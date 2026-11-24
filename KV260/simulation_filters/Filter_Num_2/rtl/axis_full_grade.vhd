-- Full-gamut, fixed-point RGB correction. A direct color term and two layers
-- of rectified affine forms act on the same twelve local measurements.
library ieee;
use ieee.std_logic_1164.all;
use work.pic2_types.all;
use work.full_grade_coeffs.all;

entity axis_full_grade is
  generic (G_CHROMA_Q8 : integer range 256 to 384 := 384);
  port (
    aclk, aresetn : in std_logic;
    s_center      : in rgb8_t;
    s_features    : in grade_features_t;
    s_valid       : in std_logic;
    s_ready       : out std_logic;
    s_sof, s_eol  : in std_logic;
    m_data        : out std_logic_vector(23 downto 0);
    m_valid       : out std_logic;
    m_ready       : in std_logic;
    m_sof, m_eol  : out std_logic
  );
end entity;

architecture rtl of axis_full_grade is
  constant LAYER_LATENCY : positive := 5;
  constant LAST_A : positive := LAYER_LATENCY;
  constant LAST_B : positive := 2*LAYER_LATENCY;
  constant LAST_RGB : positive := 3*LAYER_LATENCY;
  constant LAST : positive := LAST_RGB+2;
  constant SCALE : positive := 2**FRAC_BITS;
  constant SATURATION : positive := (G_CHROMA_Q8*256+192)/384;
  signal advance : std_logic;
  signal valid, sof, eol : std_logic_vector(0 to LAST);
  signal first_layer : grade_vector_t(0 to FIRST_COUNT-1);
  signal second_layer : grade_vector_t(0 to SECOND_COUNT-1);
  signal direct_rgb, residual_rgb : grade_vector_t(0 to 2);
  type center_delay_t is array(1 to LAST_A) of rgb8_t;
  signal centers : center_delay_t;
  -- Include the center and signed direct correction before delaying to the RGB head.
  function direct_limit return positive is
    variable result, row_sum : positive;
  begin
    result := SCALE*255;
    for ch in 0 to 2 loop
      row_sum := SCALE*255 + magnitude(B_DIRECT(ch));
      for k in W_DIRECT'range(2) loop
        row_sum := row_sum + 510*magnitude(W_DIRECT(ch,k));
      end loop;
      result := largest(result,row_sum);
    end loop;
    return result;
  end function;
  constant BASE_LIMIT : positive := direct_limit;
  type signed_rgb_t is array(0 to 2) of integer range -BASE_LIMIT to BASE_LIMIT;
  type base_delay_t is array(LAST_A+1 to LAST_RGB) of signed_rgb_t;
  signal base : base_delay_t;
  signal graded : rgb_t;
begin
  advance <= (not valid(LAST)) or m_ready;
  s_ready <= advance;
  valid(0) <= s_valid;
  sof(0) <= s_sof;
  eol(0) <= s_eol;
  m_valid <= valid(LAST);
  m_sof <= sof(LAST);
  m_eol <= eol(LAST);

  first_forms : entity work.grade_affine
    generic map (W_FIRST,B_FIRST,510,FRAC_BITS,HIDDEN_LIMIT)
    port map (aclk,advance,valid(0 to LAST_A-1),s_features,first_layer);
  direct_terms : entity work.grade_affine
    generic map (W_DIRECT,B_DIRECT,510)
    port map (aclk,advance,valid(0 to LAST_A-1),s_features,direct_rgb);
  second_forms : entity work.grade_affine
    generic map (W_SECOND,B_SECOND,HIDDEN_LIMIT,FRAC_BITS,HIDDEN_LIMIT)
    port map (aclk,advance,valid(LAST_A to LAST_B-1),first_layer,second_layer);
  rgb_head : entity work.grade_affine
    generic map (W_RGB,B_RGB,HIDDEN_LIMIT)
    port map (aclk,advance,valid(LAST_B to LAST_RGB-1),second_layer,residual_rgb);

  align_and_finish : process(aclk)
    variable y, total : integer;
    variable result_rgb : rgb8_t;
  begin
    if rising_edge(aclk) then
      if aresetn='0' then
        valid(1 to LAST) <= (others=>'0');
        sof(1 to LAST) <= (others=>'0');
        eol(1 to LAST) <= (others=>'0');
        m_data <= (others=>'0');
      elsif advance='1' then
        valid(1 to LAST) <= valid(0 to LAST-1);
        sof(1 to LAST) <= sof(0 to LAST-1);
        eol(1 to LAST) <= eol(0 to LAST-1);
        centers(1) <= s_center;
        centers(2 to LAST_A) <= centers(1 to LAST_A-1);
        if valid(LAST_A)='1' then
          base(LAST_A+1) <= (SCALE*centers(LAST_A).r+direct_rgb(0),
                             SCALE*centers(LAST_A).g+direct_rgb(1),
                             SCALE*centers(LAST_A).b+direct_rgb(2));
        end if;
        base(LAST_A+2 to LAST_RGB) <= base(LAST_A+1 to LAST_RGB-1);
        if valid(LAST_RGB)='1' then
          for ch in 0 to 2 loop
            total := base(LAST_RGB)(ch) + residual_rgb(ch);
            graded(ch) <= clamp((total+SCALE/2)/SCALE,0,255);
          end loop;
        end if;
        if valid(LAST_RGB+1)='1' then
          y := luma(graded);
          result_rgb.r := (SATURATION*graded(0)+(256-SATURATION)*y+128)/256;
          result_rgb.g := (SATURATION*graded(1)+(256-SATURATION)*y+128)/256;
          result_rgb.b := (SATURATION*graded(2)+(256-SATURATION)*y+128)/256;
          m_data <= to_slv24(result_rgb);
        end if;
      end if;
    end if;
  end process;
end architecture;
