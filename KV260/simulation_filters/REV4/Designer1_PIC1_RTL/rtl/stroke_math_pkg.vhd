library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package stroke_math_pkg is
  subtype rgb_t is std_logic_vector(23 downto 0);
  subtype seeds_t is std_logic_vector(23 downto 0);
  type luma9_t is array(0 to 8) of natural range 0 to 511;
  type rgb9_t is array(0 to 8) of rgb_t;
  type index4_t is array(0 to 3) of natural range 0 to 8;
  -- Order of orientations: horizontal, vertical, descending and ascending diagonal.
  constant TAN_A : index4_t := (3,1,0,2);
  constant TAN_B : index4_t := (5,7,8,6);
  constant NORM_A : index4_t := (1,3,2,0);
  constant NORM_B : index4_t := (7,5,6,8);
  type strip_t is record
    gradient, phase : integer range -511 to 511;
    tangent : natural range 0 to 511;
    furrow : integer range -511 to 511;
  end record;
  type directions_t is array(0 to 3) of strip_t;
  function hi(a,b : integer) return integer;
  function lo(a,b : integer) return integer;
  function bound(v,a,b : integer) return integer;
  function dist(a,b : integer) return natural;
  function as_nat(v : std_logic_vector) return natural;
  function luma(p : rgb_t) return natural;
  function source_guide(surface,surround : rgb_t) return natural;
  function strips(v : luma9_t) return directions_t;
  function seed(fine,coarse : strip_t) return natural;
  function median_luma(v : luma9_t) return natural;
  function rank_color(v : rgb9_t; ys : luma9_t; middle : natural) return rgb_t;
  function surface_weight(center,anchor : rgb_t; olive,strength : natural) return natural;
  function blend48(center,anchor : rgb_t; w : natural) return rgb_t;
  function ink_amount(strength,side,olive,room,y : natural) return natural;
  function dark_flank_level(ys : luma9_t) return natural;
  function apply_ink(p,flank : rgb_t; ink,lift : natural) return rgb_t;
end package;

package body stroke_math_pkg is
  function hi(a,b : integer) return integer is
  begin if a>b then return a; end if; return b; end;
  function lo(a,b : integer) return integer is
  begin if a<b then return a; end if; return b; end;
  function bound(v,a,b : integer) return integer is
  begin return hi(a,lo(b,v)); end;
  function dist(a,b : integer) return natural is
  begin if a>=b then return a-b; end if; return b-a; end;
  function as_nat(v : std_logic_vector) return natural is
  begin return to_integer(unsigned(v)); end;
  function luma(p : rgb_t) return natural is
  begin return (as_nat(p(23 downto 16))+2*as_nat(p(15 downto 8))+as_nat(p(7 downto 0))+2)/4; end;
  function source_guide(surface,surround : rgb_t) return natural is
    variable y,d,r,g,b : integer;
    variable side,olive,room,lift : natural;
  begin
    y:=luma(surface); d:=integer(luma(surround))-y;
    r:=as_nat(surface(23 downto 16)); g:=as_nat(surface(15 downto 8)); b:=as_nat(surface(7 downto 0));
    side:=bound(13+d,0,31);
    olive:=bound(3*(g-b-3),0,16)*bound(16-3*(r-g-1),0,16)/16;
    room:=bound(80-y,0,24);
    lift:=bound(-d-2,0,12)*bound(58-y,0,16)/16;
    lift:=(lift*(16-olive)+8)/16;
    return side+32*olive+1024*room+32768*lift;
  end;
  function mean3(a,b,c : natural) return natural is
  begin return (a+2*b+c+2)/4; end;

  function strip(t0,c,t1,f0,f1 : natural) return strip_t is
    variable s : strip_t;
    variable mid : natural range 0 to 511;
  begin
    mid:=mean3(t0,c,t1);
    s.gradient:=integer(f1)-integer(f0);
    s.phase:=(f0+f1+1)/2-integer(mid);
    s.tangent:=dist(t0,t1);
    s.furrow:=lo(f0,f1)-mid;
    return s;
  end;
  function strips(v : luma9_t) return directions_t is
    variable s : directions_t;
  begin
    s(0):=strip(v(3),v(4),v(5),mean3(v(0),v(1),v(2)),mean3(v(6),v(7),v(8)));
    s(1):=strip(v(1),v(4),v(7),mean3(v(0),v(3),v(6)),mean3(v(2),v(5),v(8)));
    s(2):=strip(v(0),v(4),v(8),mean3(v(1),v(2),v(5)),mean3(v(3),v(6),v(7)));
    s(3):=strip(v(2),v(4),v(6),mean3(v(3),v(0),v(1)),mean3(v(7),v(8),v(5)));
    return s;
  end;
  function seed(fine,coarse : strip_t) return natural is
    variable step,ridge,f,g : integer;
  begin
    step:=0;
    if (fine.gradient>=0 and coarse.gradient>=0) or (fine.gradient<=0 and coarse.gradient<=0) then
      f:=hi(0,dist(fine.gradient,0)-fine.tangent/2);
      g:=hi(0,dist(coarse.gradient,0)-coarse.tangent/2);
      step:=lo((lo(255,lo(2*f,g))+1)/2,hi(0,12+fine.phase));
    end if;
    ridge:=3*hi(0,lo(fine.furrow,coarse.furrow));
    return lo(63,hi(step,ridge));
  end;
  function mid3(a,b,c : natural) return natural is
  begin return hi(lo(a,b),lo(hi(a,b),c)); end;
  function median_luma(v : luma9_t) return natural is
    type luma3_t is array(0 to 2) of natural range 0 to 511;
    variable lows,mids,highs : luma3_t;
  begin
    for row in 0 to 2 loop
      lows(row):=lo(v(3*row),lo(v(3*row+1),v(3*row+2)));
      mids(row):=mid3(v(3*row),v(3*row+1),v(3*row+2));
      highs(row):=hi(v(3*row),hi(v(3*row+1),v(3*row+2)));
    end loop;
    return mid3(hi(lows(0),hi(lows(1),lows(2))),mid3(mids(0),mids(1),mids(2)),lo(highs(0),lo(highs(1),highs(2))));
  end;
  function dark_flank_level(ys : luma9_t) return natural is
  begin
    return lo(mid3(ys(0),ys(1),ys(2)),lo(mid3(ys(3),ys(4),ys(5)),mid3(ys(6),ys(7),ys(8))));
  end;
  function rank_color(v : rgb9_t; ys : luma9_t; middle : natural) return rgb_t is
    type order_t is array(0 to 8) of natural range 0 to 8;
    constant ORDER : order_t := (4,5,3,7,1,8,6,2,0);
  begin
    for i in ORDER'range loop
      if ys(ORDER(i))=middle then return v(ORDER(i)); end if;
    end loop;
    return v(4);
  end;
  function surface_weight(center,anchor : rgb_t; olive,strength : natural) return natural is
    variable gap,weight : natural;
  begin
    gap:=0;
    for i in 0 to 2 loop
      gap:=hi(gap,dist(as_nat(center(8*i+7 downto 8*i)),as_nat(anchor(8*i+7 downto 8*i))));
    end loop;
    if strength<9 then weight:=bound(84-integer(gap),0,16);
    else weight:=bound(14-integer(gap),0,12); end if;
    return weight*(12+olive/4)/16;
  end;
  function blend48(center,anchor : rgb_t; w : natural) return rgb_t is
    variable c,a,value : natural;
    variable p : rgb_t;
  begin
    for i in 0 to 2 loop
      c:=as_nat(center(8*i+7 downto 8*i)); a:=as_nat(anchor(8*i+7 downto 8*i));
      value:=(c*(48-w)+a*w+24)/48;
      p(8*i+7 downto 8*i):=std_logic_vector(to_unsigned(value,8));
    end loop;
    return p;
  end;
  function ink_amount(strength,side,olive,room,y : natural) return natural is
    variable e,amount,penalty,side_limit,exposure : natural;
  begin
    if strength<15 then return 0; end if;
    e:=strength-8;
    amount:=lo(48,(e+1)/2+hi(0,integer(e)-6)+hi(0,integer(e)-18));
    penalty:=(bound(20-integer(side),0,8)*bound((integer(y)-72)/4,0,16)+8)/16;
    side_limit:=bound(integer(side)-integer(penalty),3,20);
    amount:=(amount*side_limit+8)/16;
    exposure:=lo(room,bound((156-integer(y))/2,0,24));
    amount:=(amount*exposure+12)/24;
    return (amount*(32-olive/2)+16)/32;
  end;
  function apply_ink(p,flank : rgb_t; ink,lift : natural) return rgb_t is
    type gains_t is array(0 to 2) of natural;
    constant GAINS : gains_t := (9,5,2); -- B, G, R
    variable c,f,target,value : natural;
    variable rgb : rgb_t;
  begin
    for i in 0 to 2 loop
      c:=as_nat(p(8*i+7 downto 8*i)); f:=as_nat(flank(8*i+7 downto 8*i));
      target:=(lo(c,f)*GAINS(i)+8)/16;
      value:=bound(integer(c)+to_integer(shift_right(to_signed((integer(target)-integer(c))*integer(ink)+32,16),6))
                   +(lo(112,32+c)*lift+32)/64,0,255);
      rgb(8*i+7 downto 8*i):=std_logic_vector(to_unsigned(value,8));
    end loop;
    return rgb;
  end;
end package body;
