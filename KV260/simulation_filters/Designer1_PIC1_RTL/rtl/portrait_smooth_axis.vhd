library ieee;
use ieee.std_logic_1164.all;

-- One centered, edge-aware [1 2 1] pass along a single image axis.
-- Bits 25:24 carry SOF and EOL. Bits 23:0 carry the source RGB888.
entity portrait_smooth_axis is
  generic (
    G_WIDTH     : positive;
    G_HEIGHT    : positive;
    G_STEP      : positive;
    G_VERTICAL  : boolean;
    G_THRESHOLD : natural range 0 to 255;
    G_FIXED_SPACING  : boolean := false;
    G_CAPTURE_CENTER : boolean := false;
    G_FORWARD_DETAIL : boolean := false
  );
  port (
    aclk, aresetn : in std_logic;
    s_word        : in natural range 0 to 2**26-1;
    s_valid       : in std_logic;
    s_ready       : out std_logic;
    m_word        : out natural range 0 to 2**26-1;
    m_valid       : out std_logic;
    m_ready       : in std_logic;
    s_detail      : in natural range 0 to 2**24-1 := 0;
    m_detail      : out natural range 0 to 2**24-1
  );
end entity;

architecture rtl of portrait_smooth_axis is
  function axis_length return positive is
  begin
    if G_VERTICAL then return G_HEIGHT; end if;
    return G_WIDTH;
  end function;

  function reach return natural is
  begin
    if G_STEP < axis_length then return G_STEP; end if;
    -- An oversized fixed stencil has neither neighbor anywhere on this axis.
    if G_FIXED_SPACING then return 0; end if;
    return axis_length-1;
  end function;

  function center_delay return natural is
  begin
    if G_VERTICAL then return reach*G_WIDTH; end if;
    return reach;
  end function;

  subtype word_t is natural range 0 to 2**26-1;
  type rgb_t is array (0 to 2) of natural range 0 to 255;

  function rgb(word : word_t) return rgb_t is
  begin
    return (word / 65536 mod 256, word / 256 mod 256, word mod 256);
  end function;

  function eligible(a, b : rgb_t) return boolean is
  begin
    for k in a'range loop
      if a(k) > b(k)+G_THRESHOLD or b(k) > a(k)+G_THRESHOLD then
        return false;
      end if;
    end loop;
    return true;
  end function;

  function smooth(far_word, center_word, near_word : word_t;
                  allow_far, allow_near : boolean) return word_t is
    variable lo, mid, hi, result_rgb : rgb_t;
  begin
    lo := rgb(far_word);
    mid := rgb(center_word);
    hi := rgb(near_word);
    if not allow_far or not eligible(lo, mid) then lo := mid; end if;
    if not allow_near or not eligible(hi, mid) then hi := mid; end if;
    for k in result_rgb'range loop
      result_rgb(k) := (lo(k) + mid(k)*2 + hi(k) + 2) / 4;
    end loop;
    return (center_word / 2**24)*2**24 +
           result_rgb(0)*65536 + result_rgb(1)*256 + result_rgb(2);
  end function;

  constant C_REACH : natural := reach;
  constant C_DELAY : natural := center_delay;
begin
  assert not (G_CAPTURE_CENTER and G_FORWARD_DETAIL)
    report "Only one source may drive the detail sideband" severity failure;

  singleton_axis : if C_DELAY = 0 generate
    m_detail <= (s_word mod 2**24) when G_CAPTURE_CENTER else s_detail;
    m_word <= s_word;
    m_valid <= s_valid;
    s_ready <= m_ready;
  end generate;

  active_axis : if C_DELAY > 0 generate
    constant C_DEPTH : positive := 2*C_DELAY;
    constant C_PIXELS : positive := G_WIDTH*G_HEIGHT;
    type history_t is array (0 to C_DEPTH-1) of word_t;
    signal history : history_t;
    signal oldest_addr : natural range 0 to C_DEPTH-1 := 0;
    signal center_addr : natural range 0 to C_DEPTH-1 := C_DELAY;
    signal inputs_before_current : natural range 0 to C_PIXELS-1 := 0;
    signal fill : natural range 0 to C_DELAY := 0;
    signal drain : natural range 0 to C_DELAY := 0;
    signal x : natural range 0 to G_WIDTH-1 := 0;
    signal y : natural range 0 to G_HEIGHT-1 := 0;
    signal far_word, center_word, near_word, incoming : word_t := 0;
    signal allow_far, allow_near : boolean := false;
    signal tap_valid, result_valid : std_logic := '0';
    signal advance, take_sample : std_logic;
  begin
    -- Horizontal context pass: the detail pixel is already in its center tap.
    capture_detail : if G_CAPTURE_CENTER generate
      process(aclk)
      begin
        if rising_edge(aclk) then
          if advance = '1' and tap_valid = '1' then
            m_detail <= center_word mod 2**24;
          end if;
        end if;
      end process;
    end generate;

    -- Vertical context pass: carry detail through just its center delay. This
    -- single-port RAM shares the tap memory's write address and clock enable.
    forward_detail : if G_FORWARD_DETAIL generate
      type detail_history_t is array (0 to C_DELAY-1) of natural range 0 to 2**24-1;
      signal detail_history : detail_history_t;
      signal detail_addr : natural range 0 to C_DELAY-1;
      signal center_detail : natural range 0 to 2**24-1;
    begin
      detail_addr <= oldest_addr when oldest_addr < C_DELAY else oldest_addr-C_DELAY;
      process(aclk)
      begin
        if rising_edge(aclk) then
          if take_sample = '1' then
            center_detail <= detail_history(detail_addr);
            detail_history(detail_addr) <= s_detail;
          end if;
          if advance = '1' and tap_valid = '1' then
            m_detail <= center_detail;
          end if;
        end if;
      end process;
    end generate;

    omit_detail : if not G_CAPTURE_CENTER and not G_FORWARD_DETAIL generate
      m_detail <= 0;
    end generate;

    -- Both tap and output registers freeze together under downstream stalls.
    advance <= (not result_valid) or m_ready;
    s_ready <= advance when aresetn = '1' and drain = 0 else '0';
    take_sample <= advance when aresetn = '1' and
                                (drain /= 0 or s_valid = '1') else '0';
    incoming <= s_word when drain = 0 else 0;
    m_valid <= result_valid;

    -- One read-before-write port and one independent synchronous read port.
    -- No reset of RAM contents. Border masks exclude stale words across SOF.
    history_ports : process(aclk)
    begin
      if rising_edge(aclk) then
        if take_sample = '1' then
          far_word <= history(oldest_addr);
          history(oldest_addr) <= incoming;
          center_word <= history(center_addr);
          near_word <= incoming;
        end if;
      end if;
    end process;

    pipeline : process(aclk)
    begin
      if rising_edge(aclk) then
        if aresetn = '0' then
          oldest_addr <= 0;
          center_addr <= C_DELAY;
          inputs_before_current <= 0;
          fill <= 0;
          drain <= 0;
          x <= 0;
          y <= 0;
          tap_valid <= '0';
          result_valid <= '0';
          m_word <= 0;
        elsif advance = '1' then
          result_valid <= tap_valid;
          if tap_valid = '1' then
            m_word <= smooth(far_word, center_word, near_word, allow_far, allow_near);
          end if;
          tap_valid <= '0';
          if take_sample = '1' then
            if oldest_addr = C_DEPTH-1 then oldest_addr <= 0;
            else oldest_addr <= oldest_addr+1; end if;
            if center_addr = C_DEPTH-1 then center_addr <= 0;
            else center_addr <= center_addr+1; end if;

            if fill = C_DELAY then
              tap_valid <= '1';
              if G_VERTICAL then
                allow_far <= y >= C_REACH;
                allow_near <= y < G_HEIGHT-C_REACH;
              else
                allow_far <= x >= C_REACH;
                allow_near <= x < G_WIDTH-C_REACH;
              end if;
              if x = G_WIDTH-1 then
                x <= 0;
                if y = G_HEIGHT-1 then y <= 0; else y <= y+1; end if;
              else
                x <= x+1;
              end if;
            else
              fill <= fill+1;
            end if;

            -- Flush the last delayed centers even if the next frame never comes.
            if drain /= 0 then
              drain <= drain-1;
              if drain = 1 then fill <= 0; end if;
            elsif inputs_before_current = C_PIXELS-1 then
              inputs_before_current <= 0;
              drain <= C_DELAY;
            else
              inputs_before_current <= inputs_before_current+1;
            end if;
          end if;
        end if;
      end if;
    end process;
  end generate;
end architecture;
