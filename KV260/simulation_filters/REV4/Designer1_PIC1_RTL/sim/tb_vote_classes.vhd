library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

-- Each probe presents surface luma 100 at its center and 108 at all eight
-- chosen taps. Only the independent context changes, altering the local
-- contrast and near/far polarity support. The expected center is hand derived.
entity tb_vote_classes is end entity;
architecture test of tb_vote_classes is
  constant W : positive := 100;
  constant H : positive := 72;
  constant N : positive := W*H;
  type bank_t is array(0 to 11) of integer;
  -- Four classifications plus unsupported/just-supported threshold cases.
  constant CONTRAST : bank_t := (0,2,7,20,-7,7,7,7,0,0,0,0);
  constant NEAR_CT  : bank_t := (0,0,3,0,3,1,4,2,4,4,4,4);
  constant FAR_CT   : bank_t := (0,0,2,0,2,4,1,2,4,4,4,4);
  constant WANT     : bank_t := (108,106,102,100,102,106,106,106,102,106,106,102);
  type octet_t is array(0 to 7) of integer;
  constant DX : octet_t := (0,-3,3,0,-7,7,-7,7);
  constant DY : octet_t := (-3,0,0,3,-7,-7,7,7);
  function rgb(k : integer) return natural is begin return 65793*k; end;
  -- Packed-context offsets below keep the numerical luma constant.
  constant RG : integer := -4*65536+2*256;
  constant GB : integer := -2*256+4;
  type sample_t is record s,b : natural range 0 to 2**24-1; end record;
  function fixture(x,y : integer) return sample_t is
    variable data : sample_t := (rgb(108),rgb(108));
    variable cx,cy : integer;
  begin
    for p in CONTRAST'range loop
      cx:=12+24*(p mod 4); cy:=12+24*(p/4);
      if x=cx and y=cy then
        if p=11 then return (rgb(100),rgb(100)-RG); end if;
        if p>=8 then return (rgb(100),rgb(100)+RG); end if;
        return (rgb(100),rgb(100-CONTRAST(p)));
      end if;
      for t in DX'range loop
        if x=cx+DX(t) and y=cy+DY(t) and ((t<4 and t<NEAR_CT(p)) or
            (t>=4 and t-4<FAR_CT(p))) then
          case p is
            when 8 => data.b:=rgb(108)+RG;
            when 9 => data.b:=rgb(108)+GB;
            when 10 | 11 => data.b:=rgb(108)-RG;
            when others =>
              if CONTRAST(p)<0 then data.b:=rgb(109); else data.b:=rgb(107); end if;
          end case;
        end if;
      end loop;
    end loop;
    return data;
  end function;
  function packet(idx,pay : integer) return natural is
    variable data : natural := pay;
  begin
    if idx=0 then data:=data+2**25; end if;
    if idx mod W=W-1 then data:=data+2**24; end if;
    return data;
  end function;
  function evidence(idx : natural) return natural is
  begin return (idx mod 1024)*65536+((idx/8) mod 8)*256+idx mod 8; end;
  signal clk,rst_n,vi,ri,vo,ro : std_logic := '0';
  signal wi,wo : natural range 0 to 2**26-1 := 0;
  signal si,so : natural range 0 to 2**24-1 := 0;
  signal ridge_i,ridge_o,guide_o : natural range 0 to 2**28-1 := 0;
begin
  clk<=not clk after 5 ns;
  dut : entity work.portrait_structure_vote generic map(W,H)
     port map(clk,rst_n,wi,si,ridge_i,vi,ri,wo,so,ridge_o,guide_o,vo,ro);
  process
    variable sent,got,cyc,checks : natural := 0;
    variable datum : sample_t;
  begin
    for i in 1 to 4 loop wait until rising_edge(clk); end loop;
    rst_n<='1'; ro<='1';
    loop
      wait until rising_edge(clk); cyc:=cyc+1;
      assert cyc<N*8 report "Vote block timeout" severity failure;
      if vi='1' and ri='1' then sent:=sent+1; end if;
      if vo='1' and ro='1' then
        datum:=fixture(got mod W,got/W);
        assert wo=packet(got,datum.b) and ridge_o=evidence(got)
          report "Misaligned center metadata" severity failure;
        assert guide_o=2**20*work.stroke_math_pkg.hi((got/8) mod 8,got mod 8)
             +work.stroke_math_pkg.source_guide(std_logic_vector(to_unsigned(datum.s,24)),
                                                  std_logic_vector(to_unsigned(datum.b,24)))
          report "Original contour guide changed at output" severity failure;
        for p in CONTRAST'range loop
          if got mod W=12+24*(p mod 4) and got/W=12+24*(p/4) then
            assert so=rgb(WANT(p)) report "Class probe " & integer'image(p) &
              " expected grayscale " & integer'image(WANT(p)) &
              " got " & integer'image(so mod 256) severity failure;
            checks:=checks+1;
          end if;
        end loop;
        got:=got+1;
      end if;
      if vi='0' or ri='1' then
        vi<='0';
        if sent<N and cyc mod 29>=4 then
          datum:=fixture(sent mod W,sent/W); vi<='1';wi<=packet(sent,datum.b);si<=datum.s;
          ridge_i<=evidence(sent);
        end if;
      end if;
      if cyc mod 283<31 then ro<='0';else ro<='1';end if;
      exit when got=N;
    end loop;
    assert sent=N and checks=12 report "Missing class probes" severity failure;
    report "VOTE PASS 12 hand-calculated class, support, polarity and equal-luma chroma probes; all 7200 context, ridge and original contour-guide transfers aligned";
    finish;
    wait;
  end process;
end architecture;
