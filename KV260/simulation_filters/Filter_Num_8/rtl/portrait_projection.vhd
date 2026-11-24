library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.portrait_types.all;

-- Fixed-coefficient dot products. A registered reduction tree has at most four
-- terms per group. WEIGHTS(output,input) is a global calibration constant.
entity portrait_projection is
  generic (WEIGHTS : matrix_t; BIAS : integers_t; FRACTION : positive;
           LOWER_LIMIT, UPPER_LIMIT : integer);
  port (clk, resetn, advance, in_valid : in std_logic;
        x : in values_t(WEIGHTS'range(2)); q : out values_t(WEIGHTS'range(1)));
end entity;
architecture rtl of portrait_projection is
  constant INPUTS : positive := WEIGHTS'length(2);
  constant GROUPS : positive := ceil_div(INPUTS,4);
  constant BLOCKS : positive := ceil_div(GROUPS,4);
  type sums_t is array (natural range <>,natural range <>) of integer;
  signal group_sum : sums_t(WEIGHTS'range(1),0 to GROUPS-1);
  signal block_sum : sums_t(WEIGHTS'range(1),0 to BLOCKS-1);
  signal v1,v2 : std_logic := '0';
  function quantize(total : integer) return integer is
    variable rounded : signed(31 downto 0);
  begin
    rounded := shift_right(to_signed(total+2**(FRACTION-1),32),FRACTION);
    return saturate(to_integer(rounded),LOWER_LIMIT,UPPER_LIMIT);
  end;
begin
  process(clk)
    variable s : integer;
  begin
    if rising_edge(clk) then
      if resetn='0' then v1<='0'; v2<='0';
      elsif advance='1' then
        v1<=in_valid; v2<=v1;
        for o in WEIGHTS'range(1) loop
          if in_valid='1' then
            for g in 0 to GROUPS-1 loop
              s:=0;
              for i in 4*g to min_nat(4*g+3,INPUTS-1) loop
                if WEIGHTS(o,i)/=0 then s:=s+x(i)*WEIGHTS(o,i); end if;
              end loop;
              group_sum(o,g)<=s;
            end loop;
          end if;
          if v1='1' then
            for b in 0 to BLOCKS-1 loop
              s:=0;
              for g in 4*b to min_nat(4*b+3,GROUPS-1) loop s:=s+group_sum(o,g); end loop;
              block_sum(o,b)<=s;
            end loop;
          end if;
          if v2='1' then
            s:=BIAS(o);
            for b in 0 to BLOCKS-1 loop s:=s+block_sum(o,b); end loop;
            q(o)<=quantize(s);
          end if;
        end loop;
      end if;
    end if;
  end process;
end architecture;
