library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pic2_types.all;

-- Continuous, fixed-point portrait grade. The centre and eight surrounding
-- samples come from the live native filter. Coordinates only address its line RAM.
entity axis_designer1_live is
  generic (G_WIDTH : positive := 2048; G_HEIGHT : positive := 1152);
  port (
    aclk, aresetn : in std_logic;
    active_width, active_height : in std_logic_vector(15 downto 0);
    s_axis_tdata : in std_logic_vector(23 downto 0);
    s_axis_tvalid, s_axis_tuser, s_axis_tlast : in std_logic;
    s_axis_tready : out std_logic;
    m_axis_tdata : out std_logic_vector(23 downto 0);
    m_axis_tvalid, m_axis_tuser, m_axis_tlast : out std_logic;
    m_axis_tready : in std_logic
  );
end entity;

architecture rtl of axis_designer1_live is
  type tap_list_t is array (0 to 7) of natural;
  constant RING : tap_list_t := (0, 2, 4, 10, 14, 20, 22, 24);
  type direction_t is array (0 to 5) of integer range -4 to 4;
  type gain_t is array (0 to 2) of integer range -2048 to 2047;
  type gain_table_t is array (natural range <>) of gain_t;
  type ramp_t is record
    direction : direction_t;
    threshold : integer range -512 to 511;
    width : integer range 1 to 32;
    gain : gain_t;
  end record;
  type ramp_table_t is array (natural range <>) of ramp_t;
  constant BASE_GAIN : gain_table_t(0 to 6) := (
    (-170, -149, -77),
    (-25, 3, -10),
    (-110, -65, -79),
    (40, 100, 147),
    (-12, -14, -13),
    (-8, -24, -4),
    (14, 17, 22)
  );
  -- Direction, lower threshold, width and signed RGB gains in Q7.
  constant RAMPS : ramp_table_t(0 to 48) := (
    ((0, 1, 0, 0, 0, 0),    0, 16, (167, -30, -5)),
    ((1, 2, 2, 0, 0, 0),  112, 16, (174, 97, 1)),
    ((1, -2, -1, 0, 0, 0),  128, 16, (-63, -15, -38)),
    ((1, -2, -1, 0, 0, 0),   96,  8, (230, 152, 157)),
    ((0, 1, -1, 0, 0, 0),  -32, 16, (119, 239, 265)),
    ((1, 0, 0, -2, 0, 0),   96, 32, (28, 7, -12)),
    ((0, 1, 1, 0, 1, 1),    8,  4, (283, 257, -44)),
    ((1, -1, 0, 0, 0, 0),   88,  8, (-136, -168, -121)),
    ((0, 2, -1, 0, 2, -1),   -4,  4, (143, 19, -114)),
    ((1, -2, 1, 0, 0, 0),  192, 32, (-79, -56, -28)),
    ((1, 0, -2, 1, 0, -2),   64, 16, (43, 58, 62)),
    ((1, 4, -2, 0, 0, 0),   64, 16, (-44, -1, 16)),
    ((1, 2, -4, 1, 2, -4),   32, 16, (55, 71, 70)),
    ((0, 0, 0, -2, 0, 0),  -80,  4, (-116, -75, 79)),
    ((1, 0, 0, -2, 0, 0),  -16,  8, (-97, -5, 8)),
    ((0, 0, 1, 0, -2, 0),  -16, 16, (48, -47, -88)),
    ((1, -1, 0, 0, 0, 0),   48, 16, (-198, -204, -138)),
    ((0, 0, 1, 0, 0, -2),  -28,  4, (320, 36, -231)),
    ((0, 1, 0, -2, 0, 0),  -40,  8, (-115, -18, 1)),
    ((0, 1, 0, 0, 0, 1),    4,  4, (-242, -106, 17)),
    ((1, 0, 0, 0, 1, 0),   96, 16, (124, 110, 42)),
    ((1, 2, -4, 1, 2, -4),   64,  8, (79, 22, -24)),
    ((0, 1, 0, 0, -2, 0),    8,  4, (385, 150, 46)),
    ((0, 1, 1, 0, 0, 0),    8,  4, (564, 51, -99)),
    ((1, -1, 1, 1, -1, 1),  152,  8, (40, 47, 77)),
    ((0, 0, 1, 1, 0, 0),   56,  8, (-242, -181, -31)),
    ((0, 0, 0, 0, 0, -2),  -40,  4, (-180, -102, -24)),
    ((0, 1, 0, 0, 0, 0),    4,  4, (1217, -36, -39)),
    ((1, 4, -2, 0, 0, 0),  128, 32, (81, 13, -26)),
    ((1, -1, -2, 0, 0, 0),   88,  8, (-25, 171, -77)),
    ((0, 2, -1, 0, 0, 0),   -4,  4, (106, 9, -159)),
    ((1, -1, 1, 0, 0, 0),   80,  8, (177, 68, -3)),
    ((1, 0, 0, 0, 1, 0),   80,  8, (-96, -110, -90)),
    ((1, -2, -1, 0, 0, 0),   88,  8, (84, 79, 119)),
    ((0, 1, 0, -2, 0, 0),  -20,  4, (-42, 22, 44)),
    ((0, 0, 1, 1, 0, 0),   -4,  4, (-68, -86, -74)),
    ((1, -2, 0, 0, 0, 0),  120,  8, (158, 122, 97)),
    ((1, -4, 2, 1, -4, 2),   64,  8, (19, -8, -38)),
    ((1, 1, -1, 1, 1, -1),   72,  8, (-110, -87, -15)),
    ((0, 1, 1, 0, 1, 1),    0,  8, (75, 27, -31)),
    ((1, -1, 0, 0, 0, 0),  160, 32, (96, -33, -43)),
    ((0, 1, -1, 0, 0, 0),  -32,  8, (-92, -118, -206)),
    ((1, -2, 0, 0, 0, 0),  144, 16, (-35, -74, -62)),
    ((0, 0, 1, 0, 1, 0),   16,  4, (-45, -30, -9)),
    ((0, 1, -2, 0, 0, 0),  -32,  8, (21, 40, 62)),
    ((1, 2, 0, 0, 0, 0),   72,  8, (136, 167, 183)),
    ((0, 0, 1, 0, 1, 0),    0,  4, (-151, -120, -22)),
    ((1, -2, -1, 1, -2, -1),  104,  8, (32, 0, -26)),
    ((0, 0, 0, 0, -2, 0),  -16,  4, (16, 40, 62))
  );

  type axis_t is array (0 to 5) of integer range -510 to 510;
  type features_t is array (0 to 55) of integer range -510 to 510;
  type rgb_pipe_t is array (0 to 10) of rgb_t;
  type mix_pipe_t is array (0 to 10) of integer range 0 to 32;
  type pair_sums_t is array (0 to 3, 0 to 2) of integer range 0 to 510;
  type half_sums_t is array (0 to 1, 0 to 2) of integer range 0 to 1020;
  -- Even at the extreme RGB inputs the absolute Q7 terms in any one output
  -- sum to less than 131072. Padding to 64 leaves makes a balanced adder tree.
  type sums_t is array (natural range <>, natural range <>) of integer range -131072 to 131071;
  signal window_data : std_logic_vector(599 downto 0);
  signal wvalid, wsof, weol, advance : std_logic;
  signal valid, sof, eol : std_logic_vector(0 to 11) := (others=>'0');
  signal centre : rgb_pipe_t;
  signal mix : mix_pipe_t;
  signal pairs : pair_sums_t;
  signal halves : half_sums_t;
  signal ring_mean, graded : rgb_t;
  signal axes : axis_t;
  signal features : features_t;
  signal products : sums_t(0 to 63, 0 to 2);
  signal sums4 : sums_t(0 to 15, 0 to 2);
  signal sums8 : sums_t(0 to 7, 0 to 2);
  signal sums16 : sums_t(0 to 3, 0 to 2);
  signal sums32 : sums_t(0 to 1, 0 to 2);

  function sample(data : std_logic_vector(599 downto 0); i : natural) return rgb_t is
  begin
    return unpack(to_integer(unsigned(data(24*i+23 downto 24*i))));
  end function;
begin
  neighbourhood : entity work.axis_window5
    generic map (G_WIDTH=>G_WIDTH, G_HEIGHT=>G_HEIGHT, G_SPACING=>20)
    port map (aclk=>aclk, aresetn=>aresetn, active_width=>active_width, active_height=>active_height,
              s_axis_tdata=>s_axis_tdata, s_axis_tvalid=>s_axis_tvalid, s_axis_tready=>s_axis_tready,
              s_axis_tuser=>s_axis_tuser, s_axis_tlast=>s_axis_tlast,
              m_window_data=>window_data, m_valid=>wvalid, m_ready=>advance, m_sof=>wsof, m_eol=>weol);

  advance <= not valid(11) or m_axis_tready;
  m_axis_tvalid <= valid(11); m_axis_tuser <= sof(11); m_axis_tlast <= eol(11);

  grade : process(aclk)
    variable pixel, a, b : rgb_t;
    variable y, u, v, span, projection, total : integer;
  begin
    if rising_edge(aclk) then
      if aresetn='0' then
        valid <= (others=>'0'); sof <= (others=>'0'); eol <= (others=>'0');
        m_axis_tdata <= (others=>'0');
      elsif advance='1' then
        valid <= wvalid & valid(0 to 10);
        sof <= wsof & sof(0 to 10); eol <= weol & eol(0 to 10);
        if wvalid='1' then
          pixel := sample(window_data,12); centre(0) <= pixel; y := luma(pixel);
          span := largest(pixel(0),largest(pixel(1),pixel(2))) - smallest(pixel(0),smallest(pixel(1),pixel(2)));
          mix(0) <= clamp(smallest(y-16,smallest(240-y,128-span)),0,32);
          for i in 0 to 3 loop
            a := sample(window_data,RING(2*i)); b := sample(window_data,RING(2*i+1));
            for ch in 0 to 2 loop pairs(i,ch) <= a(ch)+b(ch); end loop;
          end loop;
        end if;
        for i in 1 to 10 loop centre(i) <= centre(i-1); mix(i) <= mix(i-1); end loop;
        if valid(0)='1' then
          for ch in 0 to 2 loop
            halves(0,ch) <= pairs(0,ch)+pairs(1,ch); halves(1,ch) <= pairs(2,ch)+pairs(3,ch);
          end loop;
        end if;
        if valid(1)='1' then
          for ch in 0 to 2 loop ring_mean(ch) <= (halves(0,ch)+halves(1,ch)+4)/8; end loop;
        end if;
        if valid(2)='1' then
          pixel := centre(2); y := luma(pixel); u := pixel(0)-pixel(1); v := pixel(1)-pixel(2);
          axes <= (y, u, v, luma(ring_mean)-y, (ring_mean(0)-ring_mean(1))-u,
                   (ring_mean(1)-ring_mean(2))-v);
        end if;
        if valid(3)='1' then
          features(0) <= 32;
          for j in axes'range loop features(1+j) <= axes(j); end loop;
          for i in RAMPS'range loop
            projection := -RAMPS(i).threshold;
            for j in axes'range loop projection := projection+RAMPS(i).direction(j)*axes(j); end loop;
            features(7+i) <= clamp(projection,0,RAMPS(i).width);
          end loop;
        end if;
        for ch in 0 to 2 loop
          if valid(4)='1' then
            for i in features'length to 63 loop products(i,ch) <= 0; end loop;
            for i in BASE_GAIN'range loop products(i,ch) <= features(i)*BASE_GAIN(i)(ch); end loop;
            for i in RAMPS'range loop products(7+i,ch) <= features(7+i)*RAMPS(i).gain(ch); end loop;
          end if;
          if valid(5)='1' then
            for i in 0 to 15 loop
              sums4(i,ch) <= (products(4*i,ch)+products(4*i+1,ch)) + (products(4*i+2,ch)+products(4*i+3,ch));
            end loop;
          end if;
          if valid(6)='1' then
            for i in 0 to 7 loop sums8(i,ch) <= sums4(2*i,ch)+sums4(2*i+1,ch); end loop;
          end if;
          if valid(7)='1' then
            for i in 0 to 3 loop sums16(i,ch) <= sums8(2*i,ch)+sums8(2*i+1,ch); end loop;
          end if;
          if valid(8)='1' then
            for i in 0 to 1 loop sums32(i,ch) <= sums16(2*i,ch)+sums16(2*i+1,ch); end loop;
          end if;
          if valid(9)='1' then
            total := 128*centre(9)(ch) + sums32(0,ch) + sums32(1,ch) + 64;
            graded(ch) <= clamp(total,0,255*128)/128;
          end if;
          if valid(10)='1' then
            total := mix(10)*graded(ch)+(32-mix(10))*centre(10)(ch)+16;
            m_axis_tdata(23-8*ch downto 16-8*ch) <= std_logic_vector(to_unsigned(total/32,8));
          end if;
        end loop;
      end if;
    end if;
  end process;
end architecture;
