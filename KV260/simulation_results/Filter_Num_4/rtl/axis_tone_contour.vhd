-- Scharr tangent linking, soft normal suppression and multiplicative color ink.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pic2_types.all;
use work.pic2_painterly_pkg.all;

entity axis_tone_contour is
  generic (
    G_WIDTH  : positive := 2048;
    G_HEIGHT : positive := 1152;
    G_SPACING      : positive := C_CONTOUR_STEP;
    G_CHROMA_Q8    : integer := C_CHROMA_Q8;
    G_EDGE_LOW     : mag_t := 22;
    G_EDGE_HIGH    : mag_t := 68;
    G_INK_STRENGTH : byte_t := 204;
    G_SHADOW_LIFT  : byte_t := 14
  );
  port (
    -- Clock, Reset, and Active Frame Geometry
    aclk          : in  std_logic;                     -- AXI4-Stream system clock
    aresetn       : in  std_logic;                     -- Synchronous active-low reset
    active_width  : in  std_logic_vector(15 downto 0); -- Active frame width
    active_height : in  std_logic_vector(15 downto 0); -- Active frame height

    -- AXI4-Stream Input Interface
    s_axis_tdata  : in  std_logic_vector(23 downto 0); -- Input RGB888 [23:16]=R, [15:8]=G, [7:0]=B
    s_axis_tvalid : in  std_logic;                     -- Input data valid
    s_axis_tready : out std_logic;                     -- Input backpressure ready
    s_axis_tuser  : in  std_logic;                     -- Start-of-Frame (SOF) marker
    s_axis_tlast  : in  std_logic;                     -- End-of-Line (EOL) marker

    -- AXI4-Stream Output Interface
    m_axis_tdata  : out std_logic_vector(23 downto 0); -- Reconstructed RGB888 output
    m_axis_tvalid : out std_logic;                     -- Output data valid
    m_axis_tready : in  std_logic;                     -- Downstream ready
    m_axis_tuser  : out std_logic;                     -- Output SOF marker
    m_axis_tlast  : out std_logic                      -- Output EOL marker
  );
end entity;

architecture rtl of axis_tone_contour is
  constant LATENCY : positive := 7;
  constant TONE : tone_lut_t := tone_lut(G_SHADOW_LIFT);
  constant ALPHA : mag_lut_t := ramp_lut(G_EDGE_LOW, G_EDGE_HIGH);
  -- Centers of the nine 3x3 Scharr operators on the 5x5 input window.
  type index9_t is array (0 to 8) of natural;
  constant CENTERS : index9_t := (6, 7, 8, 11, 12, 13, 16, 17, 18);
  type gradients_t is array (0 to 8) of gradient_t;
  type magnitudes_t is array (0 to 8) of mag_t;
  type dir_lumas_t is array (direction_t) of byte_t;
  type dir_indices_t is array (direction_t) of positive;
  constant PATCH_TANGENT : dir_indices_t := (1, 2, 3, 4);
  constant PATCH_NORMAL  : dir_indices_t := (3, 4, 1, 2);

  signal y1 : luma_window_t;
  signal color1, color2, tone3, tone4, tone5, tone6 : rgb_t;
  signal gradient2 : gradients_t;
  signal normal_mean2 : dir_lumas_t;
  signal y2 : byte_t;
  signal mags3 : magnitudes_t;
  signal direction3 : direction_t;
  signal valley3, valley4 : byte_t;
  signal flow4, flank4, edge5 : mag_t;
  signal scale6 : natural range 0 to 256;
  signal taps : std_logic_vector(599 downto 0);
  signal window_valid, window_sof, window_eol, advance : std_logic;
  signal valid_pipe, sof_pipe, eol_pipe : std_logic_vector(1 to LATENCY) := (others => '0');
  signal result_q : rgb_t;
begin
  advance <= not valid_pipe(LATENCY) or m_axis_tready;
  neighborhood : entity work.axis_window5
    generic map (G_WIDTH => G_WIDTH, G_HEIGHT => G_HEIGHT, G_SPACING => G_SPACING)
    port map (
      aclk => aclk, aresetn => aresetn, active_width => active_width, active_height => active_height,
      s_axis_tdata => s_axis_tdata, s_axis_tvalid => s_axis_tvalid, s_axis_tready => s_axis_tready,
      s_axis_tuser => s_axis_tuser, s_axis_tlast => s_axis_tlast,
      m_window_data => taps, m_valid => window_valid, m_ready => advance,
      m_sof => window_sof, m_eol => window_eol
    );

  markers : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        valid_pipe <= (others => '0');
        sof_pipe <= (others => '0');
        eol_pipe <= (others => '0');
      elsif advance = '1' then
        valid_pipe <= window_valid & valid_pipe(1 to LATENCY-1);
        sof_pipe <= window_sof & sof_pipe(1 to LATENCY-1);
        eol_pipe <= window_eol & eol_pipe(1 to LATENCY-1);
      end if;
    end if;
  end process;
  m_axis_tvalid <= valid_pipe(LATENCY);
  m_axis_tuser <= sof_pipe(LATENCY);
  m_axis_tlast <= eol_pipe(LATENCY);
  m_axis_tdata <= std_logic_vector(to_unsigned(pack(result_q), 24));

  contour : process(aclk)
    variable p : rgb_t;
    variable d : direction_t;
    variable t, n, ridge, response : natural;
    variable yc, delta : integer;
  begin
    if rising_edge(aclk) then
      if aresetn = '1' and advance = '1' then
        -- 1. A single 5x5 luma window contains all nine Scharr neighborhoods.
        if window_valid = '1' then
          for i in 0 to 24 loop
            p := read_tap(taps, i);
            y1(i) <= bt601(p);
          end loop;
          color1 <= read_tap(taps, 12);
        end if;

        -- 2. Compute signed gradients and pairs straddling the center.
        for i in CENTERS'range loop
          gradient2(i) <= scharr(y1, CENTERS(i));
        end loop;
        for dir in direction_t loop
          normal_mean2(dir) <= (y1(12-NORMAL(dir)) + y1(12+NORMAL(dir)))/2;
        end loop;
        y2 <= y1(12);
        color2 <= color1;

        -- 3. Approximate gradient magnitude, classify tangent, retain dark valleys.
        for i in mags3'range loop
          mags3(i) <= gradient_mag(gradient2(i));
        end loop;
        d := tangent_dir(gradient2(4));
        direction3 <= d;
        valley3 <= largest(0, normal_mean2(d) - y2);
        yc := TONE(y2);
        for k in 0 to 2 loop
          delta := ((integer(color2(k))-y2)*G_CHROMA_Q8)/256; -- truncate toward zero
          tone3(k) <= clamp(yc + delta, 0, 255);
        end loop;

        -- 4. Smooth along the tangent, then measure the stronger flank across the normal.
        t := PATCH_TANGENT(direction3);
        n := PATCH_NORMAL(direction3);
        flow4 <= (mags3(4-t) + 2*mags3(4) + mags3(4+t) + 2)/4;
        ridge := largest(mags3(4-n), mags3(4+n));
        flank4 <= largest(0, integer(ridge) - mags3(4));
        valley4 <= valley3;
        tone4 <= tone3;

        -- 5. Soft non-maximum suppression and dark-ridge fusion.
        response := largest(0, flow4 - 2*flank4);
        edge5 <= largest(response, 2*valley4);
        tone5 <= tone4;

        -- 6-7. Apply the same continuous multiplicative ink to every channel.
        scale6 <= 256 - ALPHA(edge5)*G_INK_STRENGTH/256;
        tone6 <= tone5;
        for k in 0 to 2 loop
          result_q(k) <= (tone6(k)*scale6 + 128)/256;
        end loop;
      end if;
    end if;
  end process;
end architecture;
