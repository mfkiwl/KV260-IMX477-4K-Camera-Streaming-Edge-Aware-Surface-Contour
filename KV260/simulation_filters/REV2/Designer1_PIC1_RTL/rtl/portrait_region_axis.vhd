library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.stroke_math_pkg.all;

-- Consolidate a rendered surface along a compatible axis. A dark center can
-- switch to a neighboring region only when no opposite pair sustains it.
entity portrait_region_axis is
  generic (G_WIDTH,G_HEIGHT : positive);
  port (clk,reset_n : in std_logic;
        s_word : in natural range 0 to 2**26-1;
        s_valid : in std_logic; s_ready : out std_logic;
        m_word : out natural range 0 to 2**26-1;
        m_valid : out std_logic; m_ready : in std_logic);
end entity;

architecture rtl of portrait_region_axis is
  type candidate_t is record
    cost : natural range 0 to 1530;
    color : rgb_t;
    flank : natural range 0 to 255;
    near_support,far_support : integer range -255 to 264;
  end record;
  type candidates_t is array(0 to 3) of candidate_t;
  signal taps : std_logic_vector(18*24-1 downto 0);
  signal flags,flags1,flags2,flags3 : std_logic_vector(1 downto 0);
  signal packed : std_logic_vector(25 downto 0);
  signal near1,far1,near2 : rgb9_t;
  signal yn1,yf1,yn2 : luma9_t;
  signal options : candidates_t;
  signal best3 : candidate_t;
  signal center3,median3 : rgb_t;
  signal median_level2 : natural range 0 to 255;
  signal repair3 : natural range 0 to 16;
  signal out4 : rgb_t;
  signal f4 : std_logic_vector(1 downto 0);
  signal v4 : std_logic;
  type offsets_t is array(0 to 2) of integer range -255 to 255;
  signal offsets4,region_delta4 : offsets_t;
  signal near_mean2,far_mean2,near_mean3,far_mean3 : integer range -14 to 14;
  signal win_valid,v1,v2,v3,advance : std_logic := '0';
  -- The two rank estimates and a compatible tangent describe one local plane.
  type plane_info_t is record
    level, center_y, flank : natural range 0 to 255;
    rank_support, middle_support, warm_votes, span_gain : natural range 0 to 16;
    rg, gb, br : integer range -255 to 255;
    tangent_rg : integer range -255 to 255;
  end record;
  type plane_weights_t is record
    level, center_y, flank : natural range 0 to 255;
    common_gain, dark_cool, red_gate, jacket, light, vote_gain, brown, red_low : natural range 0 to 16;
    middle_gain : natural range 0 to 12;
    shoulder_mix : natural range 0 to 256;
    neutral_cool : natural range 0 to 16;
    red_level : natural range 0 to 36;
    tangent_gap : natural range 0 to 16;
  end record;
  signal far_rank2, far_rank3 : natural range 0 to 255;
  signal span_gain2, span_gain3 : natural range 0 to 12;
  signal warm_votes2, warm_votes3 : natural range 0 to 9;
  signal plane4 : plane_info_t;
  signal weights5 : plane_weights_t;
  signal base5,base6 : rgb_t;
  signal flags5,flags6 : std_logic_vector(1 downto 0);
  signal adjust6 : offsets_t;
  signal v5,v6 : std_logic;
  function average(a,b,c,d : rgb_t) return rgb_t is
    variable p : rgb_t;
    variable low : natural;
  begin
    for k in 0 to 2 loop
      low:=8*k;
      p(low+7 downto low):=std_logic_vector(to_unsigned((as_nat(a(low+7 downto low))+as_nat(b(low+7 downto low))
                  +as_nat(c(low+7 downto low))+as_nat(d(low+7 downto low))+2)/4,8));
    end loop;
    return p;
  end;
begin
  packed<=std_logic_vector(to_unsigned(s_word,26));
  win : entity work.axis_stencil
    generic map(G_WIDTH,G_HEIGHT,2,5,24,2)
    port map(clk,reset_n,packed(23 downto 0),packed(25 downto 24),s_valid,s_ready,taps,flags,win_valid,advance);
  advance<=(not m_valid) or m_ready;
  process(clk)
    variable pn,pf,mean : rgb_t;
    variable i,j,amount,c,m,restored : natural;
    variable best : candidate_t;
    variable ns,fs,y,along,dev,red,blue,gmb,lip,warm_mid,structure_strength,pos,cool,hc,tint,devmag,rc,gc,bc : integer;
    function floor_div(x : integer; divisor : positive) return integer is
    begin
      if x<0 then return -((-x+divisor-1)/divisor); end if;
      return x/divisor;
    end;
    -- The center difference is zero. The eight remaining terms form a
    -- bounded estimate of the surround's offset from the central luminance.
    function bounded_mean(levels : luma9_t) return integer is
      type terms_t is array(0 to 3) of integer range -28 to 28;
      variable pairs : terms_t;
      variable center : integer := levels(4);
    begin
      for pair_index in pairs'range loop
        pairs(pair_index):=bound(levels(pair_index)-center,-14,14)
                          +bound(levels(8-pair_index)-center,-14,14);
      end loop;
      return floor_div((pairs(0)+pairs(1))+(pairs(2)+pairs(3))+4,8);
    end;
    variable medium,warm_weight,cool_weight,warm_step,cool_step,blue_shade : integer;
    variable count_warm : natural range 0 to 9;
    variable far_low, far_high : natural range 0 to 255;
    variable light_plane : natural range 0 to 40;
    variable near_level,level,illumination,warm,cool_gain,olive_gain,votes : natural;
    variable common,peak,lift,pale,reflected,shade,glow : integer;
  begin
    if rising_edge(clk) then
      if reset_n='0' then v1<='0'; v2<='0'; v3<='0'; v4<='0'; v5<='0'; v6<='0'; m_valid<='0'; m_word<=0;
      elsif advance='1' then
        v1<=win_valid; v2<=v1; v3<=v2; v4<=v3; v5<=v4; v6<=v5; m_valid<=v6;
        if win_valid='1' then
          flags1<=flags;
          for t in 0 to 8 loop
            pn:=taps(24*t+23 downto 24*t); pf:=taps(24*(9+t)+23 downto 24*(9+t));
            near1(t)<=pn; far1(t)<=pf; yn1(t)<=luma(pn); yf1(t)<=luma(pf);
          end loop;
        end if;
        if v1='1' then
          far_rank2<=median_luma(yf1);
          count_warm:=0; far_low:=yf1(4); far_high:=yf1(4);
          for k in far1'range loop
            far_low:=lo(far_low,yf1(k)); far_high:=hi(far_high,yf1(k));
            if as_nat(far1(k)(23 downto 16)) > as_nat(far1(k)(15 downto 8))+12 then
              count_warm:=count_warm+1;
            end if;
          end loop;
          warm_votes2<=count_warm;
          span_gain2<=bound((integer(far_high)-integer(far_low)-12)/2,0,12);
          near_mean2<=bounded_mean(yn1); far_mean2<=bounded_mean(yf1);
          flags2<=flags1; near2<=near1; yn2<=yn1; median_level2<=median_luma(yn1);
          for d in 0 to 3 loop
            i:=TAN_A(d); j:=TAN_B(d);
            options(d).cost<=2*(dist(yn1(i),yn1(4))+dist(yn1(j),yn1(4)))+dist(yf1(i),yn1(4))+dist(yf1(j),yn1(4));
            options(d).flank<=(yf1(NORM_A(d))+yf1(NORM_B(d))+1)/2;
            options(d).near_support<=integer(yn1(4))+6-hi(yn1(i),yn1(j));
            options(d).far_support<=integer(yn1(4))+9-hi(yf1(i),yf1(j));
            options(d).color<=average(near1(i),near1(j),far1(i),far1(j));
          end loop;
        end if;
        if v2='1' then
          far_rank3<=far_rank2; warm_votes3<=warm_votes2; span_gain3<=span_gain2;
          near_mean3<=near_mean2; far_mean3<=far_mean2;
          flags3<=flags2; center3<=near2(4); median3<=rank_color(near2,yn2,median_level2);
          best:=options(0); ns:=best.near_support; fs:=best.far_support;
          for d in 1 to 3 loop
            if options(d).cost<best.cost then best:=options(d); end if;
            ns:=hi(ns,options(d).near_support); fs:=hi(fs,options(d).far_support);
          end loop;
          best3<=best; repair3<=0;
          if median_level2>yn2(4)+3 and ns<0 and fs<0 then
            repair3<=bound(2*lo(-ns,-fs),0,14);
          end if;
        end if;
        if v3='1' then
          amount:=bound((68-integer(best3.cost))/2,0,18);
          for k in 0 to 2 loop
            c:=as_nat(center3(8*k+7 downto 8*k)); m:=as_nat(best3.color(8*k+7 downto 8*k));
            restored:=(c*(32-amount)+m*amount+16)/32;
            m:=as_nat(median3(8*k+7 downto 8*k));
            mean(8*k+7 downto 8*k):=std_logic_vector(to_unsigned((restored*(16-repair3)+m*repair3+8)/16,8));
          end loop;
          y:=luma(center3); rc:=as_nat(center3(23 downto 16)); gc:=as_nat(center3(15 downto 8)); bc:=as_nat(center3(7 downto 0));
          along:=(2*y+luma(best3.color)+1)/3; dev:=along-integer(best3.flank);
          red:=rc-gc; blue:=bc-rc; gmb:=gc-bc; devmag:=dist(along,best3.flank);
          lip:=bound(red-20,0,24)*bound(24-hi(0,3*(gmb-8)),0,24)/24;
          warm_mid:=bound((146-y)/2,0,24)*bound((red-14)/2,0,24)/24;
          structure_strength:=(bound(24-integer(best3.cost)/3,0,20)*bound(devmag-2,0,16)+8)/16;
          pos:=(structure_strength*warm_mid+8)/16;
          pos:=(pos*(8+lip)+8)/16;
          if dev<=0 then pos:=floor_div(-pos,3); end if;
          pos:=floor_div(pos*bound(12+lip,0,24)+12,24);
          cool:=bound((blue-8)/2,0,18)*bound((52-y)/2,0,16)/16;
          hc:=2*bound(floor_div(along-20,3),-3,5);
          hc:=floor_div(hc*cool+8,16);
          hc:=floor_div(hc*bound(2*devmag,0,16)+8,16);
          tint:=(lip*bound(8+dev,0,20)+16)/32;
          offsets4<=(floor_div(pos,2)+tint/2+hc,pos+hc,pos+tint+floor_div(hc,3));
          medium:=bound(near_mean3-far_mean3,-8,8);
          medium:=floor_div(medium+1,2);
          warm_weight:=bound((red-4)/2,0,16)*bound((gmb+4)/2,0,16)/16;
          cool_weight:=bound((blue-1)/2,0,16)*bound(56-y,0,16)/16;
          warm_step:=floor_div(medium*warm_weight+8,16);
          cool_step:=floor_div(medium*cool_weight+8,16);
          blue_shade:=(bound((50-y-near_mean3)/2,0,16)*cool_weight+8)/16;
          blue_shade:=(blue_shade*bound(3*dist(far_mean3,0),0,16)+8)/16;
          region_delta4<=(floor_div(warm_step+1,2)+floor_div(3*cool_step,2),
                          warm_step+cool_step, floor_div(warm_step,2)-blue_shade);
          near_level:=luma(median3);
          plane4.level<=(near_level+far_rank3+2*luma(best3.color)+2)/4;
          plane4.center_y<=y; plane4.flank<=best3.flank;
          plane4.rg<=red; plane4.gb<=gmb; plane4.br<=blue;
          plane4.tangent_rg<=integer(as_nat(best3.color(23 downto 16)))-integer(as_nat(best3.color(15 downto 8)));
          plane4.rank_support<=bound(18-integer(dist(near_level,far_rank3))/3,0,16);
          plane4.middle_support<=bound(lo(near_level,far_rank3)-12,0,12)*bound(52-hi(near_level,far_rank3),0,16)/16;
          plane4.warm_votes<=warm_votes3; plane4.span_gain<=span_gain3;
          out4<=mean; f4<=flags3;
        end if;
        if v4='1' then
          for k in 0 to 2 loop
            c:=as_nat(out4(8*k+7 downto 8*k));
            mean(8*k+7 downto 8*k):=std_logic_vector(to_unsigned(bound(bound(integer(c)+offsets4(k),0,255)+region_delta4(k),0,255),8));
          end loop;
          base5<=mean; flags5<=f4;
          level:=plane4.level;
          illumination:=bound((90-integer(level))/2,0,16);
          warm:=bound((plane4.rg-8)/2,0,16);
          cool_gain:=bound((plane4.br+2)/2,0,16);
          olive_gain:=bound(2*(plane4.gb-3),0,16)*bound(16-plane4.rg,0,16)/16;
          votes:=bound(4*plane4.warm_votes,0,16);
          weights5.level<=level; weights5.center_y<=plane4.center_y; weights5.flank<=plane4.flank;
          weights5.common_gain<=hi(hi(warm,cool_gain)*illumination/16,olive_gain)*plane4.rank_support/16;
          weights5.dark_cool<=(cool_gain*illumination+8)/16;
          weights5.middle_gain<=plane4.middle_support;
          weights5.red_gate<=(warm*illumination+8)/16;
          weights5.red_level<=bound(plane4.rg-6,0,36);
          weights5.jacket<=bound(135-integer(level),0,16)*olive_gain/16;
          weights5.light<=bound((integer(level)-41)/2,0,16)*bound((plane4.br-4)/2,0,16)/16;
          weights5.tangent_gap<=bound(plane4.tangent_rg-plane4.rg,0,16);
          weights5.vote_gain<=votes;
          weights5.brown<=((votes*bound((integer(level)-26)/2,0,16)/16)*bound(3*plane4.gb-plane4.rg+4,0,16)+8)/16;
          -- A broad color transition can support a brighter midlevel on its
          -- neutral/cool side. Warm votes and flank span protect quiet areas.
          weights5.shoulder_mix<=(bound(integer(level)-46,0,16)*bound(128-integer(level),0,16)/16)
                                *bound(plane4.span_gain+4*plane4.warm_votes,0,16);
          -- Limit the neutral shadow lift when no neighboring tap is warm.
          weights5.neutral_cool<=(bound(3*(plane4.br+12),0,16)*bound(12*plane4.warm_votes+6,0,16)+8)/16;
          weights5.red_low<=warm*bound(2*(8-plane4.gb),0,16)/16;
        end if;
        if v5='1' then
          base6<=base5; flags6<=flags5;
          level:=weights5.level;
          common:=floor_div(bound(integer(level)-integer(weights5.center_y),-20,20)*weights5.common_gain+16,32);
          lift:=(3*weights5.middle_gain*weights5.dark_cool+128)/256;
          peak:=bound(integer(weights5.center_y)-hi(level,weights5.flank)-2,0,20)*weights5.dark_cool/16;
          pale:=weights5.light*weights5.tangent_gap/16;
          reflected:=(24*weights5.light*weights5.vote_gain+128)/256;
          shade:=-((bound(90-integer(level),0,20)*weights5.brown+8)/16);
          light_plane:=(40*weights5.shoulder_mix*weights5.neutral_cool+2048)/4096;
          glow:=(bound(60-integer(level),0,30)*weights5.red_low+8)/16;
          adjust6(2)<=common+(lift+2)/4-peak/2-(weights5.red_level*weights5.red_gate+8)/16
                      +pale+reflected+glow+shade+light_plane+light_plane/2;
          adjust6(1)<=common+lift-peak+(bound((57-integer(level))/2,0,12)*weights5.red_gate+8)/16
                      +(pale+1)/2+reflected/2+(glow+1)/2+shade+light_plane;
          adjust6(0)<=common+lift/2-peak+(bound((57-integer(level))/2,0,10)*weights5.red_gate+8)/16
                      -(6*weights5.jacket+8)/16-pale/2-reflected/4+glow/4+floor_div(shade,2)+light_plane/4;
        end if;
        if v6='1' then
          for k in 0 to 2 loop
            c:=as_nat(base6(8*k+7 downto 8*k));
            mean(8*k+7 downto 8*k):=std_logic_vector(to_unsigned(bound(integer(c)+adjust6(k),0,255),8));
          end loop;
          m_word<=as_nat(flags6 & mean);
        end if;
      end if;
    end if;
  end process;
end architecture;
