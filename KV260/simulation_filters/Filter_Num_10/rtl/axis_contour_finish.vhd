-- Five-tap anti-aliasing along contours and edge-limited polish on surfaces.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pic2_types.all;
use work.pic2_painterly_pkg.all;

entity axis_contour_finish is
  generic (
    G_WIDTH  : positive := 2048;
    G_HEIGHT : positive := 1152;
    G_SPACING       : positive := 1;
    G_DIFF_THRESH   : natural := 18; -- original fourth generic, now the surface clamp
    G_TANGENT_CLAMP : byte_t := 36;
    G_SURFACE_CLAMP : byte_t := clamp(G_DIFF_THRESH, 0, 255);
    G_AA_LOW        : mag_t := 16;
    G_AA_HIGH       : mag_t := 48
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
    m_axis_tdata  : out std_logic_vector(23 downto 0); -- Final smoothed RGB888 output
    m_axis_tvalid : out std_logic;                     -- Output data valid
    m_axis_tready : in  std_logic;                     -- Downstream ready
    m_axis_tuser  : out std_logic;                     -- Output SOF marker
    m_axis_tlast  : out std_logic                      -- Output EOL marker
  );
end entity;

architecture rtl of axis_contour_finish is
  constant LATENCY : positive := 5;
  constant AA_WEIGHT : mag_lut_t := ramp_lut(G_AA_LOW, G_AA_HIGH);
  type dist_t is array (0 to 24) of byte_t;
  type kernel_t is array (0 to 2) of positive;
  constant K3 : kernel_t := (1, 2, 1);
  type five_t is array (0 to 4) of rgb_t;

  signal pixels1, pixels2, tangent3, surface3 : rgb_window_t;
  signal y1 : luma_window_t;
  signal dist2 : dist_t;
  signal gradient2 : gradient_t;
  signal direction3 : direction_t;
  signal mix3, mix4 : byte_t;
  signal along4, flat4 : rgb_t;
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

  polish : process(aclk)
    variable p : rgb_t;
    variable t : positive;
    variable sample : five_t;
    variable total : natural;
  begin
    if rising_edge(aclk) then
      if aresetn = '1' and advance = '1' then
        -- 1-2. Estimate the orientation on the inked RGB, aligned to this window.
        if window_valid = '1' then
          for i in 0 to 24 loop
            p := read_tap(taps, i);
            pixels1(i) <= p;
            y1(i) <= bt601(p);
          end loop;
        end if;
        pixels2 <= pixels1;
        gradient2 <= scharr(y1, 12);
        for i in 0 to 24 loop
          dist2(i) <= distance(pixels1(i), pixels1(12));
        end loop;

        -- 3. A strong color jump is replaced by the center before averaging.
        direction3 <= tangent_dir(gradient2);
        mix3 <= AA_WEIGHT(gradient_mag(gradient2));
        for i in 0 to 24 loop
          if dist2(i) <= G_TANGENT_CLAMP then tangent3(i) <= pixels2(i);
          else tangent3(i) <= pixels2(12);
          end if;
          if dist2(i) <= G_SURFACE_CLAMP then surface3(i) <= pixels2(i);
          else surface3(i) <= pixels2(12);
          end if;
        end loop;

        -- 4. Five-tap binomial along the stroke; 3x3 binomial on the surface.
        t := TANGENT(direction3);
        for i in 0 to 4 loop
          sample(i) := tangent3(12 + (i-2)*t);
        end loop;
        for k in 0 to 2 loop
          along4(k) <= (sample(0)(k)+sample(4)(k) + 4*(sample(1)(k)+sample(3)(k)) +
                        6*sample(2)(k) + 8)/16;
          total := 8;
          for y in 0 to 2 loop
            for x in 0 to 2 loop
              total := total + K3(y)*K3(x)*surface3(6+y*5+x)(k);
            end loop;
          end loop;
          flat4(k) <= total/16;
        end loop;
        mix4 <= mix3;

        -- 5. A continuous strength ramp crossfades surface and tangent filters.
        for k in 0 to 2 loop
          result_q(k) <= ((255-mix4)*flat4(k) + mix4*along4(k) + 128)/255;
        end loop;
      end if;
    end if;
  end process;
end architecture;
