library ieee;
use ieee.std_logic_1164.all;
use std.env.all;

-- Sample the center of each 32x32 tile. The half-plane fixtures can be
-- transposed or reversed without changing their signed correction.
entity tb_side_context is end entity;

architecture test of tb_side_context is
  constant W : positive := 128;
  constant H : positive := 160;
  constant N : positive := W*H;
  type offsets_t is array (0 to 19) of integer;
  -- An eight-code step has near/far separations of 32 quarter-codes.
  -- Its selected side differs from broad by 16 quarter-codes. The full
  -- gate therefore adds four codes to the voted surface and one to broad.
  -- The weaker-direction case (28) has weight four and adds one / zero.
  constant WANT_SURFACE : offsets_t := (7,-7,7,-7,3,3,0,1,-1,3,1,8,32,-32,3,4,3,5,7,-5);
  constant WANT_CONTEXT : offsets_t := (1,-1,1,-1,0,1,0,0,0,0,0,0,0,0,0,0,1,2,2,0);
  type sample_t is record
    surface, broad : natural range 0 to 2**24-1;
    directional : natural range 0 to 255;
  end record;

  function sample(x,y : natural) return sample_t is
    variable p : natural := 4*(y/32)+x/32;
    variable dx : integer := integer(x mod 32)-16;
    variable dy : integer := integer(y mod 32)-16;
    variable axis : integer := dx;
    variable base : natural := 80*65536+65*256+48;
    variable offset : integer := 0;
    variable evidence : natural := 0;
  begin
    if p=2 or p=3 then axis:=dy; end if;
    case p is
      when 0 to 5 | 9 to 19 =>
        if axis>=0 then offset:=4; else offset:=-4; end if;
        if p=1 or p=3 then offset:=-offset; end if;
        if p=4 then evidence:=64; end if;
        if p=5 then base:=62*65536+62*256+47; end if;
        if p=9 and abs(axis)>=6 then offset:=-offset; end if;
        if p=10 then offset:=offset/4; end if;
        if p=11 then offset:=8; end if;
        if p=12 or p=13 then
          offset:=offset*8; evidence:=200;
          if p=13 then offset:=-offset; end if;
        end if;
        if p=14 then base:=33*65536+22*256+12; end if;
        if p=15 then evidence:=28; end if;
        if p=16 then base:=80*65536+65*256+53; end if;
        if p=17 or p=19 then base:=80*65536+65*256+52; end if;
        if p=18 then base:=80*65536+65*256+51; end if;
        if p=19 then offset:=-offset; end if;
      when 6 => null;
      when 7 => if dx=0 and dy=0 then offset:=4; end if;
      when others => if dx=0 and dy=0 then offset:=-4; end if;
    end case;
    return (base+offset*65793,base,evidence);
  end function;

  function packet(i,color : natural) return natural is
    variable word : natural := color;
  begin
    if i=0 then word:=word+2**25; end if;
    if i mod W=W-1 then word:=word+2**24; end if;
    return word;
  end function;
  signal clk,rst,vi,ri,vo,ro : std_logic := '0';
  signal wi,wo : natural range 0 to 2**26-1 := 0;
  signal si,surface_out,context_out : natural range 0 to 2**24-1 := 0;
  signal qi,qo : natural range 0 to 2**28-1 := 0;
begin
  clk <= not clk after 5 ns;
  dut : entity work.portrait_structure_vote generic map(W,H)
    port map(clk,rst,wi,si,qi,vi,ri,wo,surface_out,qo,open,vo,ro,context_out);

  process
    variable sent,got,cycle,checks,x,y,p : natural := 0;
    variable s : sample_t;
    variable stalled : boolean := false;
    variable previous_context,previous_surface : natural := 0;
  begin
    for k in 1 to 3 loop wait until rising_edge(clk); end loop;
    rst<='1'; ro<='1';
    loop
      wait until rising_edge(clk); cycle:=cycle+1;
      assert cycle<8*N report "Directional context timeout" severity failure;
      if vi='1' and ri='1' then sent:=sent+1; end if;
      if stalled then
        assert vo='1' and previous_context=context_out and previous_surface=surface_out
          report "Surface or context changed under stall" severity failure;
      end if;
      stalled:=vo='1' and ro='0';
      previous_context:=context_out; previous_surface:=surface_out;
      if vo='1' and ro='1' then
        x:=got mod W; y:=got/W; s:=sample(x,y);
        assert wo=packet(got,s.broad) and qo=s.directional report "Context tag displaced" severity failure;
        if (x mod 32)=16 and (y mod 32)=16 then
          p:=4*(y/32)+x/32;
          assert context_out=s.broad+WANT_CONTEXT(p)*65793
            report "Side context probe " & integer'image(p) & " expected offset " & integer'image(WANT_CONTEXT(p)) &
                   " got packed " & integer'image(context_out) & " over base " & integer'image(s.broad)
            severity failure;
          assert surface_out=s.broad+WANT_SURFACE(p)*65793
            report "Side surface probe " & integer'image(p) & " expected offset " & integer'image(WANT_SURFACE(p)) &
                   " got packed " & integer'image(surface_out) & " over base " & integer'image(s.broad)
            severity failure;
          checks:=checks+1;
        end if;
        got:=got+1;
      end if;
      if vi='0' or ri='1' then
        vi<='0';
        if sent<N and cycle mod 41>=3 then
          s:=sample(sent mod W,sent/W);
          vi<='1'; wi<=packet(sent,s.broad); si<=s.surface; qi<=s.directional;
        end if;
      end if;
      if cycle mod 67<18 then ro<='0'; else ro<='1'; end if;
      exit when got=N;
    end loop;
    assert sent=N and checks=WANT_SURFACE'length report "Incomplete directional check" severity failure;
    report "SIDE CONTEXT PASS 20 directional, chroma-taper and control field centers with 20480 tagged transfers";
    finish;
    wait;
  end process;
end architecture;
