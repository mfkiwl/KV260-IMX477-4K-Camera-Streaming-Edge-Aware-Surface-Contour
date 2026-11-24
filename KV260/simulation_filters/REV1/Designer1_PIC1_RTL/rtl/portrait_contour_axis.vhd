library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Measure signed structure on two square stencils of the lightly filtered
-- camera luminance. Each accepted output carries the original RGB at the center.
entity portrait_contour_axis is
  generic (
    G_WIDTH, G_HEIGHT : positive;
    G_FINE_STEP, G_MEDIUM_STEP : positive
  );
  port (
    aclk, aresetn : in std_logic;
    s_word   : in natural range 0 to 2**26-1; -- SOF, EOL and 10-bit Q2 luma
    s_rgb    : in natural range 0 to 2**24-1;
    s_valid  : in std_logic;
    s_ready  : out std_logic;
    m_word   : out natural range 0 to 2**26-1; -- SOF, EOL, RGB888
    m_ridge  : out natural range 0 to 2**28-1;   -- dark and bright evidence in Q2
    m_valid  : out std_logic;
    m_ready  : in std_logic
  );
end entity;

architecture rtl of portrait_contour_axis is
  function larger(a, b : integer) return integer is
  begin
    if a > b then return a; end if;
    return b;
  end function;

  function smaller(a, b : integer) return integer is
  begin
    if a < b then return a; end if;
    return b;
  end function;

  function distance(a, b : natural) return natural is
  begin
    if a >= b then return a-b; end if;
    return b-a;
  end function;

  constant R : positive := larger(G_FINE_STEP, G_MEDIUM_STEP);
  constant PITCH : positive := G_WIDTH+R;
  constant CENTER_DELAY : positive := R*PITCH+R;
  type step_array_t is array(0 to 1) of positive;
  constant SPACING : step_array_t := (G_FINE_STEP, G_MEDIUM_STEP);

  subtype luma_t is natural range 0 to 1023;
  subtype pixel_word_t is natural range 0 to 2**26-1;
  subtype packed_rows_t is std_logic_vector(20*R-1 downto 0);
  type row_store_t is array(0 to G_WIDTH-1) of packed_rows_t;
  type center_store_t is array(0 to CENTER_DELAY-1) of pixel_word_t;
  type column_t is array(0 to 1, 0 to 2) of luma_t;
  type columns_t is array(natural range <>) of column_t;
  type stencil_t is array(0 to 2, 0 to 2) of luma_t;
  type stencil_pair_t is array(0 to 1) of stencil_t;
  type direction_t is record
    curvature : integer range -1023 to 1023;
    normal_contrast, tangent_contrast : luma_t;
  end record;
  type orientations_t is array(0 to 3) of direction_t;
  type scale_stats_t is array(0 to 1) of orientations_t;
  type strengths_t is array(0 to 3) of natural range 0 to 255;

  function average3(a, b, c : luma_t) return luma_t is
  begin
    return (a+2*b+c+2)/4;
  end function;

  function strip(center0, center1, center2, flank0, flank1 : luma_t) return direction_t is
    variable result : direction_t;
  begin
    result.curvature := average3(center0,center1,center2) - (flank0+flank1+1)/2;
    result.normal_contrast := distance(flank0,flank1);
    result.tangent_contrast := distance(center0,center2);
    return result;
  end function;

  function directions(s : stencil_t) return orientations_t is
    variable d : orientations_t;
  begin
    -- Each orientation compares the center strip with strips on its two sides.
    d(0) := strip(s(1,0),s(1,1),s(1,2), average3(s(0,0),s(0,1),s(0,2)), average3(s(2,0),s(2,1),s(2,2)));
    d(1) := strip(s(0,1),s(1,1),s(2,1), average3(s(0,0),s(1,0),s(2,0)), average3(s(0,2),s(1,2),s(2,2)));
    d(2) := strip(s(0,0),s(1,1),s(2,2), average3(s(0,1),s(0,2),s(1,2)), average3(s(1,0),s(2,0),s(2,1)));
    d(3) := strip(s(0,2),s(1,1),s(2,0), average3(s(1,0),s(0,0),s(0,1)), average3(s(2,1),s(2,2),s(1,2)));
    return d;
  end function;

  function evidence(fine, medium : direction_t; dark_side : boolean) return natural is
    variable fine_curve, medium_curve : integer range -1023 to 1023;
    variable coherent, support : natural;
  begin
    if dark_side then
      fine_curve := -fine.curvature;
      medium_curve := -medium.curvature;
    else
      fine_curve := fine.curvature;
      medium_curve := medium.curvature;
    end if;
    coherent := larger(0, medium_curve - larger(0,medium.tangent_contrast-medium.normal_contrast)/8);
    support := 3*larger(0,fine_curve) + larger(0,medium.normal_contrast-fine.tangent_contrast)/4 + 2;
    return smaller(255,smaller(coherent,support));
  end function;

  function strongest(q : strengths_t) return natural is
  begin
    return larger(larger(q(0),q(1)),larger(q(2),q(3)));
  end function;

  signal rows : row_store_t;
  signal centers : center_store_t;
  signal cols : columns_t(0 to 2*R-1);
  signal x, x0 : natural range 0 to PITCH-1 := 0;
  signal y, y0 : natural range 0 to G_HEIGHT+R-1 := 0;
  signal center_addr : natural range 0 to CENTER_DELAY-1 := 0;
  signal read_rows : packed_rows_t;
  signal luma0 : luma_t;
  signal word0, word1, word2, word3 : pixel_word_t;
  signal stencils : stencil_pair_t;
  signal stats : scale_stats_t;
  signal dark3, light3 : strengths_t;
  signal v0, v1, v2, v3, v4 : std_logic := '0';
  signal active, advance, issue : std_logic;
begin
  active <= '1' when x<G_WIDTH and y<G_HEIGHT else '0';
  advance <= (not v4) or m_ready;
  s_ready <= advance and active and aresetn;
  issue <= advance and aresetn and ((not active) or s_valid);
  m_valid <= v4;

  pipeline : process(aclk)
    variable all_rows : std_logic_vector(20*R+9 downto 0);
    variable sample : luma_t;
    variable column : column_t;
    variable window : columns_t(0 to 2*R);
    variable offset : natural range 0 to 2*R;
  begin
    if rising_edge(aclk) then
      if aresetn='0' then
        x<=0; y<=0; center_addr<=0;
        v0<='0'; v1<='0'; v2<='0'; v3<='0'; v4<='0';
        m_word<=0; m_ridge<=0;
      elsif advance='1' then
        v0<=issue; v1<='0'; v2<=v1; v3<=v2; v4<=v3;
        if issue='1' then
          x0<=x; y0<=y;
          if x=PITCH-1 then
            x<=0;
            if y=G_HEIGHT+R-1 then y<=0; else y<=y+1; end if;
          else x<=x+1;
          end if;
          if x<G_WIDTH then read_rows<=rows(x); end if;
          luma0<=s_word mod 1024;
          word0<=centers(center_addr);
          centers(center_addr)<=(s_word/2**24)*2**24+s_rgb;
          if center_addr=CENTER_DELAY-1 then center_addr<=0; else center_addr<=center_addr+1; end if;
        end if;
        if v0='1' then
          if x0<G_WIDTH then
            sample:=luma0;
            if y0>=G_HEIGHT then sample:=to_integer(unsigned(read_rows(9 downto 0))); end if;
            all_rows:=read_rows & std_logic_vector(to_unsigned(sample,10));
            -- Replicate the top row. This also invalidates the preceding frame's line history.
            if y0=0 then
              for j in 0 to 2*R loop
                all_rows(10*j+9 downto 10*j):=std_logic_vector(to_unsigned(sample,10));
              end loop;
            end if;
            rows(x0)<=all_rows(20*R-1 downto 0);
            for scale in 0 to 1 loop
              for row_index in 0 to 2 loop
                offset:=R+(1-row_index)*SPACING(scale);
                column(scale,row_index):=to_integer(unsigned(all_rows(10*offset+9 downto 10*offset)));
              end loop;
            end loop;
          else
            column:=cols(0); -- replicate the right edge of this row
          end if;
          window(0):=column;
          if x0=0 then window(1 to 2*R):=(others=>column);
          else window(1 to 2*R):=cols;
          end if;
          cols<=window(0 to 2*R-1);
          if x0>=R and y0>=R then
            v1<='1'; word1<=word0;
            for scale in 0 to 1 loop
              for row_index in 0 to 2 loop
                for col_index in 0 to 2 loop
                  offset:=R+(1-col_index)*SPACING(scale);
                  stencils(scale)(row_index,col_index)<=window(offset)(scale,row_index);
                end loop;
              end loop;
            end loop;
          end if;
        end if;
        if v1='1' then
          word2<=word1;
          for scale in 0 to 1 loop stats(scale)<=directions(stencils(scale)); end loop;
        end if;
        if v2='1' then
          word3<=word2;
          for i in 0 to 3 loop
            dark3(i)<=evidence(stats(0)(i),stats(1)(i),true);
            light3(i)<=evidence(stats(0)(i),stats(1)(i),false);
          end loop;
        end if;
        if v3='1' then
          m_word<=word3;
          m_ridge<=256*strongest(dark3)+strongest(light3);
        end if;
      end if;
    end if;
  end process;
end architecture;
