library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pic2_types.all;
use work.designer_geometry.all;
use work.jpeg_reader_pkg.all;
use work.bmp_writer_pkg.all;

entity tb_pic2 is
  generic (
    G_INPUT : string := "images/PIC1.JPG";
    G_OUTPUT : string := "results/PIC1_filtered.bmp";
    G_DECODED_BMP : string := "";
    G_SECOND_JPEG : string := "";
    G_SECOND_OUTPUT : string := "results/second_filtered.bmp";
    G_WIDTH : positive := 2048; G_HEIGHT : positive := 1152;
    G_MEDIUM_STEP : positive := 3; G_COARSE_STEP : positive := 6;
    G_CONTOUR_STEP : positive := 6; G_CHROMA_Q8 : natural range 256 to 384 := 384;
    G_STALLS : boolean := false;
    G_DESIGNER_VIEW : boolean := G_WIDTH=INPUT_WIDTH and G_HEIGHT=INPUT_HEIGHT;
    G_LARGE_VIEW : boolean := true;
    G_DESIGNER1 : boolean := true;
    G_PORTRAIT_FRAMING : boolean := false;
    G_COLOR_PROFILE : string := "test_default";
    G_CAMERA_WRAPPER : boolean := false
  );
end entity;

architecture bench of tb_pic2 is
  function frames return positive is
  begin if G_SECOND_JPEG/="" then return 2; end if; return 1; end;
  constant NFRAMES : positive := frames;
  constant PORTRAIT : boolean := G_DESIGNER_VIEW and G_PORTRAIT_FRAMING;
  function test_profile return string is
  begin
    if G_COLOR_PROFILE /= "test_default" then return G_COLOR_PROFILE; end if;
    if G_DESIGNER_VIEW and G_LARGE_VIEW and G_DESIGNER1 and not PORTRAIT then
      return "designer1_live";
    end if;
    return "auto";
  end function;
  constant PROFILE : string := test_profile;
  constant W_OUT : positive := stream_width(G_WIDTH,PORTRAIT,G_LARGE_VIEW);
  constant H_OUT : positive := stream_height(G_HEIGHT,PORTRAIT,G_LARGE_VIEW);
  constant NP_IN  : positive := G_WIDTH*G_HEIGHT;
  constant NP_OUT : positive := W_OUT*H_OUT;
  signal clk : std_logic := '0';
  signal capture_complete : std_logic := '0'; -- pixel equality is checked after the BMP closes
  signal rst_n, sv, sr, ss, sl, mv, mr, ms, ml, sent : std_logic := '0';
  signal sd, md : std_logic_vector(23 downto 0) := (others=>'0');
  function next_lfsr(v : unsigned(15 downto 0)) return unsigned is
  begin return v(14 downto 0) & (v(15) xor v(13) xor v(12) xor v(10)); end;
begin
  clk <= not clk after 5 ns;
  rst_n <= '1' after 40 ns;
  assert not G_CAMERA_WRAPPER or (G_DESIGNER_VIEW and not PORTRAIT and PROFILE="designer1_live" and
         G_MEDIUM_STEP=3 and G_COARSE_STEP=6 and G_CONTOUR_STEP=6 and G_CHROMA_Q8=384)
    report "RGB10 camera test requires the aligned live profile and production core settings" severity failure;

  camera_view : if G_CAMERA_WRAPPER generate
    signal input10, output10 : std_logic_vector(31 downto 0);
    signal filtering : std_logic;
  begin
    -- Nonzero low bits exercise the physical RGB10 lane truncation.
    input10 <= "10" & sd(23 downto 16) & "11" & sd(15 downto 8) & "01" & sd(7 downto 0) & "10";
    md <= output10(29 downto 22) & output10(19 downto 12) & output10(9 downto 2);
    dut : entity work.surface_contour_select
      generic map (G_MAX_WIDTH=>G_WIDTH, G_MAX_HEIGHT=>G_HEIGHT, G_DESIGNER1_LIVE=>true)
      port map (aclk=>clk, aresetn=>rst_n, enable=>'1',
                dimensions=>std_logic_vector(to_unsigned(G_HEIGHT,16) & to_unsigned(G_WIDTH,16)),
                s_axis_tdata=>input10, s_axis_tvalid=>sv, s_axis_tready=>sr, s_axis_tuser=>ss, s_axis_tlast=>sl,
                m_axis_tdata=>output10, m_axis_tvalid=>mv, m_axis_tready=>mr, m_axis_tuser=>ms,
                filtered=>filtering, m_axis_tlast=>ml);
    verify_packing : process(clk)
    begin
      if rising_edge(clk) and mv='1' and mr='1' then
        assert filtering='1' and output10(31 downto 30)="00" and output10(21 downto 20)="00" and
               output10(11 downto 10)="00" and output10(1 downto 0)="00"
          report "Invalid filtered RGB10 word" severity failure;
      end if;
    end process;
  end generate;

  native_view : if not G_DESIGNER_VIEW and not G_CAMERA_WRAPPER generate
    dut : entity work.pic2_filter_axis
      generic map (G_WIDTH,G_HEIGHT,G_MEDIUM_STEP,G_COARSE_STEP,G_CONTOUR_STEP,G_CHROMA_Q8)
      port map (
        aclk          => clk,
        aresetn       => rst_n,
        active_width  => std_logic_vector(to_unsigned(G_WIDTH, 16)),
        active_height => std_logic_vector(to_unsigned(G_HEIGHT, 16)),
        s_axis_tdata  => sd, s_axis_tvalid => sv, s_axis_tready => sr,
        s_axis_tuser  => ss, s_axis_tlast  => sl,
        m_axis_tdata  => md, m_axis_tvalid => mv, m_axis_tready => mr,
        m_axis_tuser  => ms, m_axis_tlast  => ml
      );
  end generate;

  styled_view : if G_DESIGNER_VIEW and not G_CAMERA_WRAPPER generate
    dut : entity work.designer_filter_axis
      generic map (G_MEDIUM_STEP=>G_MEDIUM_STEP, G_COARSE_STEP=>G_COARSE_STEP,
                   G_CONTOUR_STEP=>G_CONTOUR_STEP, G_CHROMA_Q8=>G_CHROMA_Q8,
                   G_LARGE_VIEW=>G_LARGE_VIEW, G_DESIGNER1=>G_DESIGNER1,
                   G_PORTRAIT_FRAMING=>G_PORTRAIT_FRAMING, G_WIDTH=>G_WIDTH, G_HEIGHT=>G_HEIGHT,
                   G_COLOR_PROFILE=>PROFILE)
      port map (aclk=>clk, aresetn=>rst_n,
                s_axis_tdata=>sd, s_axis_tvalid=>sv, s_axis_tready=>sr, s_axis_tuser=>ss, s_axis_tlast=>sl,
                m_axis_tdata=>md, m_axis_tvalid=>mv, m_axis_tready=>mr, m_axis_tuser=>ms, m_axis_tlast=>ml);
  end generate;

  drive : process
    variable image : frame_ptr;
    variable w,h : natural;
    variable rng : unsigned(15 downto 0) := x"ACE1";
  begin
    wait until rst_n='1';
    for f in 1 to NFRAMES loop
      if f=1 then read_jpeg(G_INPUT,image,w,h);
      else read_jpeg(G_SECOND_JPEG,image,w,h);
      end if;
      assert w=G_WIDTH and h=G_HEIGHT report "JPEG dimensions disagree with DUT generics" severity failure;
      if f=1 and G_DECODED_BMP/="" then write_frame(G_DECODED_BMP,image,w,h); end if;
      for y in 0 to h-1 loop
        for x in 0 to w-1 loop
          if G_STALLS then
            rng := next_lfsr(rng);
            if rng(2 downto 0)="000" then
              sv <= '0'; ss <= '0'; sl <= '0';
              wait until rising_edge(clk);
            end if;
          end if;
          sv <= '1'; sd <= std_logic_vector(to_unsigned(image(y*w+x),24));
          if x=0 and y=0 then ss <= '1'; else ss <= '0'; end if;
          if x=w-1 then sl <= '1'; else sl <= '0'; end if;
          loop
            wait until rising_edge(clk);
            exit when sr='1';
          end loop;
        end loop;
      end loop;
      deallocate(image);
      report "Input frame " & integer'image(f) & " accepted: " & integer'image(NP_IN) & " pixels";
    end loop;
    sv <= '0'; ss <= '0'; sl <= '0'; sent <= '1';
    wait;
  end process;

  sink_ready : process(clk)
    variable rng : unsigned(15 downto 0) := x"17B5";
    variable first_stall : boolean := true;
  begin
    if rising_edge(clk) then
      rng := next_lfsr(rng);
      if rst_n='0' then mr <= '0'; first_stall := true;
      elsif G_STALLS and NP_OUT<=4 and first_stall then
        -- A very short frame may miss every pseudorandom stall. Hold its first beat.
        mr <= '0';
        if mv='1' then first_stall := false; end if;
      elsif G_STALLS and (rng(1 downto 0)="00" or rng(7 downto 4)="1111") then mr <= '0';
      else mr <= '1';
      end if;
    end if;
  end process;

  capture : process
    file dst : bmp_file_t;
    variable cycles, n, lines, completed, drain, blocked, first_beat : natural := 0;
    variable held : boolean := false;
    variable held_data : std_logic_vector(23 downto 0);
    variable held_sof, held_eol : std_logic;
    constant LIMIT : positive := 10*(G_WIDTH+4*G_COARSE_STEP+10)*(G_HEIGHT+4*G_COARSE_STEP+10)*NFRAMES+1000;
  begin
    wait until rst_n='1';
    file_open(dst,G_OUTPUT,write_mode); bmp_header(dst,W_OUT,H_OUT);
    loop
      wait until rising_edge(clk);
      cycles := cycles+1;
      assert cycles<LIMIT report "Stream timeout" severity failure;
      if held then
        assert mv='1' and md=held_data and ms=held_sof and ml=held_eol
          report "AXI output changed while blocked" severity failure;
      end if;
      held := mv='1' and mr='0';
      if held then
        held_data := md; held_sof := ms; held_eol := ml; blocked := blocked+1;
      end if;
      if mv='1' and mr='1' then
        assert completed<NFRAMES report "Extra output beat" severity failure;
        assert not is_x(md) report "Unknown output pixel" severity failure;
        assert (ms='1')=(n=0) report "Output SOF misaligned" severity failure;
        assert (ml='1')=((n mod W_OUT)=W_OUT-1) report "Output EOL misaligned" severity failure;
        if n=0 then first_beat := cycles; end if;
        bmp_pixel(dst,to_integer(unsigned(md)));
        if ml='1' then bmp_end_line(dst,W_OUT); lines := lines+1; end if;
        n := n+1;
        if n=NP_OUT then
          file_close(dst); completed := completed+1;
          assert lines=H_OUT report "Wrong line count" severity failure;
          report "Output frame " & integer'image(completed) & ": " & integer'image(n) & " pixels, " &
                 integer'image(lines) & " EOL, 1 SOF; first/last cycles " &
                 integer'image(first_beat) & "/" & integer'image(cycles);
          if completed<NFRAMES then
            file_open(dst,G_SECOND_OUTPUT,write_mode); bmp_header(dst,W_OUT,H_OUT);
          end if;
          n := 0; lines := 0;
        end if;
      end if;
      if completed=NFRAMES and sent='1' then
        drain := drain+1;
        if drain=40 then
          if G_STALLS then assert blocked>0 report "Stall test did not stall" severity failure; end if;
          report "AXI capture PASS: " & integer'image(completed) & " frame(s), " & integer'image(NP_OUT*completed) &
                 " accepted output pixels, " & integer'image(blocked) & " stalled output cycles";
          capture_complete <= '1';
          wait for 0 ns;
          finish;
        end if;
      end if;
    end loop;
  end process;
end architecture;
