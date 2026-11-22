library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pic2_types.all;

entity tb_scene_exposure is end entity;

architecture bench of tb_scene_exposure is
  constant W : positive := 9;
  constant H : positive := 9;
  type frames_t is array (natural range <>) of natural;
  constant EMITTED : frames_t := (0,2,3,4,6); -- frames 1 and 5 are metering only
  signal clk : std_logic := '0';
  signal rst_n, sv, sr, ss, sl, meter_pin, mv, mr, ms, ml, sent : std_logic := '0';
  signal sd, md : std_logic_vector(23 downto 0) := (others=>'0');
  function stimulus(f,x,y : natural) return rgb_t is
  begin
    -- All four corners are grid samples, including the last beat of the frame.
    if x mod 8=0 and y mod 8=0 then
      if f=1 or f=3 then return (108,113,113); else return (32,34,25); end if;
    end if;
    return ((9*x+7*y+13*f) mod 256,(13*x+25*y+3*f) mod 256,(31*x+y+18*f) mod 256);
  end function;
begin
  clk <= not clk after 5 ns;
  rst_n <= '1' after 42 ns;
  dut : entity work.axis_scene_exposure generic map(G_WIDTH=>W,G_HEIGHT=>H)
    port map(aclk=>clk,aresetn=>rst_n,s_axis_tdata=>sd,s_axis_tvalid=>sv,s_axis_tready=>sr,
      s_axis_tuser=>ss,s_axis_tlast=>sl,s_axis_meter_only=>meter_pin,
      m_axis_tdata=>md,m_axis_tvalid=>mv,m_axis_tready=>mr,m_axis_tuser=>ms,m_axis_tlast=>ml);

  source : process
    variable dropping : std_logic;
  begin
    wait until rst_n='1';
    for f in 0 to 6 loop
      if f=1 or f=5 then dropping := '1'; else dropping := '0'; end if;
      for y in 0 to H-1 loop
        for x in 0 to W-1 loop
          if (3*x+y+f) mod 11=7 then sv<='0'; wait until rising_edge(clk); end if;
          sv<='1'; sd<=std_logic_vector(to_unsigned(pack(stimulus(f,x,y)),24));
          if x=0 and y=0 then ss<='1'; meter_pin<=dropping;
          else ss<='0'; meter_pin<=not dropping;
          end if;
          if x=W-1 then sl<='1'; else sl<='0'; end if;
          loop wait until rising_edge(clk); exit when sr='1'; end loop;
        end loop;
      end loop;
    end loop;
    sv<='0'; sent<='1'; wait;
  end process;

  check : process(clk)
    variable count, cycles, drain, f, x, y, lift : natural := 0;
    variable held : boolean := false;
    variable held_payload : std_logic_vector(25 downto 0);
    variable expected : rgb_t;
    constant GAIN : rgb_t := (125,114,97);
  begin
    if rising_edge(clk) and rst_n='1' then
      cycles := cycles+1;
      assert cycles<3000 report "Exposure transition test timed out" severity failure;
      if cycles mod 13<4 then mr<='0'; else mr<='1'; end if;
      if held then assert mv='1' and (md & ms & ml)=held_payload report "Stalled exposure output changed" severity failure; end if;
      held := mv='1' and mr='0'; held_payload := md & ms & ml;
      if mv='1' and mr='1' then
        assert count < EMITTED'length*W*H report "Meter-only frame emitted pixels" severity failure;
        f := EMITTED(count/(W*H)); x := count mod W; y := (count/W) mod H;
        expected := stimulus(f,x,y);
        if f=2 or f=4 then
          lift := largest(0,14-(luma(expected)+4)/8);
          for ch in expected'range loop expected(ch) := (expected(ch)*GAIN(ch)+128)/256+lift; end loop;
        end if;
        assert md=std_logic_vector(to_unsigned(pack(expected),24)) report "Wrong gain or pixel position at transfer " & integer'image(count) severity failure;
        assert (ms='1')=(x=0 and y=0) and (ml='1')=(x=W-1) report "Exposure sideband moved" severity failure;
        count := count+1;
      end if;
      if sent='1' and count=EMITTED'length*W*H then
        drain := drain+1;
        if drain=24 then report "PASS: meter-only suppression, first-frame unity, live frame transitions, grid corners and AXI stalls"; std.env.finish; end if;
      end if;
    end if;
  end process;
end architecture;
