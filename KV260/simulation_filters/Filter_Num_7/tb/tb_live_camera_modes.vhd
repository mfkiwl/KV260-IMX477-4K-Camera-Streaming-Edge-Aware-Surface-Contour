-- Check filtered frame drain, dynamic dimensions, bypass and RGB10 lanes under stall.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_live_camera_modes is end entity;
architecture test of tb_live_camera_modes is
  type frame_case is record
    width, height : positive;
    active : std_logic;
    source, expected : std_logic_vector(23 downto 0);
  end record;
  type case_array is array (natural range <>) of frame_case;
  -- Uniform-frame outputs were computed with the independent integer model.
  constant frames : case_array := (
    (87,45,'1',x"18202D",x"0C3F55"), (7,3,'0',x"214467",x"214467"),
    (1,1,'1',x"402B18",x"B25C28"), (23,16,'1',x"DB78CE",x"FF6AEB"));
  signal clk, rst_n, enable, sv, sr, ss, sl, mv, mr, ms, ml, filtered : std_logic := '0';
  signal dims, sd, md : std_logic_vector(31 downto 0) := (others=>'0');
  function pack(rgb : std_logic_vector(23 downto 0); keep_low_bits : boolean) return std_logic_vector is
  begin
    if keep_low_bits then
      return "11" & rgb(23 downto 16) & "11" & rgb(15 downto 8) & "10" & rgb(7 downto 0) & "01";
    end if;
    return "00" & rgb(23 downto 16) & "00" & rgb(15 downto 8) & "00" & rgb(7 downto 0) & "00";
  end function;
begin
  clk <= not clk after 5 ns;
  rst_n <= '1' after 42 ns;
  dut : entity work.surface_contour_select
    generic map (G_MAX_WIDTH=>97, G_MAX_HEIGHT=>64, G_DESIGNER1_LIVE=>true)
    port map (aclk=>clk, aresetn=>rst_n, enable=>enable, dimensions=>dims,
              s_axis_tdata=>sd, s_axis_tvalid=>sv, s_axis_tready=>sr, s_axis_tuser=>ss, s_axis_tlast=>sl,
              m_axis_tdata=>md, m_axis_tvalid=>mv, m_axis_tready=>mr, m_axis_tuser=>ms,
              filtered=>filtered, m_axis_tlast=>ml);
  drive : process
  begin
    wait until rst_n='1';
    for f in frames'range loop
      dims <= std_logic_vector(to_unsigned(frames(f).height,16) & to_unsigned(frames(f).width,16));
      enable <= frames(f).active;
      for y in 0 to frames(f).height-1 loop
        for x in 0 to frames(f).width-1 loop
          if (x+3*y) mod 11=4 then sv <= '0'; wait until rising_edge(clk); end if;
          sv <= '1'; sd <= pack(frames(f).source,true);
          if x=0 and y=0 then ss<='1'; else ss<='0'; end if;
          if x=frames(f).width-1 then sl<='1'; else sl<='0'; end if;
          loop wait until rising_edge(clk); exit when sr='1'; end loop;
        end loop;
      end loop;
    end loop;
    sv<='0'; ss<='0'; sl<='0'; wait;
  end process;
  sink : process(clk)
    variable f, x, y, cycles, blocked, drain : natural := 0;
    variable held : boolean := false;
    variable previous : std_logic_vector(34 downto 0);
  begin
    if rising_edge(clk) and rst_n='1' then
      cycles := cycles+1;
      assert cycles<90000 report "Camera mode test timed out" severity failure;
      if cycles mod 11<5 then mr<='0'; else mr<='1'; end if;
      if held then
        assert mv='1' and (md & ms & ml & filtered)=previous report "Stalled camera beat changed" severity failure;
      end if;
      held := mv='1' and mr='0';
      if held then previous := md & ms & ml & filtered; blocked := blocked+1; end if;
      if mv='1' and mr='1' then
        assert f<frames'length report "Extra camera beat" severity failure;
        assert filtered=frames(f).active and md=pack(frames(f).expected,frames(f).active='0')
          report "Wrong color, packing or bypass state in frame " & integer'image(f+1) severity failure;
        assert (ms='1')=(x=0 and y=0) and (ml='1')=(x=frames(f).width-1)
          report "Wrong camera frame markers" severity failure;
        if x+1<frames(f).width then x := x+1;
        elsif y+1<frames(f).height then x := 0; y := y+1;
        else x := 0; y := 0; f := f+1;
        end if;
      end if;
      if f=frames'length then
        drain := drain+1;
        if drain=60 then
          assert blocked>0 report "No output stalls exercised" severity failure;
          report "Camera modes PASS: four frames, varying sizes, bypass, RGB10 packing and " &
                 integer'image(blocked) & " stalled cycles";
          finish;
        end if;
      end if;
    end if;
  end process;
end architecture;
