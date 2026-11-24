library ieee;
use ieee.std_logic_1164.all;
use std.env.all;

-- The target samples are 32 pixels apart, so the five-by-five stencils do
-- not overlap. Gray offsets on a warm base have the same value in R, G and
-- B, making each near- and far-field mean hand calculable.
entity tb_medium_context is end entity;

architecture test of tb_medium_context is
  constant W : positive := 128;
  constant H : positive := 128;
  constant N : positive := W*H;
  type levels_t is array(0 to 15) of integer;
  constant CENTER : levels_t := (0, 3, 8, 8, -8, -8, 0, 8, -8, 28, 7, -7, 8, 8, 43, -18);
  constant INNER : levels_t := (0, 0, 8, 8, -8, -8, 0, 8, -8, 28, 0, 0, 8, 8, 43, -18);
  constant OUTER : levels_t := (0, 0, 0, 8,  0, -8, 0, 0,  0, 0, 0, 0, 0, 0, 35, -26);
  constant BROAD : levels_t := (0, 0, 0, 0,  0,  0, 4, 12,-12, 0, 0, 0, 0, 0, 35, -26);
  constant DIR_Q2 : levels_t := (0, 0, 0, 0,  0,  0, 0, 0,  0, 0, 0, 0, 36, 20, 0, 0);
  -- Near/far means differ for the light and dark patches. The uniform
  -- fields have zero band difference. Probe 6 changes only the eight
  -- off-diagonal positions missing from two nested 3x3 stencils.
  constant WANT : levels_t := (0, 0, 3, 0, -3, 0, 1, 12, -12, 0, 1, -1, 0, 2, 35, -26);

  function rgb(offset : integer) return natural is
  begin
    return (60+offset)*65536+(55+offset)*256+45+offset;
  end function;

  type sample_t is record
    surface, broad : natural range 0 to 2**24-1;
    directional : natural range 0 to 255;
  end record;
  function sample(x,y : natural) return sample_t is
    variable quadrant : natural := (y/32)*4+x/32;
    variable dx : natural := abs(integer(x mod 32)-16);
    variable dy : natural := abs(integer(y mod 32)-16);
    variable offset : integer := OUTER(quadrant);
  begin
    if dx<=3 and dy<=3 then offset:=INNER(quadrant); end if;
    if dx=0 and dy=0 then offset:=CENTER(quadrant); end if;
    if quadrant=6 and ((dx=3 and dy=7) or (dx=7 and dy=3)) then
      offset:=8;
    end if;
    return (rgb(offset),rgb(BROAD(quadrant)),DIR_Q2(quadrant));
  end function;

  function tag(beat, color : natural) return natural is
    variable q : natural := color;
  begin
    if beat=0 then q:=q+2**25; end if;
    if beat mod W=W-1 then q:=q+2**24; end if;
    return q;
  end function;

  signal clk,reset_n,vi,ri,vo,ro : std_logic := '0';
  signal input_word,output_word : natural range 0 to 2**26-1 := 0;
  signal surface,context_out : natural range 0 to 2**24-1 := 0;
  signal input_ridge,output_ridge : natural range 0 to 2**28-1 := 0;
begin
  clk<=not clk after 5 ns;
  dut : entity work.portrait_structure_vote generic map(W,H)
    port map(clk,reset_n,input_word,surface,input_ridge,vi,ri,
             output_word,open,output_ridge,open,vo,ro,context_out);
  process
    variable sent,got,cyc,checks,x,y,idx : natural := 0;
    variable held : boolean := false;
    variable held_context : natural := 0;
    variable s : sample_t;
  begin
    for k in 1 to 3 loop wait until rising_edge(clk); end loop;
    reset_n<='1'; ro<='1';
    loop
      wait until rising_edge(clk);
      cyc:=cyc+1;
      assert cyc<8*N report "Medium-context block timeout" severity failure;
      if vi='1' and ri='1' then sent:=sent+1; end if;
      if held then
        assert vo='1' and context_out=held_context
          report "The context sample changed under output backpressure" severity failure;
      end if;
      held:=vo='1' and ro='0';
      if held then held_context:=context_out; end if;
      if vo='1' and ro='1' then
        x:=got mod W; y:=got/W; s:=sample(x,y);
        assert output_word=tag(got,s.broad) and output_ridge=s.directional
          report "Misaligned context sidebands" severity failure;
        if x mod 32=16 and y mod 32=16 then
          idx:=(y/32)*4+x/32;
          assert context_out=rgb(WANT(idx))
            report "Medium context probe " & integer'image(idx) & " expected " &
                   integer'image(rgb(WANT(idx))) & " got " & integer'image(context_out)
            severity failure;
          checks:=checks+1;
        end if;
        got:=got+1;
      end if;
      if vi='0' or ri='1' then
        vi<='0';
        if sent<N and cyc mod 23>=4 then
          s:=sample(sent mod W,sent/W);vi<='1';input_word<=tag(sent,s.broad);
          surface<=s.surface;input_ridge<=s.directional;
        end if;
      end if;
      if cyc mod 79<14 then ro<='0';else ro<='1';end if;
      exit when got=N;
    end loop;
    assert checks=16 and sent=N report "Missing medium field probes" severity failure;
    report "CONTEXT PASS 16 independently calculated field centers and 16384 tagged transfers";
    finish;
    wait;
  end process;
end architecture;
