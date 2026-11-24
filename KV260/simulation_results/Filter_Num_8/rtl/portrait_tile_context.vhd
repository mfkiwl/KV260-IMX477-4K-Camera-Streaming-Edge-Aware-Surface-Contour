library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.portrait_types.all;

-- Compute tile averages as the input arrives. Four interleaved RAM banks allow
-- a one-clock fetch of the four adjacent tiles surrounding a delayed pixel.
entity portrait_tile_context is
  generic (FRAME_WIDTH, FRAME_HEIGHT, LOOKAHEAD, LOG_TILE : positive);
  port (clk, resetn, advance, write_pixel, read_pixel : in std_logic;
        x : in natural range 0 to FRAME_WIDTH-1;
        write_y, read_y : in natural range 0 to FRAME_HEIGHT;
        sample_in : in planes_t;
        smooth : out planes_t;
        slope : out slopes_t);
end entity;
architecture rtl of portrait_tile_context is
  constant K : positive := 2**LOG_TILE;
  constant NX : positive := ceil_div(FRAME_WIDTH,K);
  constant NY : positive := ceil_div(FRAME_HEIGHT,K);
  constant ACC_BITS : positive := 10+2*LOG_TILE;
  constant BANK_COLS : positive := ceil_div(NX,2);
  constant BANK_ROWS : positive := next_power2(min_nat(ceil_div(NY,2),ceil_div(LOOKAHEAD,2*K)+2));
  constant BANK_SIZE : positive := BANK_ROWS*BANK_COLS;
  subtype accum_word_t is std_logic_vector(4*ACC_BITS-1 downto 0);
  subtype tile_word_t is std_logic_vector(39 downto 0);
  type words4_t is array (0 to 3) of tile_word_t;
  type plane_corners_t is array (0 to 3) of planes_t;
  type axes_corners_t is array (0 to 3) of axes_t;
  type counters_t is array (0 to 3) of natural range 0 to K*1023;
  type indices_t is array (0 to 3) of natural range 0 to 3;
  type pair_t is array (0 to 1) of integer range -2046 to 2046;
  signal partial_x : counters_t;
  signal row_totals : counters_t;
  signal pending, first_row, final_row, bypass_partial : std_logic := '0';
  signal end_segment, partial_write, tile_write : std_logic;
  signal tile_x, saved_x : natural range 0 to NX-1;
  signal saved_y : natural range 0 to NY-1;
  signal partial_read_data, partial_write_data, forwarded : accum_word_t;
  signal mean_word : tile_word_t;
  signal x0,x1 : natural range 0 to NX-1;
  signal y0,y1 : natural range 0 to NY-1;
  signal x_phase, y_phase, px1, py1, px2, py2 : natural range 0 to K-1;
  signal bank_number : indices_t;
  signal bank_data : words4_t;
  signal hv0, hv1 : planes_t;
  signal dx0,dx1,dy0,dy1 : pair_t;
  signal rd1, rd2 : std_logic := '0';

  function mean_code(total, tx, ty : natural) return code10_t is
    constant LAST_W : positive := FRAME_WIDTH-(NX-1)*K;
    constant LAST_H : positive := FRAME_HEIGHT-(NY-1)*K;
  begin
    -- Four elaboration-time divisors cover the partial cells at the frame edges.
    if tx=NX-1 and ty=NY-1 then return (total+(LAST_W*LAST_H)/2)/(LAST_W*LAST_H);
    elsif tx=NX-1 then return (total+(LAST_W*K)/2)/(LAST_W*K);
    elsif ty=NY-1 then return (total+(K*LAST_H)/2)/(K*LAST_H);
    else return (total+K*K/2)/(K*K); end if;
  end;
  function bank_addr(tx,ty : natural) return natural is
  begin return ((ty/2) mod BANK_ROWS)*BANK_COLS+tx/2; end;
  function bank_id(tx,ty : natural) return natural is
  begin return 2*(ty mod 2)+(tx mod 2); end;
  function mix(a,b : integer; phase : natural) return integer is
    -- The positive offset makes division round signed differences toward -infinity.
  begin
    return a+((b-a)*integer(phase)+4096*K+K/2)/K-4096;
  end;
begin
  tile_x <= x/K;
  end_segment <= write_pixel when (x mod K)=K-1 or x=FRAME_WIDTH-1 else '0';
  partial_write <= advance and pending and resetn;
  tile_write <= partial_write and final_row;
  partial_sums : entity work.portrait_sdp_ram
    generic map (WORD_BITS=>4*ACC_BITS,DEPTH=>NX)
    port map (clk=>clk,wr_en=>partial_write,rd_en=>end_segment,wr_addr=>saved_x,
              rd_addr=>tile_x,wr_data=>partial_write_data,rd_data=>partial_read_data);

  accumulation : process(all)
    variable prior : accum_word_t;
    variable total : natural range 0 to K*K*1023;
    variable packed : accum_word_t;
    variable average : planes_t;
  begin
    packed := (others=>'0'); average := (others=>0);
    if pending='1' then
      if bypass_partial='1' then prior := forwarded; else prior := partial_read_data; end if;
      for ch in 0 to 3 loop
        total := row_totals(ch);
        if first_row='0' then total := total+to_integer(unsigned(prior((ch+1)*ACC_BITS-1 downto ch*ACC_BITS))); end if;
        packed((ch+1)*ACC_BITS-1 downto ch*ACC_BITS) := std_logic_vector(to_unsigned(total,ACC_BITS));
        if final_row='1' then average(ch) := mean_code(total,saved_x,saved_y); end if;
      end loop;
    end if;
    partial_write_data <= packed; mean_word <= pack_planes(average);
  end process;

  collect : process(clk)
    variable h : counters_t;
  begin
    if rising_edge(clk) then
      if resetn='0' then pending<='0'; bypass_partial<='0';
      elsif advance='1' then
        pending <= end_segment;
        if write_pixel='1' then
          for ch in 0 to 3 loop
            if (x mod K)=0 then h(ch):=sample_in(ch); else h(ch):=partial_x(ch)+sample_in(ch); end if;
          end loop;
          partial_x <= h;
          if end_segment='1' then
            row_totals<=h; saved_x<=tile_x; saved_y<=write_y/K;
            if (write_y mod K)=0 then first_row<='1'; else first_row<='0'; end if;
            if (write_y mod K)=K-1 or write_y=FRAME_HEIGHT-1 then final_row<='1'; else final_row<='0'; end if;
            -- Explicit forwarding also supports single-column images.
            if pending='1' and saved_x=tile_x then bypass_partial<='1'; else bypass_partial<='0'; end if;
            forwarded <= partial_write_data;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- Pixel positions are referred to tile centers. At an outer border both
  -- coordinates select the same edge tile, so interpolation replicates it.
  bounds : process(all)
  begin
    x0<=0; x1<=0; y0<=0; y1<=0;
    if x>=K/2 then x0<=min_nat((x-K/2)/K,NX-1); x1<=min_nat((x-K/2)/K+1,NX-1); end if;
    if read_y>=K/2 then y0<=min_nat((read_y-K/2)/K,NY-1); y1<=min_nat((read_y-K/2)/K+1,NY-1); end if;
  end process;
  x_phase<=(x+K/2) mod K; y_phase<=(read_y+K/2) mod K;

  banks : for i in 0 to 3 generate
    signal bx : natural range 0 to NX-1;
    signal by : natural range 0 to NY-1;
    signal we : std_logic;
  begin
    bx <= x0 when (x0 mod 2)=(i mod 2) else x1;
    by <= y0 when (y0 mod 2)=(i/2) else y1;
    we <= tile_write when bank_id(saved_x,saved_y)=i else '0';
    storage : entity work.portrait_sdp_ram
      generic map (WORD_BITS=>40,DEPTH=>BANK_SIZE)
      port map (clk=>clk,wr_en=>we,rd_en=>read_pixel,wr_addr=>bank_addr(saved_x,saved_y),
                rd_addr=>bank_addr(bx,by),wr_data=>mean_word,rd_data=>bank_data(i));
  end generate;

  interpolate : process(clk)
    variable c : plane_corners_t;
    variable a : axes_corners_t;
  begin
    if rising_edge(clk) then
      if resetn='0' then rd1<='0'; rd2<='0';
      elsif advance='1' then
        rd1<=read_pixel; rd2<=rd1;
        if read_pixel='1' then
          bank_number<=(bank_id(x0,y0),bank_id(x1,y0),bank_id(x0,y1),bank_id(x1,y1));
          px1<=x_phase; py1<=y_phase;
        end if;
        if rd1='1' then
          for i in 0 to 3 loop
            c(i) := unpack_planes(bank_data(bank_number(i)));
            a(i) := components((c(i)(0),c(i)(1),c(i)(2)));
          end loop;
          for ch in 0 to 3 loop hv0(ch)<=mix(c(0)(ch),c(1)(ch),px1); hv1(ch)<=mix(c(2)(ch),c(3)(ch),px1); end loop;
          for ch in 0 to 1 loop
            dx0(ch)<=a(1)(ch)-a(0)(ch); dx1(ch)<=a(3)(ch)-a(2)(ch);
            dy0(ch)<=a(2)(ch)-a(0)(ch); dy1(ch)<=a(3)(ch)-a(1)(ch);
          end loop;
          px2<=px1; py2<=py1;
        end if;
        if rd2='1' then
          for ch in 0 to 3 loop smooth(ch)<=mix(hv0(ch),hv1(ch),py2); end loop;
          for ch in 0 to 1 loop slope(2*ch)<=mix(dx0(ch),dx1(ch),py2); slope(2*ch+1)<=mix(dy0(ch),dy1(ch),px2); end loop;
        end if;
      end if;
    end if;
  end process;
end architecture;
