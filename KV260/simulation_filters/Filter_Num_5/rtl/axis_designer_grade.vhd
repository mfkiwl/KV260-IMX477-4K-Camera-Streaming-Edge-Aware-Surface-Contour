library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pic2_types.all;

-- Fixed-point portrait grading after edge-preserving surface and contour filtering.
-- The brightness curve is scalar. Output RGB is calculated from brightness and
-- signed colour differences of the same incoming pixel.
entity axis_designer_grade is
  generic (G_LARGE_VIEW : boolean := true);
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
  type anchors_t is array (0 to 16) of byte_t;
  function anchors(large_view : boolean) return anchors_t is
  begin
    if large_view then return (0,9,18,27,39,78,107,140,174,196,218,234,250,252,253,254,255); end if;
    return (0,13,26,39,40,79,105,137,169,190,212,231,250,252,253,254,255);
  end function;
  constant A : anchors_t := anchors(G_LARGE_VIEW);

  type curve_t is array (byte_t) of byte_t;
  function brightness_curve return curve_t is
    variable result : curve_t;
    variable k, tone, nearest : natural;
  begin
    for y in result'range loop
      k := y/16;
      tone := A(k) + ((y mod 16)*(A(k+1)-A(k))+8)/16;
      nearest := 8*((tone+4)/8);
      result(y) := (3*tone + nearest + 2)/4;
    end loop;
    return result;
  end function;
  constant CURVE : curve_t := brightness_curve;

  -- Columns represent R-G, B-G, positive R-G, excess R-G above 16,
  -- and excess G-B above 28. Coefficients use six fractional bits.
  type coeff_t is array (0 to 2, 0 to 4) of integer;
  function coefficients(large_view : boolean) return coeff_t is
  begin
    if large_view then
      return ((150, 12, 13,-199,13), (52,20,-63,-63, 5), (45,109,-99,-27,61));
    end if;
    return ((134,  1, 27,-185,-3), (44, 7,-55,-53,-13), (38, 96,-93,-17,42));
  end function;
  constant C : coeff_t := coefficients(G_LARGE_VIEW);
  type terms_t is array (0 to 4) of integer range -255 to 255;
  type products_t is array (0 to 2, 0 to 4) of integer range -255*200 to 255*200;
  type sums_t is array (0 to 2) of integer range -160000 to 160000;
  signal u, v : integer range -255 to 255 := 0;
  signal y1, tone2, tone3 : byte_t := 0;
  signal terms : terms_t;
  signal products : products_t;
  signal left_sum, right_sum : sums_t;
  signal valid, sof, eol : std_logic_vector(0 to 4) := (others=>'0');
  signal advance : std_logic;
begin
  advance <= not valid(4) or m_axis_tready;
  s_axis_tready <= aresetn and advance;
  m_axis_tvalid <= valid(4);
  m_axis_tuser <= sof(4);
  m_axis_tlast <= eol(4);

  pipeline : process(aclk)
    variable rgb : rgb8_t;
    variable total : integer;
  begin
    if rising_edge(aclk) then
      if aresetn='0' then
        valid <= (others=>'0'); sof <= (others=>'0'); eol <= (others=>'0');
        m_axis_tdata <= (others=>'0');
      elsif advance='1' then
        valid <= s_axis_tvalid & valid(0 to 3);
        sof <= s_axis_tuser & sof(0 to 3);
        eol <= s_axis_tlast & eol(0 to 3);
        if s_axis_tvalid='1' then
          rgb := to_rgb8(s_axis_tdata);
          y1 <= luma_y(rgb);
          u <= rgb.r-rgb.g;
          v <= rgb.b-rgb.g;
        end if;

        terms <= (u, v, largest(u,0), largest(u-16,0), largest(-v-28,0));
        tone2 <= CURVE(y1);
        tone3 <= tone2;
        for ch in 0 to 2 loop
          for j in 0 to 4 loop
            products(ch,j) <= C(ch,j)*terms(j);
          end loop;
          left_sum(ch) <= 64*tone3 + products(ch,0) + products(ch,1);
          right_sum(ch) <= products(ch,2) + products(ch,3) + products(ch,4);
          total := left_sum(ch)+right_sum(ch);
          m_axis_tdata(23-8*ch downto 16-8*ch) <=
            std_logic_vector(to_unsigned(clamp(total+32,0,255*64)/64,8));
        end loop;
      end if;
    end if;
  end process;
end architecture;
