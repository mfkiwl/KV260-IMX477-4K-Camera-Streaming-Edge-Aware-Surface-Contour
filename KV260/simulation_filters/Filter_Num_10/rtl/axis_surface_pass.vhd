-- Softly weighted, overlapping 3x3 Kuwahara quadrants on a 5x5 window.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pic2_types.all;
use work.pic2_painterly_pkg.all;

entity axis_surface_pass is
  generic (
    G_WIDTH  : positive := 2048;
    G_HEIGHT : positive := 1152;
    G_SPACING    : positive := 1;
    -- Retain the original fourth generic; it now sets the default soft-weight scale.
    G_TOLERANCE  : natural := 14;
    G_SIGMA      : natural range 1 to 53 := clamp(G_TOLERANCE, 1, 53);
    G_CENTER_CAP : byte_t := 16
  );
  port (
    -- Clock, Reset, and Frame Geometry
    aclk          : in  std_logic;                     -- AXI4-Stream system clock
    aresetn       : in  std_logic;                     -- Synchronous active-low reset
    active_width  : in  std_logic_vector(15 downto 0); -- Active frame width
    active_height : in  std_logic_vector(15 downto 0); -- Active frame height

    -- AXI4-Stream Input Interface
    s_axis_tdata  : in  std_logic_vector(23 downto 0); -- Input RGB888 [23:16]=R, [15:8]=G, [7:0]=B
    s_axis_tvalid : in  std_logic;                     -- Input data valid
    s_axis_tready : out std_logic;                     -- Input ready backpressure
    s_axis_tuser  : in  std_logic;                     -- Start-of-Frame (SOF) marker
    s_axis_tlast  : in  std_logic;                     -- End-of-Line (EOL) marker

    -- AXI4-Stream Output Interface
    m_axis_tdata  : out std_logic_vector(23 downto 0); -- Filtered RGB888 output
    m_axis_tvalid : out std_logic;                     -- Output data valid
    m_axis_tready : in  std_logic;                     -- Downstream ready
    m_axis_tuser  : out std_logic;                     -- Output SOF marker
    m_axis_tlast  : out std_logic                      -- Output EOL marker
  );
end entity;

architecture rtl of axis_surface_pass is
  constant LATENCY : positive := 8;
  constant DECAY : decay_lut_t := decay_lut(G_SIGMA);
  constant RECIP : recip_lut_t := recip_lut;
  subtype strip_sum_t is natural range 0 to 1020;
  subtype score_t is natural range 0 to 382; -- luma span + max RGB span/2
  subtype product_t is natural range 0 to 65025;
  type sums_t is array (0 to 2) of strip_sum_t;
  type strip_t is record
    sums : sums_t;
    lo, hi : rgb_t;
    ymin, ymax : byte_t;
  end record;
  type strips_t is array (0 to 4, 0 to 1) of strip_t;
  type colors4_t is array (0 to 3) of rgb_t;
  type scores4_t is array (0 to 3) of score_t;
  type weights4_t is array (0 to 3) of byte_t;
  type products_t is array (0 to 3, 0 to 2) of product_t;
  type accum_t is array (0 to 2) of unsigned(17 downto 0);
  type center_delays_t is array (1 to LATENCY-1) of rgb_t;

  -- A thin line is a local valley/crest across its normal with a similar
  -- neighbor along its tangent. An isolated impulse lacks tangent support.
  type dir_scores_t is array (direction_t) of byte_t;
  function ridge_contrast(a, center_y, b : byte_t) return byte_t is
  begin
    return largest(0, largest(smallest(a,b)-center_y, center_y-largest(a,b)));
  end;

  signal cross2, along2 : dir_scores_t;
  signal ridge3 : byte_t;
  signal colors1 : rgb_window_t;
  signal luma1 : luma_window_t;
  signal strips2 : strips_t;
  signal means3, means4 : colors4_t;
  signal scores3 : scores4_t;
  signal weights4 : weights4_t;
  signal products5 : products_t;
  signal sum_weights5 : natural range 0 to 1020;
  signal acc6 : accum_t;
  signal inverse6 : unsigned(16 downto 0);
  signal smooth7 : rgb_t;
  signal center : center_delays_t;
  signal keep4, keep5, keep6, keep7 : byte_t;
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

  surface : process(aclk)
    variable p : rgb_t;
    variable i, row, col, span, best, total : natural;
    variable a, b, c : strip_t;
    variable s : strip_t;
    variable scaled : unsigned(34 downto 0);
    variable n, tangent_offset, near_ridge, far_ridge, supported, line_keep : natural;
  begin
    if rising_edge(aclk) then
      if aresetn = '1' and advance = '1' then
        -- 1. Sample a row-major window and compute luminance once per tap.
        if window_valid = '1' then
          for t in 0 to 24 loop
            p := read_tap(taps, t);
            colors1(t) <= p;
            luma1(t) <= bt601(p);
          end loop;
          center(1) <= read_tap(taps, 12);
        end if;
        for stage in 2 to LATENCY-1 loop
          center(stage) <= center(stage-1);
        end loop;

        -- 2. Ten reusable 1-2-1 horizontal strips and their color/luma extrema.
        for r in 0 to 4 loop
          for half in 0 to 1 loop
            i := 5*r + 2*half;
            for k in 0 to 2 loop
              s.sums(k) := colors1(i)(k) + 2*colors1(i+1)(k) + colors1(i+2)(k);
              s.lo(k) := smallest(colors1(i)(k), smallest(colors1(i+1)(k), colors1(i+2)(k)));
              s.hi(k) := largest(colors1(i)(k), largest(colors1(i+1)(k), colors1(i+2)(k)));
            end loop;
            s.ymin := smallest(luma1(i), smallest(luma1(i+1), luma1(i+2)));
            s.ymax := largest(luma1(i), largest(luma1(i+1), luma1(i+2)));
            strips2(r, half) <= s;
          end loop;
        end loop;

        if G_SPACING = 1 then
          for dir in direction_t loop
            n := NORMAL(dir);
            tangent_offset := TANGENT(dir);
            near_ridge := ridge_contrast(luma1(12-n), luma1(12), luma1(12+n));
            far_ridge := ridge_contrast(luma1(12-2*n), luma1(12), luma1(12+2*n));
            cross2(dir) <= largest(near_ridge, far_ridge);
            along2(dir) <= smallest(magnitude(luma1(12-tangent_offset)-luma1(12)), magnitude(luma1(12+tangent_offset)-luma1(12)));
          end loop;
          supported := 0;
          for dir in direction_t loop
            supported := largest(supported, cross2(dir)-along2(dir));
          end loop;
          ridge3 <= supported;
        end if;

        -- 3. Overlapping quadrants use binomial means and a continuous range score.
        for q in 0 to 3 loop
          row := 2*(q/2);
          col := q mod 2;
          a := strips2(row, col);
          b := strips2(row+1, col);
          c := strips2(row+2, col);
          span := 0;
          for k in 0 to 2 loop
            means3(q)(k) <= (a.sums(k) + 2*b.sums(k) + c.sums(k) + 8)/16;
            span := largest(span, largest(a.hi(k), largest(b.hi(k), c.hi(k))) -
                                  smallest(a.lo(k), smallest(b.lo(k), c.lo(k))));
          end loop;
          scores3(q) <= largest(a.ymax, largest(b.ymax,c.ymax)) -
                        smallest(a.ymin, smallest(b.ymin,c.ymin)) + span/2;
        end loop;

        -- 4. Quartic edge-stopping weights and detail-dependent center retention.
        means4 <= means3;
        best := smallest(smallest(scores3(0), scores3(1)), smallest(scores3(2), scores3(3)));
        if G_SPACING = 1 then
          line_keep := clamp(8*(integer(ridge3)-8), 0, 248);
        else
          -- At coarse spacing a fine stroke may fall between tangent taps.
          -- Trust its center when even the most homogeneous quadrant crosses it.
          line_keep := clamp(5*(integer(best)-28), 0, 248);
        end if;
        keep4 <= largest(line_keep, smallest(G_CENTER_CAP, largest(0, integer(best)-24)/2));
        for q in 0 to 3 loop
          weights4(q) <= DECAY(smallest(63, scores3(q)/2));
        end loop;

        -- 5-6. Products, balanced accumulation and a Q18 reciprocal ROM.
        keep5 <= keep4;
        for q in 0 to 3 loop
          for k in 0 to 2 loop
            products5(q,k) <= weights4(q)*means4(q)(k);
          end loop;
        end loop;
        sum_weights5 <= (weights4(0)+weights4(1)) + (weights4(2)+weights4(3));
        inverse6 <= RECIP(sum_weights5);
        keep6 <= keep5;
        for k in 0 to 2 loop
          total := (products5(0,k)+products5(1,k)) + (products5(2,k)+products5(3,k));
          acc6(k) <= to_unsigned(total, 18);
        end loop;

        -- 7-8. Normalize and blend the unfiltered center only in difficult neighborhoods.
        keep7 <= keep6;
        for k in 0 to 2 loop
          if valid_pipe(6) = '1' then
            scaled := acc6(k) * inverse6 + to_unsigned(131072, 35);
            smooth7(k) <= smallest(255, to_integer(scaled(34 downto 18)));
          end if;
          result_q(k) <= ((256-keep7)*smooth7(k) + keep7*center(7)(k) + 128)/256;
        end loop;
      end if;
    end if;
  end process;
end architecture;
