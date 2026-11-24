library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pic2_types.all;
use work.designer_geometry.all;

-- Camera-domain edge and tone renderer. All colour terms come from the
-- current pixel and eight symmetric neighbours. There are no image-file ports.
entity axis_designer_grade is
  generic (G_WIDTH : positive := INPUT_WIDTH; G_HEIGHT : positive := INPUT_HEIGHT);
  port (
    aclk, aresetn : in std_logic;
    s_axis_tdata : in std_logic_vector(23 downto 0);
    s_axis_tvalid, s_axis_tuser, s_axis_tlast : in std_logic;
    s_axis_tready : out std_logic;
    m_axis_tdata : out std_logic_vector(23 downto 0);
    m_axis_tvalid, m_axis_tuser, m_axis_tlast : out std_logic;
    m_axis_tready : in std_logic
  );
end entity;

architecture rtl of axis_designer_grade is
  constant W : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(G_WIDTH,16));
  constant H : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(G_HEIGHT,16));
  constant LAST_STAGE : natural := 10;
  type index_vec_t is array(natural range <>) of natural;
  -- Vertical, horizontal and the two diagonals. Each consecutive pair
  -- straddles the centre, allowing a dark stroke to be separated from a step.
  constant NEIGHBOURS : index_vec_t(0 to 7) := (2,22,10,14,6,18,8,16);
  type eight_t is array(0 to 7) of byte_t;
  type four_t is array(0 to 3) of byte_t;
  type pair_sums_t is array(0 to 3) of integer range 0 to 510;
  subtype signed_byte_t is integer range -255 to 255;
  type opponent_t is record
    y : byte_t;
    u, v : signed_byte_t;
  end record;
  type context_t is record
    col : opponent_t;
    detail : signed_byte_t;
    span, dark, light : byte_t;
  end record;
  type context_pipe_t is array(2 to 7) of context_t;

  -- Q6 coefficients operate on signed opponents and saturated linear ramps.
  -- The only brightness lookup is a single signed scalar added to all channels.
  type anchors_t is array(0 to 16) of integer range -64 to 319;
  constant ANCHOR : anchors_t := (-39, -27, -16, -3, 12, 33, 52, 86, 120, 152, 167, 177, 189, 202, 215, 229, 242);
  type tone_curve_t is array(byte_t) of integer range -64 to 319;
  function tone_curve return tone_curve_t is
    variable curve : tone_curve_t;
    variable k, f : natural;
  begin
    for y in curve'range loop
      k := y/16;
      f := y mod 16;
      curve(y) := ((16-f)*ANCHOR(k) + f*ANCHOR(k+1) + 1024 + 8)/16 - 64;
    end loop;
    return curve;
  end function;
  constant TONE : tone_curve_t := tone_curve;

  constant N_TERMS : positive := 21;
  type weights_t is array(0 to 2,0 to N_TERMS-1) of integer range -1023 to 1023;
  constant WEIGHT : weights_t := (
    (-19, -42, -35, 130, 149, 68, 58, 43, -52, -34, 36, 73, 40, -71, 70, 75, 38, -9, -38, 42, -40),
    (-166, -101, -48, 153, 39, 67, 63, 58, -65, -32, 75, 72, 46, -78, 57, 80, 16, -10, -41, 35, -33),
    (787, -110, -146, 122, -7, 99, 19, -9, -43, -18, 69, 56, 38, -68, 62, 64, 4, -11, -18, 18, -18)
  );
  type terms_t is array(0 to N_TERMS-1) of signed_byte_t;
  function ramp(x, low_limit, high_limit : integer) return natural is
  begin
    return clamp(x-low_limit,0,high_limit-low_limit);
  end function;
  function grade_terms(c : context_t) return terms_t is
    variable y, u, v : integer;
  begin
    y := c.col.y;
    u := c.col.u;
    v := c.col.v;
    return (
      1, u, v,
      ramp(u,-8,4), ramp(u,4,16), ramp(v,28,48),
      ramp(y-2*v,68,84), ramp(y-2*v,84,104), ramp(y+2*u,72,92),
      ramp(y+2*u,120,152), ramp(v-u,4,16), ramp(y+2*v,68,96),
      ramp(y+2*v,96,128), ramp(y-2*u,72,96), ramp(2*v+u,10,22),
      ramp(u+v,28,48), ramp(y+4*u-2*v,80,100), ramp(c.detail,-32,0),
      ramp(c.detail,0,32), ramp(c.span,0,24), ramp(c.span+u,16,40)
    );
  end function;

  type product_row_t is array(0 to 23) of integer range -261000 to 261000;
  type products_t is array(0 to 2) of product_row_t;
  type group_row_t is array(0 to 5) of integer range -1044000 to 1044000;
  type groups_t is array(0 to 2) of group_row_t;
  type accum_t is array(0 to 2) of integer range -3200000 to 3200000;
  signal win : std_logic_vector(599 downto 0);
  signal win_valid, win_ready, win_sof, win_eol, advance : std_logic;
  signal valid, sof, eol : std_logic_vector(0 to LAST_STAGE) := (others=>'0');
  signal samples0 : eight_t;
  signal center0, center1 : opponent_t;
  signal low1, high1 : four_t;
  signal sum1 : pair_sums_t;
  signal ctx : context_pipe_t;
  signal terms3 : terms_t;
  signal tone3, tone4, tone5 : integer range -64 to 319;
  signal products4 : products_t;
  signal groups5 : groups_t;
  signal half_a6, half_b6 : accum_t;
  signal color7, color8, color9 : rgb_t;
  signal level8 : byte_t;
  signal gain8, gain9 : integer range 8 to 52;
  signal neutral8 : integer range -4096 to 4096;
  signal ridge8 : integer range -36 to 12;
  signal band9 : integer range -7 to 8;
  signal offset9 : integer range -300 to 300;
begin
  window_stage : entity work.axis_window5
    generic map(G_WIDTH=>G_WIDTH,G_HEIGHT=>G_HEIGHT,G_SPACING=>8)
    port map(aclk=>aclk,aresetn=>aresetn,active_width=>W,active_height=>H,
      s_axis_tdata=>s_axis_tdata,s_axis_tvalid=>s_axis_tvalid,s_axis_tready=>s_axis_tready,
      s_axis_tuser=>s_axis_tuser,s_axis_tlast=>s_axis_tlast,
      m_window_data=>win,m_valid=>win_valid,m_ready=>win_ready,m_sof=>win_sof,m_eol=>win_eol);
  advance <= not valid(LAST_STAGE) or m_axis_tready;
  win_ready <= advance and aresetn;
  m_axis_tvalid <= valid(LAST_STAGE);
  m_axis_tuser <= sof(LAST_STAGE);
  m_axis_tlast <= eol(LAST_STAGE);

  pipeline : process(aclk)
    variable c : rgb8_t;
    variable i, y, mean, lo, hi, ridge_floor, ridge_ceiling : integer;
    variable u, v, weight_neutral, shift, delta : integer;
  begin
    if rising_edge(aclk) then
      if aresetn='0' then
        valid <= (others=>'0'); sof <= (others=>'0'); eol <= (others=>'0');
        m_axis_tdata <= (others=>'0');
      elsif advance='1' then
        valid <= win_valid & valid(0 to LAST_STAGE-1);
        sof <= win_sof & sof(0 to LAST_STAGE-1);
        eol <= win_eol & eol(0 to LAST_STAGE-1);

        if win_valid='1' then
          c := to_rgb8(win(311 downto 288)); -- tap 12
          center0 <= (luma_y(c),c.r-c.g,c.g-c.b);
          for j in samples0'range loop
            i := NEIGHBOURS(j);
            samples0(j) <= luma_y(to_rgb8(win(24*i+23 downto 24*i)));
          end loop;
        end if;

        if valid(0)='1' then
          center1 <= center0;
          for j in 0 to 3 loop
            low1(j) <= smallest(samples0(2*j),samples0(2*j+1));
            high1(j) <= largest(samples0(2*j),samples0(2*j+1));
            sum1(j) <= samples0(2*j)+samples0(2*j+1);
          end loop;
        end if;

        if valid(1)='1' then
          mean := (sum1(0)+sum1(1)+sum1(2)+sum1(3)+4)/8;
          lo := smallest(smallest(low1(0),low1(1)),smallest(low1(2),low1(3)));
          hi := largest(largest(high1(0),high1(1)),largest(high1(2),high1(3)));
          ridge_floor := largest(largest(low1(0),low1(1)),largest(low1(2),low1(3)));
          ridge_ceiling := smallest(smallest(high1(0),high1(1)),smallest(high1(2),high1(3)));
          ctx(2) <= (center1,center1.y-mean,hi-lo,
                     largest(0,ridge_floor-center1.y),largest(0,center1.y-ridge_ceiling));
        end if;

        for k in 3 to 7 loop
          if valid(k-1)='1' then ctx(k) <= ctx(k-1); end if;
        end loop;
        if valid(2)='1' then
          terms3 <= grade_terms(ctx(2));
          tone3 <= TONE(ctx(2).col.y);
        end if;

        if valid(3)='1' then
          tone4 <= tone3;
          for ch in 0 to 2 loop
            for j in terms3'range loop
              products4(ch)(j) <= WEIGHT(ch,j)*terms3(j);
            end loop;
            products4(ch)(N_TERMS to 23) <= (others=>0);
          end loop;
        end if;
        if valid(4)='1' then
          tone5 <= tone4;
          for ch in 0 to 2 loop
            for j in 0 to 5 loop
              groups5(ch)(j) <= (products4(ch)(4*j)+products4(ch)(4*j+1))
                              + (products4(ch)(4*j+2)+products4(ch)(4*j+3));
            end loop;
          end loop;
        end if;
        if valid(5)='1' then
          for ch in 0 to 2 loop
            half_a6(ch) <= (groups5(ch)(0)+groups5(ch)(1))+(groups5(ch)(2)+64*tone5);
            half_b6(ch) <= groups5(ch)(3)+groups5(ch)(4)+groups5(ch)(5);
          end loop;
        end if;
        if valid(6)='1' then
          for ch in 0 to 2 loop
            color7(ch) <= clamp(half_a6(ch)+half_b6(ch)+32,0,255*64)/64;
          end loop;
        end if;

        -- Compress flat, low-chroma shadow variation. The ridge correction
        -- preserves narrow dark strokes and modest highlights in dark regions.
        if valid(7)='1' then
          y := luma(color7); u := ctx(7).col.u; v := ctx(7).col.v;
          weight_neutral := clamp(16-2*magnitude(u)-magnitude(v-6),0,16);
          weight_neutral := smallest(weight_neutral,clamp(28-magnitude(y-61),0,16));
          weight_neutral := smallest(weight_neutral,clamp(20-ctx(7).span,0,16));
          neutral8 <= (61-y)*weight_neutral;
          ridge8 <= -smallest(36,(3*largest(0,ctx(7).dark-4)+1)/2)
                    + smallest(clamp(85-y,0,12),largest(0,ctx(7).light-3));
          level8 <= y; color8 <= color7; gain8 <= clamp(14+3*u,8,52);
        end if;
        if valid(8)='1' then
          shift := (neutral8+4096+8)/16-256+ridge8;
          offset9 <= shift;
          band9 <= 8-((level8+shift+8) mod 16);
          color9 <= color8; gain9 <= gain8;
        end if;
        if valid(9)='1' then
          delta := offset9+(band9*gain9+1024+32)/64-16;
          for ch in 0 to 2 loop
            m_axis_tdata(23-8*ch downto 16-8*ch) <=
              std_logic_vector(to_unsigned(clamp(color9(ch)+delta,0,255),8));
          end loop;
        end if;
      end if;
    end if;
  end process;
end architecture;
