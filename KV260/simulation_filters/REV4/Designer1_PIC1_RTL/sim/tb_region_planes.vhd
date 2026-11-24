library ieee;
use ieee.std_logic_1164.all;
use std.env.all;

entity tb_region_planes is generic (G_OBSERVE : boolean := false); end entity;
architecture test of tb_region_planes is
  constant W : positive := 64;
  constant H : positive := 64;
  type triple_t is array(0 to 2) of natural;
  type bank_t is array (0 to 15) of triple_t;
  constant COLOR : bank_t := ((18,66,80),(18,66,80),(88,64,54),(88,64,54),
    (111,79,65),(75,55,45),(55,60,72),(9,22,25),(185,128,77),(100,58,52),
    (125,135,88),(90,100,112),(48,66,58),(88,54,42),(88,54,42),(48,66,58));
  constant WANT : bank_t := ((18,66,80),(55,71,71),(55,41,47),(55,41,47),(110,76,60),
    (35,26,38),(53,59,73),(9,26,28),(185,128,77),(93,59,54),(125,135,83),(97,103,110),
    (76,65,46),(50,36,41),(25,27,41),(43,38,44));
  function packet(i : natural; c : triple_t; offset : integer := 0) return natural is
    variable v : integer := 65536*c(0)+256*c(1)+c(2)+offset*65793;
  begin
    if i=0 then v:=v+2**25; end if;
    if i mod W=W-1 then v:=v+2**24; end if;
    return v;
  end function;
  function input(i : natural) return natural is
    variable x : natural := i mod W;
    variable y : natural := i/W;
    variable idx : natural := (y/16)*4+x/16;
    variable offset : integer := 0;
  begin
    -- The low/high vertical bands alter the outer field. The center and
    -- its tangent share the listed color throughout the 16x16 tile.
    -- Both chroma vectors in the last four fields have weighted luminance
    -- 60. They differ only in spatial support for the center's pigment.
    if idx>=12 then
      if x mod 16=8 and y mod 16=8 then
        if idx=12 then return packet(i,(88,54,42)); end if;
        if idx=14 then return packet(i,(48,66,58)); end if;
      end if;
      if idx=15 and y mod 16=8 then return packet(i,(88,54,42)); end if;
    elsif idx mod 2=1 or idx>=4 then
      if y mod 16<=3 then offset:=-8;
      elsif y mod 16>=13 then offset:=8; end if;
    end if;
    return packet(i,COLOR(idx),offset);
  end function;
  signal clk,rst,vi,ri,vo,ro : std_logic := '0';
  signal wi,wo : natural range 0 to 2**26-1 := 0;
begin
  clk<=not clk after 5 ns;
  dut : entity work.portrait_region_axis generic map(W,H)
    port map(clk,rst,wi,vi,ri,wo,vo,ro);
  process
    variable sent,got,cycle,x,y,idx,checks : natural := 0;
  begin
    for k in 1 to 3 loop wait until rising_edge(clk); end loop;
    rst<='1';
    loop
      wait until rising_edge(clk); cycle:=cycle+1;
      assert cycle<6*W*H report "Region probes timed out" severity failure;
      if vi='1' and ri='1' then sent:=sent+1; end if;
      if vo='1' and ro='1' then
        x:=got mod W; y:=got/W;
        if x mod 16=8 and y mod 16=8 then
          idx:=(y/16)*4+x/16;
          if G_OBSERVE then
            report "P " & integer'image(idx) & " " & integer'image(wo/65536 mod 256) &
              " " & integer'image(wo/256 mod 256) & " " & integer'image(wo mod 256);
          else
            assert wo=packet(got,WANT(idx))
              report "Region probe " & integer'image(idx) & " got " &
              integer'image(wo/65536 mod 256) & " " & integer'image(wo/256 mod 256) &
              " " & integer'image(wo mod 256) severity failure;
          end if;
          checks:=checks+1;
        end if;
        got:=got+1;
      end if;
      if vi='0' or ri='1' then
        vi<='0';
        if sent<W*H and cycle mod 23>=3 then vi<='1'; wi<=input(sent); end if;
      end if;
      if cycle mod 37<7 then ro<='0'; else ro<='1'; end if;
      exit when got=W*H;
    end loop;
    assert checks=WANT'length and sent=W*H severity failure;
    report "REGION PLANE PASS 16 shadow, pigment and neutral fixtures, including equal-luma tangent support";
    finish; wait;
  end process;
end architecture;
