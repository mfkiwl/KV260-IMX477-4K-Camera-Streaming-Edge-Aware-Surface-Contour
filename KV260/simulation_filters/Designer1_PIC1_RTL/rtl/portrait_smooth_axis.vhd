library ieee;
use ieee.std_logic_1164.all;

-- Centered three-tap window for RGB surface processing or scalar luminance.
-- Bits 25:24 carry SOF and EOL. Bits 23:0 carry the source RGB888.
entity portrait_smooth_axis is
  generic (
    G_WIDTH     : positive;
    G_HEIGHT    : positive;
    G_STEP      : positive;
    G_VERTICAL  : boolean;
    G_THRESHOLD : natural range 0 to 255;
    G_CAPTURE_CENTER : boolean := false;
    G_FORWARD_DETAIL : boolean := false;
    G_SMOOTH_LUMA    : boolean := false;
    G_FORWARD_RIDGE  : boolean := false;
    G_MEASURE_FINE   : boolean := false;
    G_SURFACE_FINISH : boolean := false;
    G_RECONSTRUCT    : boolean := false;
    G_IMPULSE_STAGE  : natural range 0 to 2 := 0
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
    m_detail      : out natural range 0 to 2**24-1;
    s_ridge       : in natural range 0 to 2**28-1 := 0;
    m_ridge       : out natural range 0 to 2**28-1
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
    return 0;
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

  -- Optional contour-branch prefilter. Luma is carried in quarter-code units.
  -- Missing samples take the center value, as in the RGB smoother.
  function smooth_luma(far_word, mid_word, near_word : word_t;
                       allow_far, allow_near : boolean) return word_t is
    variable low, mid, high : natural range 0 to 1023;
  begin
    mid := mid_word mod 1024;
    low := mid;
    high := mid;
    if allow_far then low := far_word mod 1024; end if;
    if allow_near then high := near_word mod 1024; end if;
    return (mid_word / 2**24)*2**24 + (low + 2*mid + high + 2)/4;
  end function;

  function rounded_luma(v : word_t) return natural is
    variable p : rgb_t;
  begin
    p := rgb(v);
    return (p(0)+2*p(1)+p(2)+2)/4;
  end function;

  function fine_response(far_word, mid_word, near_word : word_t;
                         allow_far, allow_near : boolean; prior : natural) return natural is
    variable lo, center, hi : natural range 0 to 255;
    variable curve : integer range -255 to 255;
    variable dark, light : natural range 0 to 63;
  begin
    center := rounded_luma(mid_word);
    lo := center;
    hi := center;
    if allow_far then lo := rounded_luma(far_word); end if;
    if allow_near then hi := rounded_luma(near_word); end if;
    curve := center - (lo+hi+1)/2;
    dark := prior/2**22;
    light := prior/2**16 mod 64;
    if curve < -63 then dark := 63;
    elsif -curve > dark then dark := -curve;
    end if;
    if curve > 63 then light := 63;
    elsif curve > light then light := curve;
    end if;
    -- The original two direction-sensitive measurements keep their Q2 precision.
    return dark*2**22 + light*2**16 + prior mod 65536;
  end function;

  function eligible(a, b : rgb_t; threshold : natural) return boolean is
  begin
    for k in a'range loop
      if a(k) > b(k)+threshold or b(k) > a(k)+threshold then
        return false;
      end if;
    end loop;
    return true;
  end function;

  function distance(a, b : natural) return natural is
  begin
    if a > b then return a-b; end if;
    return b-a;
  end function;

  function minimum(a, b : natural) return natural is
  begin
    if a < b then return a; end if;
    return b;
  end function;

  function maximum(a, b : natural) return natural is
  begin
    if a > b then return a; end if;
    return b;
  end function;

  function pack(center : word_t; v : rgb_t) return word_t is
  begin
    return (center/2**24)*2**24 + v(0)*65536 + v(1)*256 + v(2);
  end function;

  function smooth(far_word, center_word, near_word : word_t;
                  allow_far, allow_near : boolean) return word_t is
    variable left, right, target, center, result_rgb : rgb_t;
    variable yl, yc, yr, dl, dr, contrast : natural range 0 to 255;
    variable cutoff, extra : natural range 0 to 255;
  begin
    center:=rgb(center_word);
    left:=center; right:=center;
    yc:=rounded_luma(center_word);
    yl:=yc; yr:=yc;
    if allow_far then left:=rgb(far_word); yl:=rounded_luma(far_word); end if;
    if allow_near then right:=rgb(near_word); yr:=rounded_luma(near_word); end if;
    contrast:=distance(yl,yr); dl:=distance(yc,yl); dr:=distance(yc,yr);
    -- Steepen the dark or bright side of a moderate transition. Select a
    -- measured neighbor only if the center is between the two tap luminances.
    if G_RECONSTRUCT and ((yl<yc and yc<yr) or (yr<yc and yc<yl)) and
       contrast>=10 and contrast<=52 and distance(dl,dr)>=3 and minimum(dl,dr)>=2 and
       (yc<=140 or center(0)>=center(1)+20) then
      if dl<dr then target:=left; else target:=right; end if;
      for k in result_rgb'range loop result_rgb(k):=(center(k)+3*target(k)+2)/4; end loop;
      return pack(center_word,result_rgb);
    end if;
    cutoff:=G_THRESHOLD;
    if G_SURFACE_FINISH then
      extra:=0;
      if yc>50 then extra:=minimum(8,(yc-50)/8); end if;
      cutoff:=G_THRESHOLD-minimum(G_THRESHOLD,8-extra);
    end if;
    if not eligible(left,center,cutoff) then left:=center; end if;
    if not eligible(right,center,cutoff) then right:=center; end if;
    for k in result_rgb'range loop result_rgb(k):=(left(k)+2*center(k)+right(k)+2)/4; end loop;
    return pack(center_word,result_rgb);
  end function;

  function pair_mean(left_word, right_word : word_t) return word_t is
    variable a, b, v : rgb_t;
  begin
    a:=rgb(left_word); b:=rgb(right_word);
    for k in v'range loop v(k):=(a(k)+b(k)+1)/2; end loop;
    return pack(0,v);
  end function;

  function pair_range(left_word, right_word : word_t) return natural is
    variable y1,y2 : natural range 0 to 255;
  begin
    y1:=rounded_luma(left_word); y2:=rounded_luma(right_word);
    return minimum(y1,y2)*256+maximum(y1,y2);
  end function;

  function clear_impulse(center, top, bottom : word_t; h_mean : word_t; h_range : natural) return word_t is
    variable low, high, yc, above, below : natural range 0 to 255;
    variable separation : integer range -255 to 255;
  begin
    above:=rounded_luma(top); below:=rounded_luma(bottom); yc:=rounded_luma(center);
    low:=minimum(h_range/256,minimum(above,below));
    high:=maximum(h_range mod 256,maximum(above,below));
    if yc<low then separation:=low-yc; else separation:=yc-high; end if;
    if separation>=3 and separation<=28 and high-low<=18 then
      return (center/2**24)*2**24 + pair_mean(h_mean,pair_mean(top,bottom));
    end if;
    return center;
  end function;

  constant C_REACH : natural := reach;
  constant C_DELAY : natural := center_delay;
begin
  assert not (G_CAPTURE_CENTER and G_FORWARD_DETAIL)
    report "Only one source may drive the detail sideband" severity failure;

  singleton_axis : if C_DELAY = 0 generate
    m_detail <= (s_word mod 2**24) when G_CAPTURE_CENTER or G_IMPULSE_STAGE=1 else s_detail;
    m_ridge <= pair_range(s_word,s_word) when G_IMPULSE_STAGE=1 else s_ridge;
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
    signal aligned_detail : natural range 0 to 2**24-1;
    signal clean_lo, clean_hi : word_t;
    signal aligned_ridge : natural range 0 to 2**28-1;
  begin
    -- Carry the contour measurement through the same center delay as its color.
    carry_ridge : if G_FORWARD_RIDGE generate
      type ridge_history_t is array (0 to C_DELAY-1) of natural range 0 to 2**28-1;
      signal ridge_history : ridge_history_t;
      signal addr : natural range 0 to C_DELAY-1;
    begin
      addr <= oldest_addr when oldest_addr < C_DELAY else oldest_addr-C_DELAY;
      process(aclk)
      begin
        if rising_edge(aclk) then
          if take_sample = '1' then
            aligned_ridge <= ridge_history(addr);
            ridge_history(addr) <= s_ridge;
          end if;
        end if;
      end process;
    end generate;
    omit_ridge : if not G_FORWARD_RIDGE generate
      aligned_ridge <= 0;
    end generate;

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

    begin
      detail_addr <= oldest_addr when oldest_addr < C_DELAY else oldest_addr-C_DELAY;
      process(aclk)
      begin
        if rising_edge(aclk) then
          if take_sample = '1' then
            aligned_detail <= detail_history(detail_addr);
            detail_history(detail_addr) <= s_detail;
          end if;
          if advance = '1' and tap_valid = '1' then
            m_detail <= aligned_detail;
          end if;
        end if;
      end process;
    end generate;

    no_detail_read : if not G_FORWARD_DETAIL generate
      aligned_detail <= 0;
    end generate;
    clean_lo <= far_word when allow_far else center_word;
    clean_hi <= near_word when allow_near else center_word;
    impulse_pair : if G_IMPULSE_STAGE=1 generate
      process(aclk)
      begin
        if rising_edge(aclk) and advance='1' and tap_valid='1' then
          m_detail <= pair_mean(clean_lo,clean_hi);
        end if;
      end process;
    end generate;
    omit_detail : if not G_CAPTURE_CENTER and not G_FORWARD_DETAIL and G_IMPULSE_STAGE/=1 generate
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
          m_ridge <= 0;
        elsif advance = '1' then
          result_valid <= tap_valid;
          if tap_valid = '1' then
            m_ridge <= aligned_ridge;
            if G_IMPULSE_STAGE=1 then
              m_word <= center_word;
              m_ridge <= pair_range(clean_lo,clean_hi);
            elsif G_IMPULSE_STAGE=2 then
              m_word <= clear_impulse(center_word,clean_lo,clean_hi,aligned_detail,aligned_ridge);
            elsif G_MEASURE_FINE then
              m_word <= center_word;
              m_ridge <= fine_response(far_word,center_word,near_word,allow_far,allow_near,aligned_ridge);
            elsif G_SMOOTH_LUMA then
              m_word <= smooth_luma(far_word, center_word, near_word, allow_far, allow_near);
            else
              m_word <= smooth(far_word, center_word, near_word, allow_far, allow_near);
            end if;
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
