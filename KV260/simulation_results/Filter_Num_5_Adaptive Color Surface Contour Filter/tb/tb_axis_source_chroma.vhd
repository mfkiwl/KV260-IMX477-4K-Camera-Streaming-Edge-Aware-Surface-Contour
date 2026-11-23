library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pic2_types.all;

entity tb_axis_source_chroma is end entity;
architecture bench of tb_axis_source_chroma is
  constant TOTAL : positive := 288;
  signal clk, reset_n, push, room, sv, sr, ss, sl, mode, mv, mr, ms, ml : std_logic := '0';
  signal raw_rgb, sd, md : std_logic_vector(23 downto 0);
  signal sent, filtered, received : natural range 0 to TOTAL := 0;
  signal tick : natural := 0;
  function source_pixel(n : natural) return rgb_t is
  begin
    case n mod 8 is
      when 0 => return (255,0,0);
      when 1 => return (0,255,0);
      when 2 => return (0,0,255);
      when 3 => return (n mod 256,n mod 256,n mod 256);
      when others => return ((13*n) mod 256,(71*n) mod 256,(181*n) mod 256);
    end case;
  end;
  function filter_pixel(n : natural) return rgb_t is
  begin
    case n mod 3 is
      when 0 => return (0,0,0);
      when 1 => return (255,255,255);
      when others => return ((47*n) mod 256,(5*n) mod 256,(19*n) mod 256);
    end case;
  end;
  function packed(p : rgb_t) return std_logic_vector is
  begin return std_logic_vector(to_unsigned(pack(p),24)); end;
begin
  clk <= not clk after 5 ns;
  reset_n <= '1' after 32 ns;
  raw_rgb <= packed(source_pixel(sent));
  -- Bursts of eight writes and a four-entry FIFO exercise both limits.
  push <= '1' when reset_n='1' and room='1' and sent<TOTAL and tick mod 23<8 else '0';
  sd <= packed(filter_pixel(filtered));
  sv <= '1' when reset_n='1' and filtered<TOTAL else '0';
  ss <= '1' when filtered mod 48=0 else '0';
  sl <= '1' when filtered mod 12=11 else '0';
  mode <= '1' when filtered mod 5=0 else '0';
  mr <= '1' when tick mod 37>=17 else '0';
  dut : entity work.axis_source_chroma
    generic map (G_DEPTH=>4)
    port map (clk,reset_n,raw_rgb,push,room,sd,sv,ss,sl,mode,sr,md,mv,ms,ml,mr);

  scoreboard : process(clk)
    variable src, dst, expected : rgb_t;
    variable offset, full_cycles, empty_cycles : integer := 0;
    variable held : boolean := false;
    variable held_value : std_logic_vector(25 downto 0);
  begin
    if rising_edge(clk) and reset_n='1' then
      tick <= tick+1;
      assert tick<4000 report "Chroma alignment timeout" severity failure;
      if room='0' then full_cycles := full_cycles+1; end if;
      if sent=filtered and sent<TOTAL and sv='1' and sr='0' then empty_cycles := empty_cycles+1; end if;
      if push='1' then sent <= sent+1; end if;
      if sv='1' and sr='1' then filtered <= filtered+1; end if;
      if held then
        assert mv='1' and (md & ms & ml)=held_value report "Output changed during stall" severity failure;
      end if;
      held := mv='1' and mr='0';
      if held then held_value := md & ms & ml; end if;
      if mv='1' and mr='1' then
        src := source_pixel(received); dst := filter_pixel(received); expected := dst;
        if received mod 5/=0 then
          offset := clamp(luma(dst)-luma(src),-smallest(src(0),smallest(src(1),src(2))),
                          255-largest(src(0),largest(src(1),src(2))));
          for k in 0 to 2 loop expected(k) := src(k)+offset; end loop;
        end if;
        assert md=packed(expected) report "RGB or source alignment mismatch" severity failure;
        assert (ms='1')=(received mod 48=0) and (ml='1')=(received mod 12=11)
          report "Marker alignment mismatch" severity failure;
        received <= received+1;
        if received=TOTAL-1 then
          assert full_cycles>0 and empty_cycles>0 severity failure;
          report "PASS: 288 pixels, FIFO full/empty, address wrap, gamut limits and held AXI data";
          finish;
        end if;
      end if;
    end if;
  end process;
end architecture;
