library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.designer_geometry.all;

-- Profile 3 preserves the native RGB888 raster. Profile 2 uses the original artwork framing.
entity designer_filter_axis is
  generic (
    G_MEDIUM_STEP : positive := 3; G_COARSE_STEP : positive := 6;
    G_CONTOUR_STEP : positive := 6; G_CHROMA_Q8 : natural range 256 to 384 := 384;
    G_PROFILE : profile_t := 3; G_WIDTH : positive := INPUT_WIDTH; G_HEIGHT : positive := INPUT_HEIGHT
  );
  port (
    aclk, aresetn : in std_logic;
    s_axis_tdata : in std_logic_vector(23 downto 0);
    s_axis_tvalid, s_axis_tuser, s_axis_tlast : in std_logic;
    s_axis_tready : out std_logic;
    m_axis_tdata : out std_logic_vector(23 downto 0);
    m_axis_tvalid, m_axis_tuser, m_axis_tlast : out std_logic;
    m_axis_tready : in std_logic;
    s_axis_meter_only : in std_logic := '0' -- sampled with the accepted SOF
  );
end entity;

architecture rtl of designer_filter_axis is
  constant W : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(G_WIDTH,16));
  constant H : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(G_HEIGHT,16));
  signal conditioned : std_logic_vector(23 downto 0);
  signal cv, cr, cs, cl : std_logic;
  type pixels_t is array(0 to 3) of std_logic_vector(23 downto 0);
  signal pixels : pixels_t;
  signal valid, ready, sof, eol : std_logic_vector(0 to 3);
begin
  assert G_PROFILE/=2 or (G_WIDTH=INPUT_WIDTH and G_HEIGHT=INPUT_HEIGHT)
    report "Profile 2 artwork framing requires a 2048 x 1152 source" severity failure;

  input_exposure : entity work.axis_scene_exposure
    generic map (G_WIDTH=>G_WIDTH, G_HEIGHT=>G_HEIGHT)
    port map (aclk=>aclk, aresetn=>aresetn, s_axis_meter_only=>s_axis_meter_only,
      s_axis_tdata=>s_axis_tdata, s_axis_tvalid=>s_axis_tvalid, s_axis_tready=>s_axis_tready,
      s_axis_tuser=>s_axis_tuser, s_axis_tlast=>s_axis_tlast,
      m_axis_tdata=>conditioned, m_axis_tvalid=>cv, m_axis_tready=>cr, m_axis_tuser=>cs, m_axis_tlast=>cl);

  camera_filter : entity work.pic2_filter_axis
    generic map(G_WIDTH=>G_WIDTH,G_HEIGHT=>G_HEIGHT,G_MEDIUM_STEP=>G_MEDIUM_STEP,
                G_COARSE_STEP=>G_COARSE_STEP,G_CONTOUR_STEP=>G_CONTOUR_STEP,G_CHROMA_Q8=>G_CHROMA_Q8)
    port map(aclk=>aclk,aresetn=>aresetn,active_width=>W,active_height=>H,
      s_axis_tdata=>conditioned,s_axis_tvalid=>cv,s_axis_tready=>cr,
      s_axis_tuser=>cs,s_axis_tlast=>cl,
      m_axis_tdata=>pixels(0),m_axis_tvalid=>valid(0),m_axis_tready=>ready(0),
      m_axis_tuser=>sof(0),m_axis_tlast=>eol(0));

  broad_surface : entity work.axis_surface_pass
    generic map(G_WIDTH=>G_WIDTH,G_HEIGHT=>G_HEIGHT,G_SPACING=>3,G_TOLERANCE=>18)
    port map(aclk=>aclk,aresetn=>aresetn,active_width=>W,active_height=>H,
      s_axis_tdata=>pixels(0),s_axis_tvalid=>valid(0),s_axis_tready=>ready(0),
      s_axis_tuser=>sof(0),s_axis_tlast=>eol(0),
      m_axis_tdata=>pixels(1),m_axis_tvalid=>valid(1),m_axis_tready=>ready(1),
      m_axis_tuser=>sof(1),m_axis_tlast=>eol(1));

  surface_grade : entity work.axis_designer_grade
    generic map(G_WIDTH=>G_WIDTH,G_HEIGHT=>G_HEIGHT)
    port map(aclk=>aclk,aresetn=>aresetn,
      s_axis_tdata=>pixels(1),s_axis_tvalid=>valid(1),s_axis_tready=>ready(1),
      s_axis_tuser=>sof(1),s_axis_tlast=>eol(1),
      m_axis_tdata=>pixels(2),m_axis_tvalid=>valid(2),m_axis_tready=>ready(2),
      m_axis_tuser=>sof(2),m_axis_tlast=>eol(2));

  view_stage : entity work.axis_designer_view
    generic map(G_PROFILE=>G_PROFILE)
    port map(aclk=>aclk,aresetn=>aresetn,
      s_axis_tdata=>pixels(2),s_axis_tvalid=>valid(2),s_axis_tready=>ready(2),
      s_axis_tuser=>sof(2),s_axis_tlast=>eol(2),
      m_axis_tdata=>pixels(3),m_axis_tvalid=>valid(3),m_axis_tready=>ready(3),
      m_axis_tuser=>sof(3),m_axis_tlast=>eol(3));

  fine_outline : entity work.axis_designer_ink
    generic map(G_PROFILE=>G_PROFILE,G_WIDTH=>G_WIDTH,G_HEIGHT=>output_height(G_PROFILE,G_HEIGHT))
    port map(aclk=>aclk,aresetn=>aresetn,
      s_axis_tdata=>pixels(3),s_axis_tvalid=>valid(3),s_axis_tready=>ready(3),
      s_axis_tuser=>sof(3),s_axis_tlast=>eol(3),
      m_axis_tdata=>m_axis_tdata,m_axis_tvalid=>m_axis_tvalid,m_axis_tready=>m_axis_tready,
      m_axis_tuser=>m_axis_tuser,m_axis_tlast=>m_axis_tlast);
end architecture;
