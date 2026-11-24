library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package portrait_types is
  subtype code10_t is integer range 0 to 1023;
  type rgb10_t is array (0 to 2) of code10_t;
  type planes_t is array (0 to 3) of code10_t; -- R, G, B, horizontal texture
  type axes_t is array (0 to 2) of integer range -1023 to 1023;
  type slopes_t is array (0 to 3) of integer range -2046 to 2046;
  subtype value_t is integer range -16384 to 16383;
  type values_t is array (natural range <>) of value_t;
  type matrix_t is array (natural range <>, natural range <>) of integer;
  type integers_t is array (natural range <>) of integer;
  constant N_FEATURES : positive := 27;
  constant FINISH_SPACING : integers_t(0 to 3) := (1,4,8,20);
  constant FINISH_THRESHOLD : integers_t(0 to 3) := (112,72,48,48);
  function min_nat(a, b : natural) return natural;
  function ceil_div(n, d : positive) return positive;
  function next_power2(n : positive) return positive;
  function saturate(n, lo, hi : integer) return integer;
  function components(c : rgb10_t) return axes_t;
  function pack_planes(p : planes_t) return std_logic_vector;
  function unpack_planes(p : std_logic_vector(39 downto 0)) return planes_t;
  function unpack_rgb(p : std_logic_vector(29 downto 0)) return rgb10_t;
  function pack_rgb(c : rgb10_t) return std_logic_vector;
end package;

package body portrait_types is
  function min_nat(a,b : natural) return natural is
  begin if a < b then return a; end if; return b; end;
  function ceil_div(n,d : positive) return positive is
  begin return (n+d-1)/d; end;
  function next_power2(n : positive) return positive is
    variable result : positive := 1;
  begin while result < n loop result := result*2; end loop; return result; end;
  function saturate(n,lo,hi : integer) return integer is
  begin if n < lo then return lo; elsif n > hi then return hi; end if; return n; end;
  function components(c : rgb10_t) return axes_t is
  begin return ((c(0)+2*c(1)+c(2)+2)/4, c(0)-c(1), c(1)-c(2)); end;
  function pack_planes(p : planes_t) return std_logic_vector is
    variable w : std_logic_vector(39 downto 0);
  begin for i in p'range loop w(10*i+9 downto 10*i) := std_logic_vector(to_unsigned(p(i),10)); end loop; return w; end;
  function unpack_planes(p : std_logic_vector(39 downto 0)) return planes_t is
    variable c : planes_t;
  begin for i in c'range loop c(i) := to_integer(unsigned(p(10*i+9 downto 10*i))); end loop; return c; end;
  function unpack_rgb(p : std_logic_vector(29 downto 0)) return rgb10_t is
  begin return (to_integer(unsigned(p(29 downto 20))),to_integer(unsigned(p(19 downto 10))),to_integer(unsigned(p(9 downto 0)))); end;
  function pack_rgb(c : rgb10_t) return std_logic_vector is
  begin return std_logic_vector(to_unsigned(c(0),10) & to_unsigned(c(1),10) & to_unsigned(c(2),10)); end;
end package body;
