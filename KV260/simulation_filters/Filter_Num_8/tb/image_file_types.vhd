-- Simulation pixel types shared by the JPEG reader and BMP writer.
package image_file_types is
  subtype byte_t is natural range 0 to 255;
  subtype pixel_t is natural range 0 to 16#ffffff#;
  type rgb_t is array (0 to 2) of byte_t;
  function pack(c : rgb_t) return pixel_t;
  function unpack(p : pixel_t) return rgb_t;
  function clamp(v, lo, hi : integer) return integer;
  function largest(a, b : integer) return integer;
end package;
package body image_file_types is
  function pack(c : rgb_t) return pixel_t is
  begin return (c(0)*256+c(1))*256+c(2); end;
  function unpack(p : pixel_t) return rgb_t is
  begin return (p/65536, (p/256) mod 256, p mod 256); end;
  function clamp(v, lo, hi : integer) return integer is
  begin
    if v<lo then return lo; elsif v>hi then return hi; end if;
    return v;
  end;
  function largest(a,b : integer) return integer is
  begin if a>b then return a; end if; return b; end;
end package body;
