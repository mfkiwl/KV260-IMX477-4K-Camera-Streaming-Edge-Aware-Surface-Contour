library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.designer_geometry.all;

-- Each input word identifies one coordinate in one of two successive frames.
-- For the native view the oracle is the output beat number itself.
entity tb_designer_view is
  generic (G_PROFILE : profile_t := 3);
end entity;

architecture bench of tb_designer_view is
  constant W_OUT : positive := INPUT_WIDTH;
  constant H_OUT : positive := output_height(G_PROFILE);
  constant INPUT_PIXELS : positive := INPUT_WIDTH*INPUT_HEIGHT;
  constant OUTPUT_PIXELS : positive := W_OUT*H_OUT;
  signal clk : std_logic := '0';
  signal rst_n, sv, sr, ss, sl, mv, mr, ms, ml : std_logic := '0';
  signal sd, md : std_logic_vector(23 downto 0);
  signal input_count, cycle_count : natural := 0;
  signal offer : std_logic := '0';
begin
  clk <= not clk after 5 ns;
  rst_n <= '1' after 45 ns;
  sv <= offer when input_count < 2*INPUT_PIXELS else '0';
  ss <= '1' when input_count mod INPUT_PIXELS=0 else '0';
  sl <= '1' when input_count mod INPUT_WIDTH=INPUT_WIDTH-1 else '0';
  sd <= std_logic_vector(to_unsigned(input_count,24));
  mr <= '0' when cycle_count mod 11=4 or cycle_count mod 11=5 else '1';

  dut : entity work.axis_designer_view
    generic map (G_PROFILE=>G_PROFILE)
    port map (aclk=>clk, aresetn=>rst_n,
              s_axis_tdata=>sd, s_axis_tvalid=>sv, s_axis_tready=>sr, s_axis_tuser=>ss, s_axis_tlast=>sl,
              m_axis_tdata=>md, m_axis_tvalid=>mv, m_axis_tready=>mr, m_axis_tuser=>ms, m_axis_tlast=>ml);

  scoreboard : process(clk)
    variable received, x, y, frame, expected, drain : natural := 0;
    variable held : boolean := false;
    variable held_data : std_logic_vector(23 downto 0);
    variable held_sof, held_eol : std_logic;
  begin
    if rising_edge(clk) and rst_n='1' then
      cycle_count <= cycle_count+1;
      assert cycle_count<14000000 report "Coordinate test timed out" severity failure;
      if sv='1' and sr='1' then input_count <= input_count+1; end if;
      if sv='0' or sr='1' then
        if cycle_count mod 17=3 then offer <= '0'; else offer <= '1'; end if;
      end if;
      if held then
        assert mv='1' and md=held_data and ms=held_sof and ml=held_eol
          report "Held pixel or marker changed" severity failure;
      end if;
      held := mv='1' and mr='0';
      held_data := md; held_sof := ms; held_eol := ml;

      if mv='1' and mr='1' then
        x := received mod W_OUT;
        y := (received mod OUTPUT_PIXELS)/W_OUT;
        frame := received/OUTPUT_PIXELS;
        expected := received;
        if G_PROFILE=2 then
          expected := frame*INPUT_PIXELS + source_y(2,y)*INPUT_WIDTH + source_x(2,x);
        end if;
        assert frame<2 and to_integer(unsigned(md))=expected
          report "Incorrect source coordinate in frame " & integer'image(frame)
            & " at (" & integer'image(x) & "," & integer'image(y) & "): expected tag "
            & integer'image(expected) & ", received " & integer'image(to_integer(unsigned(md))) severity failure;
        assert (ms='1')=(x=0 and y=0) and (ml='1')=(x=W_OUT-1)
          report "Output frame marker misaligned" severity failure;
        received := received+1;
      end if;
      if received=2*OUTPUT_PIXELS and input_count=2*INPUT_PIXELS then
        drain := drain+1;
        if drain=16 then
          report "PASS: " & integer'image(received) & " pixel coordinates and markers checked in two frames with input gaps and output backpressure";
          std.env.finish;
        end if;
      end if;
    end if;
  end process;
end architecture;
