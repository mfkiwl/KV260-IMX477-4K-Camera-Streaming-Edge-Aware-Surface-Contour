library ieee;
use ieee.std_logic_1164.all;
use std.env.all;

entity tb_olive_finish is end entity;
architecture test of tb_olive_finish is
  constant W : positive := 64;
  type levels_t is array(0 to 7) of integer;
  constant LEFT_OFFSET : levels_t := (8,8,8,-24,39,1,8,-8);
  constant RIGHT_OFFSET : levels_t := (10,10,10,25,40,1,10,-10);
  -- A green-supported center counts once and its paired mean counts three
  -- times. Probe 0 has a mean of +9; probe 7 has -9. Compare the +5
  -- conventional blend when the color class or guide disables consolidation.
  constant EXPECTED : levels_t := (7,5,5,0,0,1,5,-7);
  function packet(x : natural; delta : integer) return natural is
    variable p : natural := x/8;
    variable base : natural := 70*65536+75*256+55;
    variable v : natural;
  begin
    if p=2 then base:=base+10; end if;
    if p=6 then base:=95*65536+70*256+50; end if;
    v:=base+delta*65793;
    if x=0 then v:=v+2**25; end if;
    if x=W-1 then v:=v+2**24; end if;
    return v;
  end function;
  signal clk,rst,vi,ri,vo,ro : std_logic := '0';
  signal wi,wo : natural range 0 to 2**26-1 := 0;
  signal guide_i,guide_o : natural range 0 to 2**28-1 := 0;
begin
  clk<=not clk after 5 ns;
  dut : entity work.portrait_smooth_axis generic map(W,1,2,false,24,G_SURFACE_FINISH=>true,
      G_RECONSTRUCT=>true,G_FORWARD_RIDGE=>true)
    port map(clk,rst,wi,vi,ri,wo,vo,ro,0,open,guide_i,guide_o);
  process
    variable sent,got,cycle,checks,p : natural := 0;
    variable delta : integer;
  begin
    for k in 1 to 3 loop wait until rising_edge(clk); end loop;
    rst<='1';
    loop
      wait until rising_edge(clk); cycle:=cycle+1;
      assert cycle<8*W severity failure;
      if vi='1' and ri='1' then sent:=sent+1; end if;
      if vo='1' and ro='1' then
        p:=got/8;
        if p=1 then assert guide_o=0 severity failure;
        else assert guide_o=16*32 severity failure; end if;
        if got mod 8=4 then
          assert wo=packet(got,EXPECTED(p)) report "Olive finish case " & integer'image(p) &
            " expected offset " & integer'image(EXPECTED(p)) & " got " &
            integer'image(integer(wo mod 256)-integer(packet(got,0) mod 256)) severity failure;
          checks:=checks+1;
        end if;
        got:=got+1;
      end if;
      if vi='0' or ri='1' then
        vi<='0';
        if sent<W and cycle mod 19>=2 then
          vi<='1'; p:=sent/8; delta:=0;
          if sent mod 8=2 then delta:=LEFT_OFFSET(p); end if;
          if sent mod 8=6 then delta:=RIGHT_OFFSET(p); end if;
          wi<=packet(sent,delta);
          if p=1 then guide_i<=0; else guide_i<=16*32; end if;
        end if;
      end if;
      if cycle mod 31<6 then ro<='0'; else ro<='1'; end if;
      exit when got=W;
    end loop;
    assert sent=W and checks=8 severity failure;
    report "OLIVE FINISH PASS 8 hand-calculated axial merges, chroma gates and boundaries";
    finish; wait;
  end process;
end architecture;
