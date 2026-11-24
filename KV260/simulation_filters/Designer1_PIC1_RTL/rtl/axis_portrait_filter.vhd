library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.live_tone_pkg.all;

entity axis_portrait_filter is
  generic (
    G_WIDTH          : positive := 2048;
    G_HEIGHT         : positive := 1152;
    G_THRESHOLD_BASE : natural range 0 to 255 := 16;
    G_THRESHOLD_STEP : natural range 0 to 255 := 2;
    G_CONTEXT_STEP   : positive := 16
  );
  port (
    aclk, aresetn : in std_logic;
    s_axis_tdata  : in std_logic_vector(31 downto 0);
    s_axis_tvalid : in std_logic;
    s_axis_tready : out std_logic;
    s_axis_tuser  : in std_logic;
    s_axis_tlast  : in std_logic;
    m_axis_tdata  : out std_logic_vector(31 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in std_logic;
    m_axis_tuser  : out std_logic;
    m_axis_tlast  : out std_logic
  );
end entity;

architecture rtl of axis_portrait_filter is
  -- Per-stage threshold in RGB888 units; ceiling covers the full channel span.
  function threshold_at(scale : natural) return natural is
    constant limit : natural := G_THRESHOLD_BASE + scale*G_THRESHOLD_STEP;
  begin
    if limit > 255 then return 255; end if;
    return limit;
  end function;
  type word_array is array (natural range <>) of natural range 0 to 2**26-1;
  signal word  : word_array(0 to 10);
  signal valid : std_logic_vector(0 to 10);
  signal ready : std_logic_vector(0 to 10);
  signal horizontal_detail, aligned_detail : natural range 0 to 2**24-1;
  signal final_word : std_logic_vector(25 downto 0);
  signal output_valid : std_logic := '0';
begin
  -- RGB10 is R[29:20], G[19:10], B[9:0]. Filter arithmetic uses the top 8 bits.
  word(0) <= to_integer(unsigned(std_logic_vector'(s_axis_tuser & s_axis_tlast &
              s_axis_tdata(29 downto 22) & s_axis_tdata(19 downto 12) &
              s_axis_tdata(9 downto 2)))) when s_axis_tvalid = '1' else 0;
  valid(0) <= s_axis_tvalid;
  s_axis_tready <= ready(0) and aresetn;

  smooth_scales : for scale in 0 to 3 generate
    horizontal : entity work.portrait_smooth_axis
      generic map (G_WIDTH, G_HEIGHT, 2**scale, false, threshold_at(scale))
      port map (aclk, aresetn, word(2*scale), valid(2*scale), ready(2*scale),
                word(2*scale+1), valid(2*scale+1), ready(2*scale+1), 0, open);
    vertical : entity work.portrait_smooth_axis
      generic map (G_WIDTH, G_HEIGHT, 2**scale, true, threshold_at(scale))
      port map (aclk, aresetn, word(2*scale+1), valid(2*scale+1), ready(2*scale+1),
                word(2*scale+2), valid(2*scale+2), ready(2*scale+2), 0, open);
  end generate;

  -- Broader unthresholded context drives a local color decision. The detailed
  -- pixel and frame markers share the same transfer as their context center.
  context_horizontal : entity work.portrait_smooth_axis
    generic map (G_WIDTH => G_WIDTH, G_HEIGHT => G_HEIGHT, G_STEP => G_CONTEXT_STEP,
                 G_VERTICAL => false, G_THRESHOLD => 255,
                 G_FIXED_SPACING => true, G_CAPTURE_CENTER => true)
    port map (aclk, aresetn, word(8), valid(8), ready(8),
              word(9), valid(9), ready(9), 0, horizontal_detail);

  context_vertical : entity work.portrait_smooth_axis
    generic map (G_WIDTH => G_WIDTH, G_HEIGHT => G_HEIGHT, G_STEP => G_CONTEXT_STEP,
                 G_VERTICAL => true, G_THRESHOLD => 255,
                 G_FIXED_SPACING => true, G_FORWARD_DETAIL => true)
    port map (aclk, aresetn, word(9), valid(9), ready(9),
              word(10), valid(10), ready(10), horizontal_detail, aligned_detail);

  ready(10) <= ((not output_valid) or m_axis_tready) and aresetn;
  final_word <= std_logic_vector(to_unsigned(word(10), final_word'length));
  m_axis_tvalid <= output_valid;

  grade_and_pack : process(aclk)
    variable graded : std_logic_vector(23 downto 0);
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        output_valid <= '0';
        m_axis_tdata <= (others => '0');
        m_axis_tuser <= '0';
        m_axis_tlast <= '0';
      elsif ready(10) = '1' then
        output_valid <= valid(10);
        if valid(10) = '1' then
          graded := tone_with_context(std_logic_vector(to_unsigned(aligned_detail, 24)),
                                      final_word(23 downto 0));
          m_axis_tdata <= "00" & graded(23 downto 16) & graded(23 downto 22) &
                          graded(15 downto 8) & graded(15 downto 14) &
                          graded(7 downto 0) & graded(7 downto 6);
          m_axis_tuser <= final_word(25);
          m_axis_tlast <= final_word(24);
        end if;
      end if;
    end if;
  end process;
end architecture;
