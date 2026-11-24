library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.live_tone_pkg.all;
use std.env.all;

-- Static test of the pre-render Y, R-G, G-B quantities. Expected entries
-- combine the previous verified tone function with independently calculated
-- signed changes to the regional grade.
entity tb_tone_planes is generic (G_OBSERVE : boolean := false); end entity;
architecture test of tb_tone_planes is
  type triple_t is array(0 to 2) of integer;
  type triple_bank_t is array(natural range <>) of triple_t;
  constant SURFACE : triple_bank_t := ((22,22,24),(24,24,26),(19,19,20),(27,26,27),
       (23,24,25),(15,15,16),(37,33,30),(24,23,21),(70,75,55),(66,71,51),
       (74,79,59),(68,79,57),(83,54,37),(167,170,151),(64,64,64),(28,25,30));
  constant BROAD : triple_bank_t := ((22,22,24),(22,22,24),(21,21,22),(22,22,24),
       (21,22,23),(15,15,16),(36,32,30),(19,19,20),(70,75,55),(70,75,55),
       (70,75,55),(70,75,55),(80,50,36),(165,164,149),(64,64,64),(20,20,20));
  constant WANT : triple_bank_t := ((18,-36,-17),(28,-40,-17),(12,-36,-15),(45,-44,-20),
    (28,-44,-16),(5,-36,-15),(63,32,-6),(28,-44,-16),(127,-16,55),(128,-17,54),
    (128,-14,57),(127,-15,56),(112,148,43),(176,3,43),(112,-18,-12),(62,-22,-27));
  function packed(c : triple_t) return rgb888_t is
  begin
    return std_logic_vector(to_unsigned(c(0)*65536+c(1)*256+c(2),24));
  end function;
begin
  process
    variable g : graded_t;
    variable v : triple_t;
  begin
    for i in SURFACE'range loop
      g:=grade(local_tone(packed(SURFACE(i)),packed(BROAD(i)),0));
      v:=(g.luminance,g.red_green,g.green_blue);
      if G_OBSERVE then
        report "P " & integer'image(i) & " " & integer'image(v(0)) & " " &
               integer'image(v(1)) & " " & integer'image(v(2));
      else
        assert v=WANT(i)
          report "Tone case " & integer'image(i) & " got " & integer'image(v(0)) &
                 " " & integer'image(v(1)) & " " & integer'image(v(2)) severity failure;
      end if;
    end loop;
    report "TONE PLANE PASS 16 pre-render luminance and chroma triples";
    finish; wait;
  end process;
end architecture;
