library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.live_tone_pkg.all;

entity axis_portrait_filter is
  generic (
    G_WIDTH          : positive := 2048;
    G_HEIGHT         : positive := 1152;
    G_THRESHOLD_BASE : natural range 0 to 255 := 16;
    G_SECTOR_RADIUS  : positive range 1 to 7 := 4;
    G_CONTEXT_STEP   : positive := 16;
    G_STRUCTURE_STEP : positive := 4;
    G_FINISH_SCALES  : natural range 0 to 3 := 3;
    G_FINISH_THRESHOLD : natural range 0 to 255 := 24;
    G_MEDIUM_STEP    : positive := 6;
    G_CONTOUR_PRE_STEP : positive := 2;
    G_FINE_STEP : positive := 2
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
  type word_array is array (natural range <>) of natural range 0 to 2**26-1;
  signal word  : word_array(0 to 7);
  signal valid : std_logic_vector(0 to 7);
  signal ready : std_logic_vector(0 to 7);
  type ridge_array is array (natural range <>) of natural range 0 to 2**28-1;
  signal ridge : ridge_array(4 to 7);
  signal fine_rgb, horizontal_rgb, center_rgb : natural range 0 to 2**24-1;
  signal luma_in, luma_h : natural range 0 to 2**26-1;
  signal luma_valid, luma_ready : std_logic;
  signal horizontal_detail, aligned_detail : natural range 0 to 2**24-1;
  signal directional, measured_h : natural range 0 to 2**28-1;
  signal contour_word, fine_h_word : natural range 0 to 2**26-1;
  signal contour_valid, contour_ready, fine_h_valid, fine_h_ready : std_logic;
  signal final_word : std_logic_vector(25 downto 0);
  constant C_LAST : natural := 2*G_FINISH_SCALES;
  signal finish_word : word_array(0 to C_LAST);
  signal finish_ready, finish_valid : std_logic_vector(0 to C_LAST);
  signal tone0 : local_tone_t;
  signal tone1 : graded_t;
  signal flag0,flag1 : std_logic_vector(1 downto 0);
  signal tone_valid0,tone_valid1 : std_logic;
  signal clean_mid,clean_word : natural range 0 to 2**26-1;
  signal clean_mean : natural range 0 to 2**24-1;
  signal clean_range : natural range 0 to 2**28-1;
  signal clean_valid,clean_ready : std_logic;
  signal guides : ridge_array(0 to C_LAST);
  signal guide0,guide1 : natural range 0 to 2**20-1;
  signal stroke_word : natural range 0 to 2**26-1;
  signal stroke_valid,stroke_ready : std_logic;
  signal output_rgb : std_logic_vector(25 downto 0);
begin
  -- RGB10 is R[29:20], G[19:10], B[9:0]. Filter arithmetic uses the top 8 bits.
  word(0) <= to_integer(unsigned(std_logic_vector'(s_axis_tuser & s_axis_tlast &
              s_axis_tdata(29 downto 22) & s_axis_tdata(19 downto 12) &
              s_axis_tdata(9 downto 2)))) when s_axis_tvalid = '1' else 0;
  valid(0) <= s_axis_tvalid;
  s_axis_tready <= ready(0) and aresetn;

  -- Fine denoising precedes the split. All downstream branches refer to the
  -- same center pixel even when ready or valid inserts gaps between transfers.
  fine : for axis in 0 to 1 generate
    pass : entity work.portrait_smooth_axis
      generic map (G_WIDTH, G_HEIGHT, 1, axis=1, G_THRESHOLD_BASE)
      port map (aclk, aresetn, word(axis), valid(axis), ready(axis),
                word(axis+1), valid(axis+1), ready(axis+1), 0, open, 0, open);
  end generate;

  -- Keep two fractional luma bits in the contour branch. The denoised RGB
  -- travels with it so the surface selector receives the same center pixel.
  fine_rgb <= word(2) mod 2**24;
  luma_in <= (word(2)/2**24)*2**24 + fine_rgb/65536 +
             2*(fine_rgb/256 mod 256) + fine_rgb mod 256;
  contour_pre_horizontal : entity work.portrait_smooth_axis
    generic map (G_WIDTH, G_HEIGHT, G_CONTOUR_PRE_STEP, false, 255,
                 G_FORWARD_DETAIL => true, G_SMOOTH_LUMA => true)
    port map (aclk, aresetn, luma_in, valid(2), ready(2), luma_h, luma_valid,
              luma_ready, fine_rgb, horizontal_rgb, 0, open);
  contour_pre_vertical : entity work.portrait_smooth_axis
    generic map (G_WIDTH, G_HEIGHT, G_CONTOUR_PRE_STEP, true, 255,
                 G_FORWARD_DETAIL => true, G_SMOOTH_LUMA => true)
    port map (aclk, aresetn, luma_h, luma_valid, luma_ready, word(3),
              valid(3), ready(3), horizontal_rgb, center_rgb, 0, open);

  contours : entity work.portrait_contour_axis
    generic map (G_WIDTH, G_HEIGHT, G_FINE_STEP, G_MEDIUM_STEP)
    port map (aclk, aresetn, word(3), center_rgb, valid(3), ready(3),
              contour_word, directional, contour_valid, contour_ready);

  -- Measure narrow axial ridges on the denoised RGB itself. Keep the independent
  -- two-scale directional mask in the low 16 bits through these center delays.
  axial_horizontal : entity work.portrait_smooth_axis
    generic map (G_WIDTH, G_HEIGHT, G_STRUCTURE_STEP, false, 255,
                 G_FORWARD_RIDGE => true, G_MEASURE_FINE => true)
    port map (aclk, aresetn, contour_word, contour_valid, contour_ready,
              fine_h_word, fine_h_valid, fine_h_ready, 0, open, directional, measured_h);
  axial_vertical : entity work.portrait_smooth_axis
    generic map (G_WIDTH, G_HEIGHT, G_STRUCTURE_STEP, true, 255,
                 G_FORWARD_RIDGE => true, G_MEASURE_FINE => true)
    port map (aclk, aresetn, fine_h_word, fine_h_valid, fine_h_ready,
              word(4), valid(4), ready(4), 0, open, measured_h, ridge(4));

  -- Choose the smoothest local color region. The mask remains the fine
  -- center pixel's measurement even when an off-center region supplies color.
  surface : entity work.portrait_sector
    generic map (G_WIDTH => G_WIDTH, G_HEIGHT => G_HEIGHT, G_RADIUS => G_SECTOR_RADIUS)
    port map (aclk => aclk, aresetn => aresetn,
              s_word => word(4), s_ridge => ridge(4), s_valid => valid(4), s_ready => ready(4),
              m_word => word(5), m_ridge => ridge(5), m_valid => valid(5), m_ready => ready(5));

  -- Broader unthresholded context drives a local color decision. The detailed
  -- pixel and frame markers share the same transfer as their context center.
  context_horizontal : entity work.portrait_smooth_axis
    generic map (G_WIDTH => G_WIDTH, G_HEIGHT => G_HEIGHT, G_STEP => G_CONTEXT_STEP,
                 G_VERTICAL => false, G_THRESHOLD => 255,
                 G_CAPTURE_CENTER => true, G_FORWARD_RIDGE => true)
    port map (aclk, aresetn, word(5), valid(5), ready(5),
              word(6), valid(6), ready(6), 0, horizontal_detail, ridge(5), ridge(6));

  context_vertical : entity work.portrait_smooth_axis
    generic map (G_WIDTH => G_WIDTH, G_HEIGHT => G_HEIGHT, G_STEP => G_CONTEXT_STEP,
                 G_VERTICAL => true, G_THRESHOLD => 255,
                 G_FORWARD_DETAIL => true, G_FORWARD_RIDGE => true)
    port map (aclk, aresetn, word(6), valid(6), ready(6),
              word(7), valid(7), ready(7), horizontal_detail, aligned_detail, ridge(6), ridge(7));

  ready(7) <= ((not finish_valid(0)) or finish_ready(0)) and aresetn;
  final_word <= std_logic_vector(to_unsigned(word(7), final_word'length));
  compose : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn='0' then
        tone_valid0<='0'; tone_valid1<='0'; finish_valid(0)<='0';
        finish_word(0)<=0; guides(0)<=0;
      elsif ready(7)='1' then
        tone_valid0<=valid(7); tone_valid1<=tone_valid0; finish_valid(0)<=tone_valid1;
        if valid(7)='1' then
          tone0<=local_tone(std_logic_vector(to_unsigned(aligned_detail,24)),final_word(23 downto 0),ridge(7));
          flag0<=final_word(25 downto 24);
          guide0<=work.stroke_math_pkg.source_guide(std_logic_vector(to_unsigned(aligned_detail,24)),final_word(23 downto 0));
        end if;
        if tone_valid0='1' then
          tone1<=grade(tone0);
          flag1<=flag0; guide1<=guide0;
        end if;
        if tone_valid1='1' then
          finish_word(0)<=to_integer(unsigned(flag1 & render(tone1))); guides(0)<=guide1;
        end if;
      end if;
    end if;
  end process;

  -- Consolidate similar colors and restore qualified midrange transitions at the two larger scales.
  finish : for scale in 1 to G_FINISH_SCALES generate
    axis_pair : for axis in 0 to 1 generate
      constant idx : natural := 2*(scale-1)+axis;
    begin
      pass : entity work.portrait_smooth_axis
        generic map (G_WIDTH, G_HEIGHT, 2**(scale-1), axis=1, G_FINISH_THRESHOLD,
                     G_SURFACE_FINISH => true, G_RECONSTRUCT => scale>=2, G_FORWARD_RIDGE => true)
        port map (aclk, aresetn, finish_word(idx), finish_valid(idx), finish_ready(idx),
                  finish_word(idx+1), finish_valid(idx+1), finish_ready(idx+1),
                  0, open, guides(idx), guides(idx+1));
    end generate;
  end generate;
  strokes : entity work.portrait_stroke_axis
    generic map (G_WIDTH,G_HEIGHT)
    port map (aclk,aresetn,finish_word(C_LAST),guides(C_LAST),finish_valid(C_LAST),finish_ready(C_LAST),
              stroke_word,stroke_valid,stroke_ready);

  -- Remove an impulse only when left, right, above and below all support the change.
  impulse_horizontal : entity work.portrait_smooth_axis
    generic map (G_WIDTH,G_HEIGHT,1,false,255,G_IMPULSE_STAGE=>1)
    port map (aclk,aresetn,stroke_word,stroke_valid,stroke_ready,
              clean_mid,clean_valid,clean_ready,0,clean_mean,0,clean_range);
  impulse_vertical : entity work.portrait_smooth_axis
    generic map (G_WIDTH,G_HEIGHT,1,true,255,G_FORWARD_DETAIL=>true,G_FORWARD_RIDGE=>true,G_IMPULSE_STAGE=>2)
    port map (aclk,aresetn,clean_mid,clean_valid,clean_ready,clean_word,m_axis_tvalid,m_axis_tready,
              clean_mean,open,clean_range,open);
  output_rgb <= std_logic_vector(to_unsigned(clean_word,26));
  m_axis_tuser <= output_rgb(25);
  m_axis_tlast <= output_rgb(24);
  m_axis_tdata <= "00" & output_rgb(23 downto 16) & output_rgb(23 downto 22) &
                         output_rgb(15 downto 8) & output_rgb(15 downto 14) &
                         output_rgb(7 downto 0) & output_rgb(7 downto 6);
end architecture;
