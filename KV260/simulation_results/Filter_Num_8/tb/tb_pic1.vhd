library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.image_file_types.all;
use work.jpeg_reader_pkg.all;
use work.bmp_writer_pkg.all;

entity tb_pic1 is
  generic (G_INPUT : string := "images/PIC1.JPG";
           G_OUTPUT : string := "results/PIC1.bmp";
           G_WIDTH : positive := 2048; G_HEIGHT : positive := 1152;
           G_STALLS : boolean := true;
           G_SECOND_OUTPUT : string := "";
           G_LOW_BITS : boolean := false;
           G_TRACE10 : string := ""; G_DECODED : string := "");
end entity;
architecture bench of tb_pic1 is
  function frame_count return positive is
  begin if G_SECOND_OUTPUT'length=0 then return 1; end if; return 2; end;
  constant FRAMES : positive := frame_count;
  constant PIXELS : positive := G_WIDTH*G_HEIGHT;
  signal clk : std_logic := '0';
  signal rst : std_logic := '0';
  signal si, mi : std_logic_vector(31 downto 0) := (others=>'0');
  signal sv,sr,su,sl,mv,mr,mu,ml : std_logic := '0';
  function rng_step(r : unsigned(15 downto 0)) return unsigned is
  begin return r(14 downto 0) & (r(15) xor r(13) xor r(12) xor r(10)); end;
  function input_word(c : rgb_t; id, frame : natural) return std_logic_vector is
    variable p : std_logic_vector(31 downto 0) := (others=>'0');
    variable sample, frac : natural;
  begin
    for ch in 0 to 2 loop
      sample:=c(ch);
      if frame=2 then sample:=255-c((ch+1) mod 3); end if;
      frac:=0;
      if G_LOW_BITS then frac:=(id+ch+frame) mod 4; end if;
      p(29-10*ch downto 20-10*ch):=std_logic_vector(to_unsigned(4*sample+frac,10));
    end loop;
    return p;
  end;
begin
  clk<=not clk after 5 ns;
  rst<='1' after 53 ns;
  dut : entity work.designer1_axis_rgb10
    generic map (DATA_WIDTH=>32,FRAME_WIDTH=>G_WIDTH,FRAME_HEIGHT=>G_HEIGHT)
    port map (aclk=>clk,aresetn=>rst,s_axis_tdata=>si,s_axis_tvalid=>sv,
              s_axis_tready=>sr,s_axis_tuser=>su,s_axis_tlast=>sl,
              m_axis_tdata=>mi,m_axis_tvalid=>mv,m_axis_tready=>mr,m_axis_tuser=>mu,m_axis_tlast=>ml);

  source : process
    variable picture : frame_ptr;
    variable w,h : natural;
    variable random : unsigned(15 downto 0) := x"c39a";
  begin
    read_jpeg(G_INPUT,picture,w,h);
    assert w=G_WIDTH and h=G_HEIGHT report "JPEG and DUT dimensions differ" severity failure;
    if G_DECODED'length>0 then write_frame(G_DECODED,picture,w,h); end if;
    wait until rising_edge(clk) and rst='1';
    for frame in 1 to FRAMES loop
      for y in 0 to h-1 loop
        for x in 0 to w-1 loop
          random:=rng_step(random);
          if G_STALLS and random(2 downto 0)="000" then
            sv<='0'; su<='0'; sl<='0'; wait until rising_edge(clk);
          end if;
          si<=input_word(unpack(picture(y*w+x)),y*w+x,frame);
          sv<='1';
          if x=0 and y=0 then su<='1'; else su<='0'; end if;
          if x=w-1 then sl<='1'; else sl<='0'; end if;
          wait until rising_edge(clk) and sr='1';
        end loop;
      end loop;
      report "Input frame " & integer'image(frame) & " accepted " & integer'image(PIXELS) & " pixels";
    end loop;
    sv<='0'; su<='0'; sl<='0'; deallocate(picture); wait;
  end process;

  sink_ready : process(clk)
    variable random : unsigned(15 downto 0) := x"9a2d";
  begin
    if rising_edge(clk) then
      if rst='0' then mr<='0';
      else
        random:=rng_step(random);
        if G_STALLS and random(1 downto 0)="00" then mr<='0'; else mr<='1'; end if;
      end if;
    end if;
  end process;

  capture : process
    file bmp, trace : bmp_file_t;
    variable ni,no,cycles,stalls,gaps,sofs,eols,tail : natural := 0;
    variable first,last : natural := 0;
    variable held : boolean := false;
    variable previous : std_logic_vector(33 downto 0);
    variable col,row,frame_index : natural;
    variable c : rgb_t;
  begin
    if G_TRACE10'length>0 then file_open(trace,G_TRACE10,write_mode); end if;
    loop
      wait until rising_edge(clk);
      if rst='1' then
        cycles:=cycles+1;
        assert cycles<8*FRAMES*(G_HEIGHT+100)*G_WIDTH+2048 report "Stream timeout" severity failure;
        if sv='1' and sr='1' then ni:=ni+1; end if;
        if sv='0' and sr='1' and ni<FRAMES*PIXELS then gaps:=gaps+1; end if;
        if held then
          assert mv='1' and (mi & mu & ml)=previous report "Output payload or sideband changed during a stall" severity failure;
        end if;
        held:=mv='1' and mr='0'; previous:=mi & mu & ml;
        if held then stalls:=stalls+1; end if;
        if mv='1' and mr='1' then
          assert no<FRAMES*PIXELS report "Extra output beat" severity failure;
          col:=no mod G_WIDTH; row:=(no/G_WIDTH) mod G_HEIGHT; frame_index:=no/PIXELS;
          assert not is_x(mi & mu & ml) report "Unknown output payload or sideband" severity failure;
          assert mi(31 downto 30)="00" report "Nonzero padding above RGB10" severity failure;
          assert (mu='1')=(col=0 and row=0) report "SOF at wrong pixel" severity failure;
          assert (ml='1')=(col=G_WIDTH-1) report "EOL at wrong pixel" severity failure;
          if mu='1' then
            sofs:=sofs+1; first:=cycles;
            if frame_index=0 then file_open(bmp,G_OUTPUT,write_mode); else file_open(bmp,G_SECOND_OUTPUT,write_mode); end if;
            bmp_header(bmp,G_WIDTH,G_HEIGHT);
          end if;
          for ch in 0 to 2 loop c(ch):=to_integer(unsigned(mi(29-10*ch downto 22-10*ch))); end loop;
          bmp_pixel(bmp,pack(c));
          if G_TRACE10'length>0 then
            for i in 0 to 3 loop write(trace,character'val(to_integer(unsigned(mi(8*i+7 downto 8*i))))); end loop;
          end if;
          if ml='1' then eols:=eols+1; bmp_end_line(bmp,G_WIDTH); end if;
          no:=no+1;
          if no mod PIXELS=0 then
            file_close(bmp); last:=cycles;
            report "Output frame " & integer'image(frame_index+1) & " accepted " & integer'image(PIXELS) &
                   " pixels; first/last transfer cycles " & integer'image(first) & "/" & integer'image(last);
          end if;
        end if;
        if no=FRAMES*PIXELS then
          tail:=tail+1;
          if tail=64 then
            assert ni=no and sofs=FRAMES and eols=FRAMES*G_HEIGHT report "Frame accounting failed" severity failure;
            if G_STALLS and no>=1024 then assert stalls>0 and gaps>0 report "Stall/gap test not exercised" severity failure; end if;
            if G_TRACE10'length>0 then file_close(trace); end if;
            report "AXI PASS. Input=" & integer'image(ni) & " output=" & integer'image(no) & " SOF=" & integer'image(sofs) &
                   " EOL=" & integer'image(eols) & " stalled output cycles=" & integer'image(stalls) & " input gap cycles=" & integer'image(gaps);
            std.env.finish; wait;
          end if;
        end if;
      end if;
    end loop;
  end process;
end architecture;
