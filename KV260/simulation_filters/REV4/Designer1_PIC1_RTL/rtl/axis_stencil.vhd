library ieee;
use ieee.std_logic_1164.all;

-- Two centered, sparse 3x3 stencils and the payload belonging to the center.
-- Sample (scale,row,col) starts at bit G_BITS*(9*scale + 3*row + col).
entity axis_stencil is
  generic (
    G_WIDTH, G_HEIGHT : positive;
    G_NEAR, G_FAR : positive;
    G_BITS, G_META_BITS : positive;
    G_MIXED_TAPS : boolean := false
  );
  port (
    clk, reset_n : in std_logic;
    s_sample : in std_logic_vector(G_BITS-1 downto 0);
    s_meta : in std_logic_vector(G_META_BITS-1 downto 0);
    s_valid : in std_logic;
    s_ready : out std_logic;
    m_samples : out std_logic_vector(18*G_BITS-1 downto 0);
    m_meta : out std_logic_vector(G_META_BITS-1 downto 0);
    m_valid : out std_logic;
    m_ready : in std_logic;
    -- Near rows with far columns, then far rows with near columns (four each).
    m_mixed : out std_logic_vector(8*G_BITS-1 downto 0) := (others=>'0')
  );
end entity;

architecture rtl of axis_stencil is
  function largest(a,b : positive) return positive is
  begin
    if a>b then return a; end if;
    return b;
  end function;
  constant R : positive := largest(G_NEAR,G_FAR);
  constant PITCH : positive := G_WIDTH+R;
  constant DELAY : positive := R*PITCH+R;
  type steps_t is array(0 to 1) of positive;
  constant STEP : steps_t := (G_NEAR,G_FAR);
  subtype sample_t is std_logic_vector(G_BITS-1 downto 0);
  subtype history_t is std_logic_vector(2*R*G_BITS-1 downto 0);
  type lines_t is array(0 to G_WIDTH-1) of history_t;
  type centers_t is array(0 to DELAY-1) of std_logic_vector(G_META_BITS-1 downto 0);
  type column_t is array(0 to 1,0 to 2) of sample_t;
  type columns_t is array(natural range <>) of column_t;
  signal cols : columns_t(0 to 2*R-1);
  signal x,x0 : natural range 0 to PITCH-1 := 0;
  signal y,y0 : natural range 0 to G_HEIGHT+R-1 := 0;
  signal addr : natural range 0 to DELAY-1 := 0;
  signal history : history_t;
  signal sample0 : sample_t;
  signal meta0 : std_logic_vector(G_META_BITS-1 downto 0);
  signal v0,v1 : std_logic := '0';
  signal active,advance,issue : std_logic;
begin
  active <= '1' when x<G_WIDTH and y<G_HEIGHT else '0';
  advance <= (not v1) or m_ready;
  s_ready <= advance and active and reset_n;
  issue <= advance and reset_n and ((not active) or s_valid);
  m_valid <= v1;
  process(clk)
    -- Only this clocked process owns these RAMs. Read before write for
    -- synchronous old-data behavior, including same-address collisions.
    variable lines : lines_t;
    variable centers : centers_t;
    variable stack : std_logic_vector((2*R+1)*G_BITS-1 downto 0);
    variable pixel : sample_t;
    variable column : column_t;
    variable window : columns_t(0 to 2*R);
    variable offset : natural range 0 to 2*R;
    variable first : natural;
  begin
    if rising_edge(clk) then
      if reset_n='0' then
        x<=0; y<=0; addr<=0; v0<='0'; v1<='0';
      elsif advance='1' then
        v0<=issue; v1<='0';
        if issue='1' then
          x0<=x; y0<=y;
          if x=PITCH-1 then
            x<=0;
            if y=G_HEIGHT+R-1 then y<=0; else y<=y+1; end if;
          else x<=x+1;
          end if;
          if x<G_WIDTH then history<=lines(x); end if;
          sample0<=s_sample;
          meta0<=centers(addr); centers(addr):=s_meta;
          if addr=DELAY-1 then addr<=0; else addr<=addr+1; end if;
        end if;
        if v0='1' then
          if x0<G_WIDTH then
            pixel:=sample0;
            if y0>=G_HEIGHT then pixel:=history(G_BITS-1 downto 0); end if;
            stack:=history & pixel;
            if y0=0 then
              for j in 0 to 2*R loop stack((j+1)*G_BITS-1 downto j*G_BITS):=pixel; end loop;
            end if;
            lines(x0):=stack(2*R*G_BITS-1 downto 0);
            for scale in 0 to 1 loop
              for row_idx in 0 to 2 loop
                offset:=R+(1-row_idx)*STEP(scale);
                column(scale,row_idx):=stack((offset+1)*G_BITS-1 downto offset*G_BITS);
              end loop;
            end loop;
          else column:=cols(0);
          end if;
          window(0):=column;
          if x0=0 then window(1 to 2*R):=(others=>column);
          else window(1 to 2*R):=cols;
          end if;
          cols<=window(0 to 2*R-1);
          if x0>=R and y0>=R then
            v1<='1'; m_meta<=meta0;
            for scale in 0 to 1 loop
              for row_idx in 0 to 2 loop
                for col_idx in 0 to 2 loop
                  offset:=R+(1-col_idx)*STEP(scale);
                  first:=G_BITS*(9*scale+3*row_idx+col_idx);
                  m_samples(first+G_BITS-1 downto first)<=window(offset)(scale,row_idx);
                end loop;
              end loop;
            end loop;
            if G_MIXED_TAPS then
              for scale in 0 to 1 loop
                for r_side in 0 to 1 loop
                  for c_side in 0 to 1 loop
                    offset:=R+(1-2*c_side)*STEP(1-scale);
                    first:=G_BITS*(4*scale+2*r_side+c_side);
                    m_mixed(first+G_BITS-1 downto first)<=window(offset)(scale,2*r_side);
                  end loop;
                end loop;
              end loop;
            else
              m_mixed<=(others=>'0');
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
