library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pic2_types.all;

-- Meter the native RGB stream on an 8 by 8 grid. A metering-only frame can
-- precede a replay of a still image. Normal video uses the last complete frame.
entity axis_scene_exposure is
  generic (G_WIDTH : positive := 2048; G_HEIGHT : positive := 1152);
  port (
    aclk, aresetn : in std_logic;
    s_axis_tdata : in std_logic_vector(23 downto 0);
    s_axis_tvalid, s_axis_tuser, s_axis_tlast : in std_logic;
    s_axis_tready : out std_logic;
    s_axis_meter_only : in std_logic;
    m_axis_tdata : out std_logic_vector(23 downto 0);
    m_axis_tvalid, m_axis_tuser, m_axis_tlast : out std_logic;
    m_axis_tready : in std_logic
  );
end entity;

architecture rtl of axis_scene_exposure is
  constant STRIDE : positive := 8;
  constant SAMPLES : positive := ((G_WIDTH+STRIDE-1)/STRIDE)*((G_HEIGHT+STRIDE-1)/STRIDE);
  constant UNITY : positive := 256; -- Q8
  constant KNEE : natural := 70;
  constant ROLLOFF : positive := 33;
  type gain_vector_t is array (0 to 2) of natural range 0 to UNITY;
  type gain_table_t is array (0 to 255) of natural range 0 to UNITY;
  function make_curve return gain_table_t is
    variable table : gain_table_t;
    variable denominator : positive;
  begin
    for y in table'range loop
      denominator := ROLLOFF+largest(0,y-KNEE);
      table(y) := largest(64,(UNITY*ROLLOFF+denominator/2)/denominator);
    end loop;
    return table;
  end function;
  constant GAIN_CURVE : gain_table_t := make_curve;

  type state_t is (collect, average, configure);
  type sums_t is array (0 to 2) of natural range 0 to 255*SAMPLES;
  type products_t is array (0 to 2) of natural range 0 to 255*UNITY;
  signal state : state_t := collect;
  signal sum_rgb : sums_t := (others=>0);
  signal mean_rgb : rgb_t := (others=>0);
  signal gain_q8 : gain_vector_t := (others=>UNITY);
  signal frame_lift, pixel_lift : natural range 0 to 20 := 0;
  signal x : natural range 0 to G_WIDTH-1 := 0;
  signal y : natural range 0 to G_HEIGHT-1 := 0;
  signal meter_frame, drop_beat, advance, accept : std_logic := '0';
  signal products : products_t;
  signal valid0, valid1, sof0, eol0 : std_logic := '0';
begin
  advance <= not valid1 or m_axis_tready;
  s_axis_tready <= aresetn and advance when state=collect else '0';
  accept <= s_axis_tvalid and s_axis_tready;
  drop_beat <= s_axis_meter_only when s_axis_tuser='1' else meter_frame;
  m_axis_tvalid <= valid1;

  meter : process(aclk)
    variable c : rgb_t;
    variable base, warm, red_gain, blue_gain, lift : natural;
  begin
    if rising_edge(aclk) then
      if aresetn='0' then
        state <= collect; sum_rgb <= (others=>0); gain_q8 <= (others=>UNITY);
        frame_lift <= 0; x <= 0; y <= 0; meter_frame <= '0';
      else
        case state is
          when collect =>
            if accept='1' then
              -- synthesis translate_off
              assert (s_axis_tuser='1')=(x=0 and y=0) report "Meter input SOF misaligned" severity failure;
              assert (s_axis_tlast='1')=(x=G_WIDTH-1) report "Meter input EOL misaligned" severity failure;
              -- synthesis translate_on
              if s_axis_tuser='1' then meter_frame <= s_axis_meter_only; end if;
              if x mod STRIDE=0 and y mod STRIDE=0 then
                c := unpack(to_integer(unsigned(s_axis_tdata)));
                for ch in c'range loop sum_rgb(ch) <= sum_rgb(ch)+c(ch); end loop;
              end if;
              if x=G_WIDTH-1 then
                x <= 0;
                if y=G_HEIGHT-1 then y <= 0; state <= average;
                else y <= y+1;
                end if;
              else x <= x+1;
              end if;
            end if;
          when average =>
            for ch in mean_rgb'range loop
              mean_rgb(ch) <= (sum_rgb(ch)+SAMPLES/2)/SAMPLES;
            end loop;
            sum_rgb <= (others=>0);
            state <= configure;
          when configure =>
            base := GAIN_CURVE(luma(mean_rgb));
            -- Warmth correction tapers to zero as exposure approaches unity.
            warm := smallest(clamp(12-mean_rgb(0)+mean_rgb(2),0,24),(UNITY-base+4)/8);
            red_gain := smallest(UNITY,base+(2*warm+1)/3);
            blue_gain := base-warm;
            lift := (UNITY-base+5)/10;
            gain_q8 <= (red_gain,base,blue_gain); frame_lift <= lift;
            -- synthesis translate_off
            report "Meter mean RGB " & integer'image(mean_rgb(0)) & "," & integer'image(mean_rgb(1)) & "," & integer'image(mean_rgb(2)) &
                   "  Q8 gain " & integer'image(red_gain) & "," & integer'image(base) & "," & integer'image(blue_gain) &
                   "  shadow lift " & integer'image(lift);
            -- synthesis translate_on
            state <= collect;
        end case;
      end if;
    end if;
  end process;

  scale : process(aclk)
    variable c : rgb_t;
  begin
    if rising_edge(aclk) then
      if aresetn='0' then
        valid0 <= '0'; valid1 <= '0'; sof0 <= '0'; eol0 <= '0';
        m_axis_tdata <= (others=>'0'); m_axis_tuser <= '0'; m_axis_tlast <= '0';
      elsif advance='1' then
        valid0 <= accept and not drop_beat;
        valid1 <= valid0;
        if accept='1' and drop_beat='0' then
          c := unpack(to_integer(unsigned(s_axis_tdata)));
          for ch in c'range loop products(ch) <= c(ch)*gain_q8(ch); end loop;
          pixel_lift <= largest(0,frame_lift-(luma(c)+4)/8);
          sof0 <= s_axis_tuser; eol0 <= s_axis_tlast;
        end if;
        if valid0='1' then
          for ch in c'range loop
            c(ch) := smallest(255,(products(ch)+128)/UNITY+pixel_lift);
          end loop;
          m_axis_tdata <= std_logic_vector(to_unsigned(pack(c),24));
          m_axis_tuser <= sof0; m_axis_tlast <= eol0;
        end if;
      end if;
    end if;
  end process;
end architecture;
