library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.designer_geometry.all;

-- The payload is the absolute input transfer number across two frames. A
-- stale RAM row, misplaced repeat or swapped word therefore changes the data.
entity tb_designer_view is
  generic (G_LARGE_VIEW : boolean := true; G_DESIGNER1 : boolean := true;
           G_PORTRAIT_FRAMING : boolean := false);
end entity;

architecture bench of tb_designer_view is
  -- Expected dimensions from the specification, independent of the RTL size functions.
  constant W_OUT : positive := profile_size(G_PORTRAIT_FRAMING,profile_size(G_LARGE_VIEW,2048,1536),INPUT_WIDTH);
  constant H_OUT : positive := profile_size(G_PORTRAIT_FRAMING,profile_size(G_LARGE_VIEW,1365,1024),INPUT_HEIGHT);
  constant NEW_PORTRAIT : boolean := G_LARGE_VIEW and G_DESIGNER1;
  constant KNEE : positive := profile_size(NEW_PORTRAIT,1245,profile_size(G_LARGE_VIEW,1195,896));
  constant TAIL : positive := profile_size(G_LARGE_VIEW,1365,1024)-1-KNEE;
  constant INPUT_PIXELS : positive := INPUT_WIDTH*INPUT_HEIGHT;
  constant OUTPUT_PIXELS : positive := W_OUT*H_OUT;
  signal clk : std_logic := '0';
  signal rst_n, sv, sr, ss, sl, mv, mr, ms, ml : std_logic := '0';
  signal sd, md : std_logic_vector(23 downto 0);
  signal input_count, cycle_count : natural := 0;
begin
  clk <= not clk after 5 ns;
  rst_n <= '1' after 45 ns;
  sv <= '1' when input_count < 2*INPUT_PIXELS else '0';
  ss <= '1' when input_count mod INPUT_PIXELS=0 else '0';
  sl <= '1' when input_count mod INPUT_WIDTH=INPUT_WIDTH-1 else '0';
  sd <= std_logic_vector(to_unsigned(input_count,24));
  mr <= '0' when cycle_count mod 11=4 or cycle_count mod 11=5 else '1';

  dut : entity work.axis_designer_view
    generic map (G_LARGE_VIEW=>G_LARGE_VIEW, G_DESIGNER1=>G_DESIGNER1,
                 G_PORTRAIT_FRAMING=>G_PORTRAIT_FRAMING)
    port map (aclk=>clk, aresetn=>rst_n,
              s_axis_tdata=>sd, s_axis_tvalid=>sv, s_axis_tready=>sr, s_axis_tuser=>ss, s_axis_tlast=>sl,
              m_axis_tdata=>md, m_axis_tvalid=>mv, m_axis_tready=>mr, m_axis_tuser=>ms, m_axis_tlast=>ml);

  scoreboard : process(clk)
    variable received, x, y, source_x, source_y, frame, expected : natural := 0;
    variable held : boolean := false;
    variable held_data : std_logic_vector(23 downto 0);
    variable held_sof, held_eol : std_logic;
  begin
    if rising_edge(clk) and rst_n='1' then
      cycle_count <= cycle_count+1;
      assert cycle_count<14000000 report "Coordinate test timed out" severity failure;
      if sv='1' and sr='1' then input_count <= input_count+1; end if;
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
        if not G_PORTRAIT_FRAMING then
          source_x := x;
          source_y := y;
        else
          if NEW_PORTRAIT then
            if x<=700 then source_x := 70+(666*x+350)/700;
            else source_x := 736+(1210*(x-700)+673)/1347;
            end if;
          else source_x := 105+(1841*x+(W_OUT-1)/2)/(W_OUT-1);
          end if;
          if NEW_PORTRAIT and y<=KNEE then source_y := (1110*y+KNEE/2)/KNEE;
          elsif NEW_PORTRAIT then source_y := 1110+(41*(y-KNEE)+TAIL/2)/TAIL;
          elsif y<=KNEE then
            source_y := 1+(1065*y+KNEE/2)/KNEE;
          else
            source_y := 1066+(85*(y-KNEE)+TAIL/2)/TAIL;
          end if;
        end if;
        expected := frame*INPUT_PIXELS + source_y*INPUT_WIDTH + source_x;
        assert frame<2 and to_integer(unsigned(md))=expected
          report "Incorrect source coordinate in frame " & integer'image(frame)
            & " at (" & integer'image(x) & "," & integer'image(y) & ")" severity failure;
        assert (ms='1')=(x=0 and y=0) and (ml='1')=(x=W_OUT-1)
          report "Output frame marker misaligned" severity failure;
        received := received+1;
      end if;
      if received=2*OUTPUT_PIXELS and input_count=2*INPUT_PIXELS then
        report "PASS: " & integer'image(received) & " coordinates and their SOF/EOL markers across two "
          & integer'image(W_OUT) & " x " & integer'image(H_OUT) & " frames under backpressure";
        std.env.finish;
      end if;
    end if;
  end process;
end architecture;
