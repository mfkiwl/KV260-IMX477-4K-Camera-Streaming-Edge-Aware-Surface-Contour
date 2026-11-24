-- RGB888 AXI4-Stream PIC2 filter. Boundaries 1/2 smooth, 3 measures the
-- broad surround, 4 applies the fixed-point color and contour response, and
-- 5 smooths the remaining high-frequency transitions.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pic2_filter_axis is
  generic (
    G_WIDTH  : positive := 2048; -- Maximum hardware line-buffer width
    G_HEIGHT : positive := 1152; -- Maximum hardware frame height
    G_MEDIUM_STEP : positive := 3;
    G_COARSE_STEP : positive := 16;
    G_CONTOUR_STEP : positive := 4;
    G_CHROMA_Q8 : natural range 256 to 384 := 384;
    G_LEGACY_PIC2 : boolean := false
  );
  port (
    -- Clock, Synchronous Active-Low Reset, and Active Frame Geometry
    aclk          : in  std_logic;                     -- AXI4-Stream system clock
    aresetn       : in  std_logic;                     -- Synchronous active-low reset
    active_width  : in  std_logic_vector(15 downto 0); -- Active frame width in pixels
    active_height : in  std_logic_vector(15 downto 0); -- Active frame height in lines

    -- RGB888 AXI4-Stream Slave Input Interface (Boundary 0)
    s_axis_tdata  : in  std_logic_vector(23 downto 0); -- [23:16]=R, [15:8]=G, [7:0]=B
    s_axis_tvalid : in  std_logic;                     -- Input pixel valid
    s_axis_tready : out std_logic;                     -- Input ready backpressure
    s_axis_tuser  : in  std_logic;                     -- Start-of-Frame (SOF) marker
    s_axis_tlast  : in  std_logic;                     -- End-of-Line (EOL) marker

    -- RGB888 AXI4-Stream Master Output Interface (Boundary 5)
    m_axis_tdata  : out std_logic_vector(23 downto 0); -- Filtered RGB888 output
    m_axis_tvalid : out std_logic;                     -- Output pixel valid
    m_axis_tready : in  std_logic;                     -- Downstream ready backpressure
    m_axis_tuser  : out std_logic;                     -- Output Start-of-Frame (SOF) marker
    m_axis_tlast  : out std_logic                      -- Output End-of-Line (EOL) marker
  );
end entity pic2_filter_axis;

architecture rtl of pic2_filter_axis is

  -- ---------------------------------------------------------------------------
  -- Stage Configuration Constants & Inter-Stage Bus Types
  -- ---------------------------------------------------------------------------
  type surface_settings_t is array (0 to 1) of positive;
  constant C_SPACING   : surface_settings_t := (1, G_MEDIUM_STEP);
  constant C_TOLERANCE : surface_settings_t := (20, 14);
  signal wide_context, tone_context : std_logic_vector(31 downto 0);

  type pixel_bus_t is array (0 to 5) of std_logic_vector(23 downto 0);

  -- Inter-stage AXI4-Stream signals across boundaries 0 (input) through 5 (output)
  signal p   : pixel_bus_t;                  -- RGB888 pixel buses p(0)..p(5)
  signal v   : std_logic_vector(0 to 5);     -- Valid handshakes v(0)..v(5)
  signal r   : std_logic_vector(0 to 5);     -- Ready handshakes r(0)..r(5)
  signal sof : std_logic_vector(0 to 5);     -- Start-of-Frame sidebands sof(0)..sof(5)
  signal eol : std_logic_vector(0 to 5);     -- End-of-Line sidebands eol(0)..eol(5)

  type input_words_t is array (0 to 4) of std_logic_vector(23 downto 0);
  signal stage_data : input_words_t;
  signal stage_valid, stage_ready, stage_sof, stage_eol : std_logic_vector(0 to 4);

begin

  -- ---------------------------------------------------------------------------
  -- External AXI4-Stream Boundary Wiring (Boundary 0 and Boundary 5)
  -- ---------------------------------------------------------------------------
  p(0)          <= s_axis_tdata;
  v(0)          <= s_axis_tvalid;
  s_axis_tready <= r(0);
  sof(0)        <= s_axis_tuser;
  eol(0)        <= s_axis_tlast;

  m_axis_tdata  <= p(5);
  m_axis_tvalid <= v(5);
  r(5)          <= m_axis_tready;
  m_axis_tuser  <= sof(5);
  m_axis_tlast  <= eol(5);

  -- ---------------------------------------------------------------------------
  -- An empty skid buffer forwards the current beat. When the receiver stalls,
  -- store the accepted beat and block upstream until the receiver consumes it.
  -- Each upstream READY depends only on its local occupancy register.
  stage_inputs : for i in 0 to 4 generate
    signal occupied : std_logic := '0';
    signal saved_data : std_logic_vector(23 downto 0);
    signal saved_sof, saved_eol : std_logic;
  begin
    r(i) <= not occupied;
    stage_valid(i) <= occupied or v(i);
    stage_data(i) <= saved_data when occupied = '1' else p(i);
    stage_sof(i) <= saved_sof when occupied = '1' else sof(i);
    stage_eol(i) <= saved_eol when occupied = '1' else eol(i);

    -- The broad statistics follow exactly the same skid decision as their RGB beat.
    with_context : if i = 3 generate
      signal saved_context : std_logic_vector(31 downto 0);
    begin
      tone_context <= saved_context when occupied = '1' else wide_context;
      process (aclk)
      begin
        if rising_edge(aclk) then
          if aresetn = '1' and occupied = '0' and v(i) = '1' and stage_ready(i) = '0' then
            saved_context <= wide_context;
          end if;
        end if;
      end process;
    end generate;

    process (aclk)
    begin
      if rising_edge(aclk) then
        if aresetn = '0' then
          occupied <= '0';
        elsif stage_ready(i) = '1' then
          occupied <= '0';
        elsif occupied = '0' and v(i) = '1' then
          occupied <= '1';
          saved_data <= p(i);
          saved_sof <= sof(i);
          saved_eol <= eol(i);
        end if;
      end if;
    end process;
  end generate;

  -- Fine and medium edge-aware surface smoothing.
  gen_surfaces : for idx in 0 to 1 generate
    surfaces : entity work.axis_surface_pass
      generic map (
        G_WIDTH       => G_WIDTH,
        G_HEIGHT      => G_HEIGHT,
        G_SPACING     => C_SPACING(idx),
        G_TOLERANCE   => C_TOLERANCE(idx)
      )
      port map (
        aclk          => aclk,
        aresetn       => aresetn,
        active_width  => active_width,
        active_height => active_height,
        s_axis_tdata  => stage_data(idx),
        s_axis_tvalid => stage_valid(idx),
        s_axis_tready => stage_ready(idx),
        s_axis_tuser  => stage_sof(idx),
        s_axis_tlast  => stage_eol(idx),
        m_axis_tdata  => p(idx + 1),
        m_axis_tvalid => v(idx + 1),
        m_axis_tready => r(idx + 1),
        m_axis_tuser  => sof(idx + 1),
        m_axis_tlast  => eol(idx + 1)
      );
  end generate gen_surfaces;

  -- ---------------------------------------------------------------------------
  -- Carry the center RGB and broad surround to the fine contour window.
  surround : entity work.axis_surround
    generic map (G_WIDTH, G_HEIGHT, G_COARSE_STEP)
    port map (
      aclk => aclk, aresetn => aresetn, active_width => active_width, active_height => active_height,
      s_axis_tdata => stage_data(2), s_axis_tvalid => stage_valid(2), s_axis_tready => stage_ready(2),
      s_axis_tuser => stage_sof(2), s_axis_tlast => stage_eol(2),
      m_axis_tdata => p(3), m_context => wide_context, m_axis_tvalid => v(3), m_axis_tready => r(3),
      m_axis_tuser => sof(3), m_axis_tlast => eol(3));

  finish_pixel : entity work.axis_tone_contour
    generic map (
      G_WIDTH       => G_WIDTH,
      G_HEIGHT      => G_HEIGHT,
      G_SPACING     => G_CONTOUR_STEP,
      G_CHROMA_Q8   => G_CHROMA_Q8,
      G_LEGACY_PIC2 => G_LEGACY_PIC2
    )
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      active_width  => active_width,
      active_height => active_height,
      s_axis_tdata  => stage_data(3),
      s_context     => tone_context,
      s_axis_tvalid => stage_valid(3),
      s_axis_tready => stage_ready(3),
      s_axis_tuser  => stage_sof(3),
      s_axis_tlast  => stage_eol(3),
      m_axis_tdata  => p(4),
      m_axis_tvalid => v(4),
      m_axis_tready => r(4),
      m_axis_tuser  => sof(4),
      m_axis_tlast  => eol(4)
    );

  -- ---------------------------------------------------------------------------
  -- Edge-directed smoothing at two-pixel spacing.
  antialias : entity work.axis_contour_finish
    generic map (
      G_WIDTH       => G_WIDTH,
      G_HEIGHT      => G_HEIGHT,
      G_SPACING     => 2
    )
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      active_width  => active_width,
      active_height => active_height,
      s_axis_tdata  => stage_data(4),
      s_axis_tvalid => stage_valid(4),
      s_axis_tready => stage_ready(4),
      s_axis_tuser  => stage_sof(4),
      s_axis_tlast  => stage_eol(4),
      m_axis_tdata  => p(5),
      m_axis_tvalid => v(5),
      m_axis_tready => r(5),
      m_axis_tuser  => sof(5),
      m_axis_tlast  => eol(5)
    );

end architecture rtl;
