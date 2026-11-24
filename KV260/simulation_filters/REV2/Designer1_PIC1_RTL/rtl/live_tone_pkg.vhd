library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package live_tone_pkg is
  subtype rgb888_t is std_logic_vector(23 downto 0);

  type local_tone_t is record
    center_y, y : natural range 0 to 255;
    delta, rg, gb, surround_rg, surround_gb : integer range -255 to 255;
    warm, dark_zone, structure : natural range 0 to 16;
    red_residual : integer range -3 to 3;
    fine_dark, fine_light : natural range 0 to 63;
    dir_dark, dir_light : natural range 0 to 255;
  end record;

  type graded_t is record
    luminance, red_green, green_blue : integer range -2048 to 2047;
    stroke : integer range -40 to 57;
    dark_crest : natural range 0 to 44;
  end record;

  function local_tone(surface, surround : rgb888_t; contours : natural) return local_tone_t;
  function grade(f : local_tone_t) return graded_t;
  function render(f : graded_t) return rgb888_t;
end package;

package body live_tone_pkg is
  function clamp(x, low, high : integer) return integer is
  begin
    if x < low then return low; end if;
    if x > high then return high; end if;
    return x;
  end function;

  function maximum(a, b : integer) return integer is
  begin
    if a > b then return a; end if;
    return b;
  end function;

  function minimum(a, b : integer) return integer is
  begin
    if a < b then return a; end if;
    return b;
  end function;

  -- Arithmetic right shift, including negative image differences.
  function shr(x : integer; bits : natural) return integer is
  begin
    return to_integer(shift_right(to_signed(x, 18), bits));
  end function;

  function local_tone(surface, surround : rgb888_t; contours : natural) return local_tone_t is
    variable f : local_tone_t;
    variable r, g, b, wr, wg, wb : natural range 0 to 255;
    variable difference : natural range 0 to 255;
    variable trust, surface_trust, chroma_trust : natural range 0 to 16;
    variable surface_rg, surface_gb : integer range -255 to 255;
    variable delta_rg, delta_gb : integer range -510 to 510;
    variable response, gate : natural range 0 to 16;
  begin
    r:=to_integer(unsigned(surface(23 downto 16)));
    g:=to_integer(unsigned(surface(15 downto 8)));
    b:=to_integer(unsigned(surface(7 downto 0)));
    wr:=to_integer(unsigned(surround(23 downto 16)));
    wg:=to_integer(unsigned(surround(15 downto 8)));
    wb:=to_integer(unsigned(surround(7 downto 0)));
    f.center_y:=(r+2*g+b+2)/4;
    f.delta:=(wr+2*wg+wb+2)/4-f.center_y;
    if f.delta < 0 then difference:=-f.delta; else difference:=f.delta; end if;
    trust:=clamp(16-2*maximum(difference-3,0),0,16);
    -- Measure the spatially filtered surface against its aligned broad context.
    -- Signed chroma residuals capture a color boundary even at nearly equal luma.
    surface_rg := r - g;
    surface_gb := g - b;
    delta_rg := (wr - wg) - surface_rg;
    delta_gb := (wg - wb) - surface_gb;
    response := clamp(4*difference + 2*maximum(maximum(delta_rg, -delta_rg), maximum(delta_gb, -delta_gb)) - 2, 0, 16);
    gate := maximum(clamp(3*(surface_rg-1), 0, 16), clamp(38-f.center_y, 0, 16));
    f.structure := (gate*response+8)/16;
    f.red_residual := clamp(-delta_rg, -3, 3);
    surface_trust := (trust*(16-(10*f.structure+8)/16)+8)/16;
    chroma_trust := (surface_trust+trust+1)/2;
    f.y := f.center_y + shr(f.delta*surface_trust+8,4);
    f.rg := surface_rg + shr(delta_rg*chroma_trust+8,4);
    f.gb := surface_gb + shr(delta_gb*chroma_trust+8,4);
    f.surround_rg:=wr-wg;
    f.surround_gb:=wg-wb;
    f.warm:=clamp(4*(f.rg-1)-maximum(f.y-32,0)/16,0,16);
    f.dark_zone:=clamp(46-f.y,0,16);
    f.fine_dark:=contours/2**22;
    f.fine_light:=contours/2**16 mod 64;
    f.dir_dark:=contours/256 mod 256;
    f.dir_light:=contours mod 256;
    return f;
  end function;

  function grade(f : local_tone_t) return graded_t is
    variable q : graded_t;
    variable shadow, yellow, cool, toe, room, olive, olive_gate, lit : natural range 0 to 16;
    variable activity_gate, amount, activity, guard, tint, shade_room : natural range 0 to 16;
    variable green_weight : natural range 0 to 256;
    variable region_y,tier,cool_zone,local_gate,bias,rg_magnitude : integer;
    variable sub,half_band,patch : integer;
    variable neutral, shadow_mix : natural range 0 to 16;
    variable broad_y : natural range 0 to 255;
    variable rounded : integer range -2 to 262;
    variable warm_exposure : integer range -255 to 510;
    variable plane_offset : integer range -5 to 4;
    variable lit_weight : natural range 0 to 16;
    variable plane_bias : integer range -26 to -2;
    variable chroma_strength : natural range 0 to 16;
    variable axial_ink : natural range 0 to 48;
    variable axial_highlight : natural range 0 to 20;
    variable floor_level, dark_amp, light_amp, ink, highlight : natural;
    variable lum, ro, go, plane, offset, delta_magnitude : integer;
  begin
    shadow:=clamp(shr(80-f.y,1),0,16);
    yellow:=clamp(2*(16-f.gb),0,16);
    cool:=(shadow*(16-f.warm)*yellow+128)/256;
    toe:=clamp(40-f.y,0,16);
    -- Retain measured yellow-green chroma in locally illuminated textured regions.
    olive_gate:=clamp(3*(f.gb-4),0,16);
    lit:=clamp((maximum(f.dir_dark,f.dir_light)+2)/4+clamp(-f.delta,0,8)-1,0,16);
    cool:=(cool*(16-(olive_gate*lit+8)/16)+8)/16;
    room:=clamp(shr(128-f.y,2),0,16);
    olive:=clamp(shr(f.gb,1),0,12);
    lum:=2*(f.y-8)-toe/2-maximum(f.y-64,0)-maximum(f.y-96,0)/2
         +(f.warm*room+8)/16+(olive*(16-f.warm)*room+128)/256;
    ro:=shr(7*f.rg,1)+2*f.warm-(9*cool+2)/4;
    go:=shr(5*f.gb,1)+shr(f.gb*f.warm,4)-(cool*(32-toe)*3+32)/64;

    -- A signed contour displaces an existing 16-code band threshold by at most
    -- five codes. Exposure and measured chroma protect bright neutral surfaces.
    activity_gate:=maximum(clamp(2*f.rg-f.gb,0,16),clamp(67-f.y,0,16));
    offset:=clamp(shr(f.dir_light-f.dir_dark+2,2),-5,5);
    offset:=shr(offset*activity_gate+8,4);
    green_weight:=clamp(2*(f.gb-4),0,16)*(16-f.warm);
    offset:=shr(offset*(16-green_weight/16)+8,4);
    if f.delta<0 then delta_magnitude:=-f.delta; else delta_magnitude:=f.delta; end if;
    activity:=clamp(3*delta_magnitude+f.fine_dark+f.fine_light,0,16);
    amount:=maximum(clamp(f.warm,4,16),minimum(clamp(2*(f.gb-6),0,16),activity));
    -- Medium structure retains the signed side of the broad surface and
    -- selects an intermediate level between adjacent 16-code plateaus.
    lum := lum + shr(clamp(-f.delta, -12, 12)*f.structure+16,5);
    plane:=16*shr(lum+offset+8,4);
    sub:=(clamp(delta_magnitude-1,0,4)*f.warm+2)/4;
    sub := maximum(sub, f.structure);
    half_band:=8*shr(lum+offset+4,3);
    plane:=plane+shr((half_band-plane)*sub+8,4);
    lum:=lum+shr((plane-lum)*amount+8,4);

    -- The fine path anchors narrow dark strokes and small highlights. Reuse the
    -- stronger of this response and the medium response at a shared boundary.
    guard:=(f.warm*clamp(shr(f.y-32,2),0,8)+8)/16;
    axial_ink:=clamp(3*(f.fine_dark-f.fine_light/2-2-clamp(2*guard-2*maximum(0,f.delta-3),0,16)),0,48);
    axial_ink:=maximum(axial_ink,clamp(f.delta-7,0,32)/2);
    axial_highlight:=clamp(2*(f.fine_light-f.fine_dark/2-2-clamp(2*guard-2*maximum(0,-f.delta-3),0,16)),0,20);
    lum:=lum+axial_highlight-axial_ink;

    floor_level:=5+((f.warm*(16-f.dark_zone)+8)/16)/2;
    dark_amp:=maximum(0,f.dir_dark-f.dir_light/2-floor_level);
    light_amp:=maximum(0,f.dir_light-f.dir_dark/2-floor_level);
    ink:=(clamp(dark_amp,0,40)*activity_gate+8)/16;
    highlight:=(clamp((6*light_amp+2)/4,0,48)*(f.dark_zone+3)+8)/16;
    q.stroke:=maximum(0,highlight-axial_highlight)-maximum(0,ink-axial_ink);
    tint:=clamp(shr(f.dir_dark-f.dir_light+2,2),0,16);
    ro:=ro-shr(ro*tint+32,6);
    go:=go-shr(go*tint+32,6);
    -- Consolidate chroma within yellow-green surfaces using the surrounding
    -- live opponent channels. A large luminance difference reduces the blend.
    chroma_strength:=(green_weight+8)/16;
    chroma_strength:=(chroma_strength*(8+clamp(24-delta_magnitude,0,8))+8)/16;
    q.red_green:=ro+shr((3*f.surround_rg-ro)*chroma_strength+16,5);
    q.green_blue:=go+shr((3*f.surround_gb-go)*chroma_strength+16,5);
    q.luminance:=lum+clamp(shr(minimum(0,f.delta)*(-integer(f.dark_zone))+8,4),0,12);
    -- Quantized local illumination on the brighter side of a shadow surface.
    patch:=clamp((-f.delta+1)/2,0,7)*6;
    patch:=(patch*clamp(52-f.center_y,0,16)+8)/16;
    patch:=(patch*(16-f.warm/2)+8)/16;
    q.luminance:=q.luminance+patch;
    q.red_green:=q.red_green-3*patch/4+(clamp(2*(f.rg-f.gb),0,12)*f.warm+8)/16;
    q.green_blue:=q.green_blue-patch/3;
    region_y:=f.center_y+shr(3*f.delta+2,2);
    tier:=4*clamp((region_y-19)/2,0,4)-6;
    if f.rg<0 then rg_magnitude:=-f.rg; else rg_magnitude:=f.rg; end if;
    cool_zone:=clamp(36-f.center_y,0,12)*clamp(12-3*rg_magnitude,0,12);
    local_gate:=clamp(4*delta_magnitude+maximum(f.dir_dark,f.dir_light)/2,0,16);
    bias:=(tier*cool_zone+72+16*144)/144-16;
    q.luminance:=q.luminance+shr(bias*local_gate+8,4);
    q.green_blue:=q.green_blue-(clamp(3*(f.rg-f.gb+1),0,12)*clamp(68-f.y,0,16)*f.warm+128)/256;
    -- Use broad exposure and local polarity to separate neighboring dark planes.
    neutral := clamp(16-3*rg_magnitude-2*maximum(0,f.gb-2), 0, 16);
    shadow_mix := (clamp(36-region_y,0,12)*neutral+8)/16;
    shadow_mix := (shadow_mix*(4+minimum(12,3*delta_magnitude))+8)/16;
    plane_bias := clamp(-f.delta,-12,12)-14;
    q.luminance := q.luminance + shr(shadow_mix*plane_bias+8,4);
    q.red_green := q.red_green + shr(f.red_residual*f.structure+8,4);
    -- Quantize the broad context. Only its signed rounding residual enters
    -- the warm surface, retaining small islands without raising contour gain.
    broad_y := f.center_y+f.delta;
    rounded := 8*((broad_y+6)/8)-2;
    lit_weight := (f.warm*clamp(2*(integer(broad_y)-55),0,16)+8)/16;
    q.luminance := q.luminance + shr((rounded-integer(broad_y))*lit_weight+8,4);
    -- Red-minus-blue distinguishes broad warm planes at a similar brightness.
    -- Weight their small luminance offsets with the existing warm light mask.
    warm_exposure := broad_y + f.surround_rg + f.surround_gb;
    if warm_exposure < 93 then
      plane_offset := -5;
    elsif warm_exposure >= 99 then
      plane_offset := 4;
    else
      plane_offset := 0;
    end if;
    q.luminance := q.luminance + shr(plane_offset*lit_weight+8,4);
    shade_room:=clamp((34-f.center_y)*2,0,16);
    q.dark_crest:=(shade_room*clamp(f.dir_light-f.dir_dark-3,0,44)+8)/16;
    return q;
  end function;

  function render(f : graded_t) return rgb888_t is
    type channels_t is array(0 to 2) of integer range -8192 to 8191;
    variable rgb : channels_t;
    variable green, c : integer;
    variable result : rgb888_t;
  begin
    green:=f.luminance+shr(f.green_blue-f.red_green+2,2);
    rgb:=(green+f.red_green,green,green-f.green_blue);
    for k in rgb'range loop
      c:=clamp(rgb(k),0,255);
      c:=clamp(c+shr(minimum(128,c+16)*f.stroke+64,7),0,255);
      c:=clamp(c+(minimum(72,c+24)*f.dark_crest+32)/64,0,255);
      result(23-8*k downto 16-8*k):=std_logic_vector(to_unsigned(c,8));
    end loop;
    return result;
  end function;
end package body;
