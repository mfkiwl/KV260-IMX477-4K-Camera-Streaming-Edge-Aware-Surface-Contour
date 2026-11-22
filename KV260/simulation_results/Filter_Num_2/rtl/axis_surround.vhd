-- Wide 5 x 5 surround statistics. Every accepted output carries the unmodified
-- center pixel, three local means, and the mean absolute luma deviation from it.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pic2_types.all;

entity axis_surround is
  generic (G_WIDTH : positive := 2048; G_HEIGHT : positive := 1152;
           G_SPACING : positive := 16);
  port (
    aclk, aresetn : in std_logic;
    active_width, active_height : in std_logic_vector(15 downto 0);
    s_axis_tdata : in std_logic_vector(23 downto 0);
    s_axis_tvalid, s_axis_tuser, s_axis_tlast : in std_logic;
    s_axis_tready : out std_logic;
    m_axis_tdata : out std_logic_vector(23 downto 0);
    m_context : out std_logic_vector(31 downto 0);
    m_axis_tvalid, m_axis_tuser, m_axis_tlast : out std_logic;
    m_axis_tready : in std_logic
  );
end entity;

architecture rtl of axis_surround is
  constant STAGES : positive := 4;
  type center_pipe_t is array (1 to STAGES) of std_logic_vector(23 downto 0);
  type samples_t is array (0 to 24, 0 to 3) of integer range 0 to 255;
  type row_sums_t is array (0 to 4, 0 to 3) of integer range 0 to 2040;
  signal window_bits : std_logic_vector(599 downto 0);
  signal valid, sof, eol, advance : std_logic;
  signal vp, sp, ep : std_logic_vector(1 to STAGES) := (others => '0');
  signal centers : center_pipe_t;
  signal colors : tap_rgb_array_t;
  signal luminances : tap_luma_array_t;
  signal samples : samples_t;
  signal rows : row_sums_t;
begin
  neighborhood : entity work.axis_window5
    generic map (G_WIDTH, G_HEIGHT, G_SPACING)
    port map (aclk, aresetn, active_width, active_height,
              s_axis_tdata, s_axis_tvalid, s_axis_tready, s_axis_tuser, s_axis_tlast,
              window_bits, valid, advance, sof, eol);

  advance <= (not vp(STAGES)) or m_axis_tready;
  m_axis_tvalid <= vp(STAGES);
  m_axis_tuser  <= sp(STAGES);
  m_axis_tlast  <= ep(STAGES);
  m_axis_tdata  <= centers(STAGES);

  stats : process(aclk)
    variable c : rgb8_t;
    variable total : integer range 0 to 16320;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        vp <= (others => '0'); sp <= (others => '0'); ep <= (others => '0');
      elsif advance = '1' then
        vp <= valid & vp(1 to STAGES-1);
        sp <= sof & sp(1 to STAGES-1);
        ep <= eol & ep(1 to STAGES-1);
        centers(1) <= window_bits(311 downto 288);
        centers(2 to STAGES) <= centers(1 to STAGES-1);
        for i in 0 to 24 loop
          c := to_rgb8(window_bits(24*i+23 downto 24*i));
          colors(i) <= c;
          luminances(i) <= luma_y(c);
          samples(i,0) <= colors(i).r;
          samples(i,1) <= colors(i).g;
          samples(i,2) <= colors(i).b;
          samples(i,3) <= magnitude(luminances(i)-luminances(C_CENTER_TAP));
        end loop;
        -- [1 2 2 2 1] in each direction, normalized once by 64.
        for ch in 0 to 3 loop
          for row in 0 to 4 loop
            rows(row,ch) <= samples(5*row,ch) + samples(5*row+4,ch) +
              2*(samples(5*row+1,ch) + samples(5*row+2,ch) + samples(5*row+3,ch));
          end loop;
          total := rows(0,ch) + rows(4,ch) + 2*(rows(1,ch) + rows(2,ch) + rows(3,ch));
          m_context(31-8*ch downto 24-8*ch) <= std_logic_vector(to_unsigned((total+32)/64,8));
        end loop;
      end if;
    end if;
  end process;
end architecture;
