library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.stroke_math_pkg.all;

-- Vote on the dominant signed luminance or opponent-color residual before
-- quantization. Preserve the original contour evidence on a parallel sideband.
entity portrait_structure_vote is
  generic (G_WIDTH, G_HEIGHT : positive);
  port (
    clk, reset_n : in std_logic;
    s_word : in natural range 0 to 2**26-1;
    s_surface : in natural range 0 to 2**24-1;
    s_ridge : in natural range 0 to 2**28-1;
    s_valid : in std_logic;
    s_ready : out std_logic;
    m_word : out natural range 0 to 2**26-1;
    m_surface : out natural range 0 to 2**24-1;
    m_ridge, m_guide : out natural range 0 to 2**28-1;
    m_valid : out std_logic;
    m_ready : in std_logic;
    m_region_context : out natural range 0 to 2**24-1 := 0
  );
end entity;

architecture rtl of portrait_structure_vote is
  type index_t is array (0 to 7) of natural;
  -- Near axial neighbors, then far diagonal neighbors.
  constant TAPS : index_t := (1,3,5,7,9,11,15,17);
  subtype tag_t is std_logic_vector(2 downto 0);
  subtype meta_t is std_logic_vector(53 downto 0);
  type delta_t is array (0 to 2) of integer range -10 to 10;
  type deltas_t is array (0 to 7) of delta_t;
  type offsets_t is array (0 to 2) of integer range -10 to 10;
  type feature_class_t is (noise, fine_texture, medium_structure, major_boundary);

  signal surface, context_rgb : rgb_t;
  signal input_tag : tag_t;
  signal metadata, aligned, meta1, meta2 : meta_t;
  signal window_samples : std_logic_vector(18*27-1 downto 0);
  -- The 9 near taps and the 16 outer sites form the nested 3x3/5x5 grid.
  signal mixed_samples : std_logic_vector(8*27-1 downto 0);
  type near_rows_t is array(0 to 2) of natural range 0 to 3060;
  type ring_groups_t is array(0 to 3) of natural range 0 to 4080;
  constant FAR_RING : index_t := (9,10,11,12,14,15,16,17);
  signal near_rows1 : near_rows_t;
  signal ring_groups1 : ring_groups_t;
  signal inner2, outer2 : natural range 0 to 1020;
  -- Top, bottom, left, right. Both scales use the same tangential width.
  type flank_levels_t is array(0 to 3) of natural range 0 to 1020;
  type flank_indices_t is array(0 to 3) of natural;
  constant NEAR_A : flank_indices_t := (0,6,0,2);
  constant NEAR_M : flank_indices_t := (1,7,3,5);
  constant NEAR_B : flank_indices_t := (2,8,6,8);
  constant FAR_A_MIXED : flank_indices_t := (4,6,0,1);
  constant FAR_M : flank_indices_t := (10,16,12,14);
  constant FAR_B_MIXED : flank_indices_t := (5,7,2,3);
  signal near_flank1, far_flank1 : flank_levels_t;
  signal flank_shift2 : integer range -4 to 4;
  signal deltas1 : deltas_t;
  signal matches1 : std_logic_vector(0 to 7);
  signal center1, center2 : rgb_t;
  signal strength1 : natural range 0 to 510;
  signal guide1, guide2 : natural range 0 to 2**28-1;
  signal offsets2 : offsets_t;
  signal move2 : std_logic;
  signal class2 : feature_class_t;
  signal window_valid, valid1, valid2, advance : std_logic;

  type residual_t is record
    tag : tag_t;
    magnitude : natural range 0 to 510;
  end record;
  signal current_residual : residual_t;

  -- Lower-index channels have priority on equal magnitudes. An exact tie with
  -- zero magnitude has a neutral tag and cannot support any signed region.
  function dominant_residual(s, b : rgb_t) return residual_t is
    variable r, g, bl, wr, wg, wb : integer;
    variable d : integer;
    type triplet_t is array (0 to 2) of integer range -510 to 510;
    variable differences : triplet_t;
    variable result : residual_t := (tag=>"000",magnitude=>0);
  begin
    r:=as_nat(s(23 downto 16)); g:=as_nat(s(15 downto 8)); bl:=as_nat(s(7 downto 0));
    wr:=as_nat(b(23 downto 16)); wg:=as_nat(b(15 downto 8)); wb:=as_nat(b(7 downto 0));
    differences:=(integer(luma(s))-integer(luma(b)),(r-g)-(wr-wg),(g-bl)-(wg-wb));
    for k in differences'range loop
      d:=differences(k);
      if dist(d,0)>result.magnitude then
        result.magnitude:=dist(d,0);
        if d>0 then result.tag:=std_logic_vector(to_unsigned(2*k+1,3));
        else result.tag:=std_logic_vector(to_unsigned(2*k+2,3)); end if;
      end if;
    end loop;
    return result;
  end function;

  -- Preserve quarter-code precision until the spatial means are compared.
  function luma4(p : rgb_t) return natural is
  begin
    return as_nat(p(23 downto 16))+2*as_nat(p(15 downto 8))+as_nat(p(7 downto 0));
  end function;

  function tap_luma4(samples : std_logic_vector; tap : natural) return natural is
  begin
    return luma4(samples(27*tap+23 downto 27*tap));
  end function;

  function round_shift(value : integer; bits : positive) return integer is
  begin
    return to_integer(shift_right(to_signed(value+2**(bits-1),13),bits));
  end function;
  -- Detect a step only if both independently measured scales agree on its
  -- polarity. A center surrounded by a flat field cannot establish a step.
  function warm_flank_shift(near_y, far_y : flank_levels_t; center, wide : rgb_t;
                            evidence : natural) return integer is
    variable level : flank_levels_t;
    variable axis, chosen : natural range 0 to 3;
    variable smooth_y, contrast_weight, weight : natural;
    variable dn, df, adjustment, green_blue : integer;
  begin
    for i in level'range loop level(i):=(near_y(i)+far_y(i)+1)/2; end loop;
    axis:=0;
    if dist(level(2),level(3))>dist(level(0),level(1)) then axis:=2; end if;
    dn:=integer(near_y(axis))-integer(near_y(axis+1));
    df:=integer(far_y(axis))-integer(far_y(axis+1));
    if dn=0 or df=0 or (dn<0)/=(df<0) then return 0; end if;
    -- The weaker scale sets confidence. Reject fine detail confined to one radius.
    contrast_weight:=bound(2*(lo(dist(dn,0),dist(df,0))-12),0,16);
    if contrast_weight=0 then return 0; end if;
    smooth_y:=(4*luma4(center)+near_y(0)+near_y(1)+near_y(2)+near_y(3)+4)/8;
    chosen:=axis;
    if dist(smooth_y,level(axis+1))<dist(smooth_y,level(axis)) then chosen:=axis+1; end if;
    -- Gate the shift using the live broad color and directional confidence.
    weight:=lo(bound(4*(as_nat(wide(23 downto 16))-as_nat(wide(15 downto 8))-6),0,16),
               bound(2*(integer(luma(wide))-36),0,16));
    weight:=lo(weight,bound((36-integer(evidence))/2,0,16));
    adjustment:=bound(round_shift(integer(level(chosen))-integer(luma4(wide)),2),-4,4);
    -- Taper the correction as the broad surface loses its warm green-blue separation.
    green_blue:=as_nat(wide(15 downto 8))-as_nat(wide(7 downto 0));
    if green_blue<=12 then return 0; end if;
    adjustment:=round_shift(round_shift(adjustment*weight,4)*contrast_weight,4);
    if green_blue=13 then return round_shift(adjustment,1); end if;
    return adjustment;
  end function;
  function region_context(wide : rgb_t; inner, outer, evidence : natural) return rgb_t is
    variable d, broad, exposure, y, change : integer;
    variable weight : natural range 0 to 16;
    variable out_rgb : rgb_t := wide;
  begin
    d:=integer(inner)-integer(outer);
    broad:=luma4(wide);
    if dist(d,0)>=2 and dist(d,0)<=40 and
       ((d>0 and inner>broad) or (d<0 and inner<broad)) then
      -- Protect deep shadows, bright warm regions, and already strong directional boundaries.
      y:=(broad+2)/4;
      exposure:=y+as_nat(wide(23 downto 16))-as_nat(wide(7 downto 0));
      weight:=lo(bound(2*(98-exposure),0,16),bound(2*(y-32),0,16));
      weight:=lo(weight,bound((36-integer(evidence))/2,0,16));
      change:=round_shift(bound(round_shift(d,1),-3,3)*weight,4);
      for k in 0 to 2 loop
        out_rgb(8*k+7 downto 8*k):=std_logic_vector(to_unsigned(
          bound(as_nat(wide(8*k+7 downto 8*k))+change,0,255),8));
      end loop;
    end if;
    return out_rgb;
  end function;
begin
  surface<=std_logic_vector(to_unsigned(s_surface,24));
  context_rgb<=std_logic_vector(to_unsigned(s_word mod 2**24,24));
  current_residual<=dominant_residual(surface,context_rgb) when s_valid='1' else
                    (tag=>"000",magnitude=>0);
  input_tag<=current_residual.tag;
  metadata<=std_logic_vector(to_unsigned(s_ridge,28)) & std_logic_vector(to_unsigned(s_word,26));

  win : entity work.axis_stencil
    generic map(G_WIDTH,G_HEIGHT,3,7,27,54,true)
    port map(clk,reset_n,input_tag & surface,metadata,s_valid,s_ready,
             window_samples,aligned,window_valid,advance,mixed_samples);
  advance<=(not m_valid) or m_ready;

  process(clk)
    variable center, tap_color, wide, result_color, region_color : rgb_t;
    variable center_tag, neighbor_tag : tag_t;
    variable index, lower_bit, near_votes, far_votes, amount, value : natural;
    variable ridge_value : natural range 0 to 2**28-1;
    variable acc, displacement : integer;
    variable near_sum : natural range 0 to 9180;
    variable ring_sum : natural range 0 to 16320;
    variable a,b : natural range 0 to 2040;
  begin
    if rising_edge(clk) then
      if reset_n='0' then
        valid1<='0'; valid2<='0'; m_valid<='0';
        m_word<=0; m_surface<=0; m_ridge<=0; m_guide<=0; m_region_context<=0;
      elsif advance='1' then
        valid1<=window_valid; valid2<=valid1; m_valid<=valid2;
        if window_valid='1' then
          center:=window_samples(4*27+23 downto 4*27);
          center_tag:=window_samples(4*27+26 downto 4*27+24);
          wide:=aligned(23 downto 0);
          ridge_value:=as_nat(aligned(53 downto 26));
          center1<=center; meta1<=aligned;
          strength1<=hi(dominant_residual(center,wide).magnitude,hi(ridge_value/256 mod 256,ridge_value mod 256)/8);
          guide1<=2**20*hi(ridge_value/256 mod 256,ridge_value mod 256)+source_guide(center,wide);
          for i in near_flank1'range loop
            near_flank1(i)<=(tap_luma4(window_samples,NEAR_A(i))+
                            2*tap_luma4(window_samples,NEAR_M(i))+
                            tap_luma4(window_samples,NEAR_B(i))+2)/4;
            far_flank1(i)<=(tap_luma4(mixed_samples,FAR_A_MIXED(i))+
                           2*tap_luma4(window_samples,FAR_M(i))+
                           tap_luma4(mixed_samples,FAR_B_MIXED(i))+2)/4;
          end loop;
          for row in near_rows1'range loop
            near_rows1(row)<=tap_luma4(window_samples,3*row)+tap_luma4(window_samples,3*row+1)+
                             tap_luma4(window_samples,3*row+2);
          end loop;
          for group_index in ring_groups1'range loop
            a:=tap_luma4(window_samples,FAR_RING(2*group_index)) +
               tap_luma4(window_samples,FAR_RING(2*group_index+1));
            b:=tap_luma4(mixed_samples,2*group_index)+tap_luma4(mixed_samples,2*group_index+1);
            ring_groups1(group_index)<=a+b;
          end loop;
          for n in TAPS'range loop
            index:=27*TAPS(n);
            tap_color:=window_samples(index+23 downto index);
            neighbor_tag:=window_samples(index+26 downto index+24);
            matches1(n)<='0';
            if center_tag/="000" and neighbor_tag=center_tag then matches1(n)<='1'; end if;
            for k in 0 to 2 loop
              lower_bit:=8*k;
              deltas1(n)(k)<=bound(as_nat(tap_color(lower_bit+7 downto lower_bit))-
                                   as_nat(center(lower_bit+7 downto lower_bit)),-10,10);
            end loop;
          end loop;
        end if;

        if valid1='1' then
          near_sum:=(near_rows1(0)+near_rows1(1))+near_rows1(2);
          ring_sum:=(ring_groups1(0)+ring_groups1(1))+(ring_groups1(2)+ring_groups1(3));
          inner2<=(near_sum+4)/9;
          outer2<=(near_sum+ring_sum+12)/25;
          ridge_value:=as_nat(meta1(53 downto 26));
          flank_shift2<=warm_flank_shift(near_flank1,far_flank1,center1,meta1(23 downto 0),
                                        hi(ridge_value/256 mod 256,ridge_value mod 256));
          meta2<=meta1; center2<=center1; guide2<=guide1;
          near_votes:=0; far_votes:=0;
          for n in 0 to 3 loop
            if matches1(n)='1' then near_votes:=near_votes+1; end if;
            if matches1(n+4)='1' then far_votes:=far_votes+1; end if;
          end loop;
          if strength1>=18 then
            class2<=major_boundary;
          elsif strength1>=3 and near_votes>=2 and far_votes>=2 and near_votes+far_votes>=5 then
            class2<=medium_structure;
          elsif strength1>=2 then
            class2<=fine_texture;
          else
            class2<=noise;
          end if;
          move2<='0';
          for k in 0 to 2 loop
            acc:=0;
            for n in TAPS'range loop acc:=acc+deltas1(n)(k); end loop;
            if dist(acc,0)>=23 then move2<='1'; end if;
            offsets2(k)<=round_shift(acc,3);
          end loop;
        end if;

        if valid2='1' then
          case class2 is
            when noise            => amount:=16;
            when fine_texture     => amount:=12;
            when medium_structure => amount:=4;
            when major_boundary   => amount:=0;
          end case;
          if move2='0' then amount:=0; end if;
          for k in 0 to 2 loop
            lower_bit:=8*k;
            value:=as_nat(center2(lower_bit+7 downto lower_bit));
            displacement:=round_shift(amount*offsets2(k),4);
            result_color(lower_bit+7 downto lower_bit):=std_logic_vector(to_unsigned(bound(bound(value+displacement,0,255)+flank_shift2,0,255),8));
          end loop;
          ridge_value:=as_nat(meta2(53 downto 26));
          region_color:=region_context(meta2(23 downto 0),inner2,outer2,
                                      hi(ridge_value/256 mod 256,ridge_value mod 256));
          -- Let the wide field follow a quarter of the same signed shift.
          for k in 0 to 2 loop
            lower_bit:=8*k;
            value:=as_nat(region_color(lower_bit+7 downto lower_bit));
            region_color(lower_bit+7 downto lower_bit):=std_logic_vector(to_unsigned(
              bound(value+round_shift(flank_shift2,2),0,255),8));
          end loop;
          m_region_context<=as_nat(region_color);
          m_surface<=as_nat(result_color); m_word<=as_nat(meta2(25 downto 0));
          m_ridge<=as_nat(meta2(53 downto 26)); m_guide<=guide2;
        end if;
      end if;
    end if;
  end process;
end architecture;
