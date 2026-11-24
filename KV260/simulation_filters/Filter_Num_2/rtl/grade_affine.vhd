-- Five enabled clocks per matrix-vector product. All rows run in parallel.
library ieee;
use ieee.std_logic_1164.all;
use work.pic2_types.all;

entity grade_affine is
  generic (
    G_WEIGHTS     : grade_matrix_t;
    G_BIAS        : grade_vector_t;
    G_INPUT_LIMIT : positive;
    G_FRAC_BITS   : natural := 0;
    G_RELU_LIMIT  : natural := 0  -- zero selects the unrounded, signed sum
  );
  port (
    aclk, advance : in std_logic;
    valid_in      : in std_logic_vector(0 to 4);
    x             : in grade_vector_t(0 to G_WEIGHTS'length(2)-1);
    y             : out grade_vector_t(0 to G_WEIGHTS'length(1)-1)
  );
end entity;

architecture rtl of grade_affine is
  constant COLS : positive := G_WEIGHTS'length(2);
  constant GROUPS : positive := (COLS+3)/4;
  constant BLOCKS : positive := (GROUPS+3)/4;
  constant DIVISOR : positive := 2**G_FRAC_BITS;
begin
  rows : for row in G_WEIGHTS'range(1) generate
    -- Bound each adder-tree level using the fixed coefficients in this row.
    function level_bound(count : positive) return positive is
      variable total, peak : natural := 0;
    begin
      for k in 0 to COLS-1 loop
        total := total + G_INPUT_LIMIT*magnitude(G_WEIGHTS(row,k));
        if (k+1) mod count=0 or k=COLS-1 then
          peak := largest(peak,total);
          total := 0;
        end if;
      end loop;
      return largest(peak,1);
    end function;
    constant P_BOUND : positive := level_bound(1);
    constant G_BOUND : positive := level_bound(4);
    constant B_BOUND : positive := level_bound(16);
    constant A_BOUND : positive := level_bound(COLS)+magnitude(G_BIAS(row));
    type products_t is array(0 to 4*GROUPS-1) of integer range -P_BOUND to P_BOUND;
    type groups_t is array(0 to 4*BLOCKS-1) of integer range -G_BOUND to G_BOUND;
    type blocks_t is array(0 to BLOCKS-1) of integer range -B_BOUND to B_BOUND;
    signal products : products_t;
    signal partial4 : groups_t;
    signal partial16 : blocks_t;
    signal affine : integer range -A_BOUND to A_BOUND;
  begin
    process(aclk)
      variable value : integer range -G_INPUT_LIMIT to G_INPUT_LIMIT;
      variable total : integer;
    begin
      if rising_edge(aclk) and advance='1' then
        if valid_in(0)='1' then
          for k in products'range loop
            if k<COLS then
              value := x(k);
              products(k) <= value*G_WEIGHTS(row,k);
            else
              products(k) <= 0;
            end if;
          end loop;
        end if;
        if valid_in(1)='1' then
          for g in partial4'range loop
            if g<GROUPS then
              partial4(g) <= (products(4*g)+products(4*g+1)) + (products(4*g+2)+products(4*g+3));
            else
              partial4(g) <= 0;
            end if;
          end loop;
        end if;
        if valid_in(2)='1' then
          for b in partial16'range loop
            partial16(b) <= (partial4(4*b)+partial4(4*b+1)) + (partial4(4*b+2)+partial4(4*b+3));
          end loop;
        end if;
        if valid_in(3)='1' then
          total := G_BIAS(row);
          for b in partial16'range loop total := total + partial16(b); end loop;
          affine <= total;
        end if;
      end if;
    end process;
    rectifier : if G_RELU_LIMIT>0 generate
      signal activation : integer range 0 to G_RELU_LIMIT;
    begin
      process(aclk)
      begin
        if rising_edge(aclk) and advance='1' and valid_in(4)='1' then
          activation <= clamp((affine+DIVISOR/2)/DIVISOR,0,G_RELU_LIMIT);
        end if;
      end process;
      y(row) <= activation;
    end generate;
    signed_output : if G_RELU_LIMIT=0 generate
      signal value : integer range -A_BOUND to A_BOUND;
    begin
      process(aclk)
      begin
        if rising_edge(aclk) and advance='1' and valid_in(4)='1' then value <= affine; end if;
      end process;
      y(row) <= value;
    end generate;
  end generate;
end architecture;
