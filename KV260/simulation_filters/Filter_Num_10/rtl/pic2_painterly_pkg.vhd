-- Fixed-point arithmetic shared by the painterly stages from source.pdf.
-- rgb_t is the project's RGB array. The tables below encode scalar weights,
-- normalization, or tone, never replacement colors.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pic2_types.all;

package pic2_painterly_pkg is
  constant C_MEDIUM_STEP  : positive := 2;
  constant C_COARSE_STEP  : positive := 4;
  constant C_CONTOUR_STEP : positive := 1;
  constant C_CHROMA_Q8    : positive := 288;

  type rgb_window_t is array (0 to 24) of rgb_t;
  type luma_window_t is array (0 to 24) of byte_t;
  type decay_lut_t is array (0 to 63) of byte_t;
  type recip_lut_t is array (0 to 1023) of unsigned(16 downto 0);
  type tone_lut_t is array (0 to 255) of byte_t;
  -- Maximum Scharr magnitude / 8 <= (4080 + 3*4080/8)/8 = 701.
  subtype mag_t is natural range 0 to 701;
  type mag_lut_t is array (mag_t) of byte_t;
  type direction_t is (horizontal, rising_diag, vertical, falling_diag);
  type gradient_t is record
    gx, gy : integer range -4080 to 4080;
  end record;
  type steps_t is array (direction_t) of positive;
  -- Index offsets on a row-major 5x5 window. Image y increases down.
  constant TANGENT : steps_t := (horizontal => 1, rising_diag => 4, vertical => 5, falling_diag => 6);
  constant NORMAL  : steps_t := (horizontal => 5, rising_diag => 6, vertical => 1, falling_diag => 4);

  function read_tap(bus_word : std_logic_vector(599 downto 0); i : natural) return rgb_t;
  function bt601(c : rgb_t) return byte_t;
  function scharr(y : luma_window_t; i : natural) return gradient_t;
  function gradient_mag(g : gradient_t) return mag_t;
  function tangent_dir(g : gradient_t) return direction_t;
  function decay_lut(sigma : positive) return decay_lut_t;
  function recip_lut return recip_lut_t;
  function tone_lut(shadow_lift : byte_t) return tone_lut_t;
  function ramp_lut(lo, hi : natural) return mag_lut_t;
end package;

package body pic2_painterly_pkg is
  function read_tap(bus_word : std_logic_vector(599 downto 0); i : natural) return rgb_t is
    variable offset : natural := i * 24;
  begin
    return (to_integer(unsigned(bus_word(offset+23 downto offset+16))),
            to_integer(unsigned(bus_word(offset+15 downto offset+8))),
            to_integer(unsigned(bus_word(offset+7 downto offset))));
  end;

  function bt601(c : rgb_t) return byte_t is
  begin
    return (77*c(0) + 150*c(1) + 29*c(2) + 128) / 256;
  end;

  function scharr(y : luma_window_t; i : natural) return gradient_t is
    variable gx, gy : integer;
  begin
    gx := 3*(y(i-4) - y(i-6)) + 10*(y(i+1) - y(i-1)) + 3*(y(i+6) - y(i+4));
    gy := 3*(y(i+4) - y(i-6)) + 10*(y(i+5) - y(i-5)) + 3*(y(i+6) - y(i-4));
    return (gx, gy);
  end;

  function gradient_mag(g : gradient_t) return mag_t is
    variable ax, ay : natural;
  begin
    ax := magnitude(g.gx);
    ay := magnitude(g.gy);
    return (largest(ax, ay) + 3 * smallest(ax, ay) / 8) / 8;
  end;

  function tangent_dir(g : gradient_t) return direction_t is
    variable ax, ay : natural;
  begin
    ax := magnitude(g.gx);
    ay := magnitude(g.gy);
    if ax * 77 < ay * 32 then return horizontal; end if;
    if ay * 77 < ax * 32 then return vertical; end if;
    if (g.gx < 0) = (g.gy < 0) then return rising_diag; end if;
    return falling_diag;
  end;

  function decay_lut(sigma : positive) return decay_lut_t is
    variable lut : decay_lut_t;
    variable s2, numerator, d, den : integer;
  begin
    -- The selectable sigma range keeps the elaboration arithmetic in 32 bits.
    assert sigma <= 53 report "Surface sigma must be in 1..53" severity failure;
    s2 := sigma * sigma;
    numerator := 255 * s2 * s2;
    for x in lut'range loop
      d := s2 + x*x;
      den := d*d;
      lut(x) := largest(1, (numerator + den/2)/den);
    end loop;
    return lut;
  end;

  function recip_lut return recip_lut_t is
    variable lut : recip_lut_t;
    variable denom : positive;
  begin
    for i in lut'range loop
      denom := largest(4, i);
      lut(i) := to_unsigned((262144 + denom/2)/denom, 17);
    end loop;
    return lut;
  end;

  function tone_lut(shadow_lift : byte_t) return tone_lut_t is
    variable lut : tone_lut_t;
  begin
    for y in lut'range loop
      lut(y) := smallest(255, y + shadow_lift * (255-y) * (255-y) / 65025);
    end loop;
    return lut;
  end;

  function ramp_lut(lo, hi : natural) return mag_lut_t is
    variable lut : mag_lut_t;
  begin
    assert hi > lo report "Upper edge threshold must exceed lower threshold" severity failure;
    for i in lut'range loop
      if i <= lo then lut(i) := 0;
      elsif i >= hi then lut(i) := 255;
      else lut(i) := (i-lo)*255/(hi-lo);
      end if;
    end loop;
    return lut;
  end;
end package body;
