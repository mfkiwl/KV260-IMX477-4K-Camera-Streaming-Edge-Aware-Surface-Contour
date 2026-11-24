library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package live_tone_pkg is
    function tone_with_context(detail, context_rgb : std_logic_vector(23 downto 0)) return std_logic_vector;
end package;

package body live_tone_pkg is
    function limit(x, lo, hi : integer) return integer is
    begin
        if x < lo then return lo; end if;
        if x > hi then return hi; end if;
        return x;
    end function;

    -- An arithmetic shift implements floor division on signed intermediate values.
    function shr(x : integer; bits : natural) return integer is
    begin
        return to_integer(shift_right(to_signed(x, 18), bits));
    end function;

    function unsigned_byte(x : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(limit(x, 0, 255), 8));
    end function;

    function tone_with_context(detail, context_rgb : std_logic_vector(23 downto 0)) return std_logic_vector is
        variable r, g, b, y : integer range 0 to 255;
        variable context_r, context_g, context_b, context_y : integer range 0 to 255;
        variable luma_difference : integer range 0 to 255;
        variable trust : integer range 0 to 12;
        variable rg, gb : integer range -255 to 255;
        variable warm, shadow, yellow_guard, cool, toe, room : integer range 0 to 16;
        variable olive : integer range 0 to 12;
        variable lum, rg_out, gb_out, green : integer range -2048 to 2047;
    begin
        r := to_integer(unsigned(detail(23 downto 16)));
        g := to_integer(unsigned(detail(15 downto 8)));
        b := to_integer(unsigned(detail(7 downto 0)));
        y := (r + 2*g + b + 2)/4;
        context_r := to_integer(unsigned(context_rgb(23 downto 16)));
        context_g := to_integer(unsigned(context_rgb(15 downto 8)));
        context_b := to_integer(unsigned(context_rgb(7 downto 0)));
        context_y := (context_r + 2*context_g + context_b + 2)/4;

        -- On a smooth surface use up to 3/4 of the broad chroma estimate.
        -- Luminance discontinuities reduce the influence of the broader taps.
        if y >= context_y then
            luma_difference := y - context_y;
        else
            luma_difference := context_y - y;
        end if;
        trust := limit(12-luma_difference,0,12);
        rg := r-g + shr(((context_r-context_g)-(r-g))*trust+8,4);
        gb := g-b + shr(((context_g-context_b)-(g-b))*trust+8,4);

        -- Red or yellow chroma suppresses the cool tint in shadows.
        -- Each mixture proportion is a Q4 value in the range 0 through 16.
        warm := limit(4*(rg-1)-limit(y-32,0,255)/16, 0, 16);
        shadow := limit(shr(80-y,1), 0, 16);
        yellow_guard := limit(2*(16-gb), 0, 16);
        cool := (shadow*(16-warm)*yellow_guard+128)/256;
        toe := limit(40-y,0,16);

        -- Increase exposure, roll off highlights, and preserve colored midtones.
        lum := 2*(y-8)-toe/2-limit(y-64,0,255)-limit(y-96,0,255)/2;
        room := limit(shr(128-y,2),0,16);
        lum := lum + (warm*room+8)/16;
        olive := limit(shr(gb,1),0,12);
        lum := lum + (olive*(16-warm)*room+128)/256;

        -- Scale the measured opponent channels and apply the shadow tint.
        rg_out := shr(7*rg,1)+2*warm-(9*cool+2)/4;
        gb_out := shr(5*gb,1)+shr(gb*warm,4)-(cool*(32-toe)*3+32)/64;

        -- The darker side of a broad boundary receives a modest ink accent.
        lum := lum-limit(context_y-y-8,0,24)/2;

        -- Soft luma steps retain half of the continuous luminance.
        lum := shr(lum+8*shr(lum+4,3),1);
        green := lum+shr(gb_out-rg_out+2,2);
        return unsigned_byte(green+rg_out) & unsigned_byte(green) &
               unsigned_byte(green-gb_out);
    end function;
end package body;
