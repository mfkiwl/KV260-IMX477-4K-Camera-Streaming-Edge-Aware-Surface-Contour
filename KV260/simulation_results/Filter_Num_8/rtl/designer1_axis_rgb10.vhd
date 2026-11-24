library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.portrait_types.all;
use work.portrait_coefficients.all;

entity designer1_axis_rgb10 is
  generic (DATA_WIDTH : positive := 32;
           FRAME_WIDTH : positive := 2048; FRAME_HEIGHT : positive := 1152;
           PIXEL_RAM_STYLE : string := "auto");
  port (
    aclk, aresetn : in std_logic;
    s_axis_tdata : in std_logic_vector(DATA_WIDTH-1 downto 0);
    s_axis_tvalid : in std_logic; s_axis_tready : out std_logic;
    s_axis_tuser, s_axis_tlast : in std_logic;
    m_axis_tdata : out std_logic_vector(DATA_WIDTH-1 downto 0);
    m_axis_tvalid : out std_logic; m_axis_tready : in std_logic;
    m_axis_tuser, m_axis_tlast : out std_logic
  );
end entity;
architecture rtl of designer1_axis_rgb10 is
  -- The 64-pixel grid can require up to 95 future rows. Three more rows
  -- cover partial tiles and the registered tile writer, including width=1.
  constant LOOKAHEAD : positive := 98;
  constant PIXELS_STORED : positive := 2*ceil_div(min_nat(FRAME_HEIGHT,LOOKAHEAD+1)*FRAME_WIDTH,2);
  type sizes_t is array (0 to 2) of positive;
  constant LOG_TILES : sizes_t := (2,4,6);
  type context_t is array (0 to 2) of planes_t;
  type directions_t is array (0 to 2) of slopes_t;
  type coords_t is array (0 to 2) of axes_t;
  type raw_delay_t is array(1 to 2) of std_logic_vector(31 downto 0);
  type base_delay_t is array(0 to 9) of rgb10_t;
  type marks_t is array (0 to 9) of std_logic_vector(1 downto 0);
  signal x : natural range 0 to FRAME_WIDTH-1 := 0;
  signal raster_y : natural range 0 to FRAME_HEIGHT+LOOKAHEAD-1 := 0;
  signal write_y, read_y : natural range 0 to FRAME_HEIGHT;
  signal wr_ptr, rd_ptr : natural range 0 to PIXELS_STORED-1 := 0;
  signal advance, step, write_pixel, read_pixel, ready_i : std_logic;
  signal raw_read : std_logic_vector(31 downto 0);
  signal raw_pipe : raw_delay_t;
  signal pixel_pair, pair_read : std_logic_vector(63 downto 0);
  signal low_pixel : std_logic_vector(31 downto 0);
  signal input_payload : std_logic_vector(31 downto 0);
  signal pair_write, read_high : std_logic;
  type stream_words_t is array (natural range <>) of std_logic_vector(29 downto 0);
  constant FINISH_STAGES : positive := FINISH_SPACING'length;
  signal stream_data : stream_words_t(0 to FINISH_STAGES);
  signal stream_valid, stream_ready, stream_sof, stream_eol : std_logic_vector(0 to FINISH_STAGES);
  signal live_planes : planes_t;
  signal prior_luma, in_luma : code10_t := 0;
  signal smooth : context_t;
  signal slopes : directions_t;
  signal f : values_t(0 to N_FEATURES-1);
  signal h1 : values_t(W1'range(1));
  signal h2 : values_t(W2'range(1));
  signal correction : values_t(W3'range(1));
  signal base : base_delay_t;
  signal marks : marks_t;
  signal valid : std_logic_vector(0 to 13) := (others=>'0');
  signal result : std_logic_vector(29 downto 0) := (others=>'0');
begin
  assert DATA_WIDTH>=30 report "DATA_WIDTH must hold three RGB10 lanes" severity failure;
  advance <= (not valid(13)) or stream_ready(0);
  ready_i <= advance and aresetn when raster_y<FRAME_HEIGHT else '0';
  s_axis_tready <= ready_i;
  -- After reset or frame drain, discard leading beats until an accepted SOF.
  write_pixel <= ready_i and s_axis_tvalid when x/=0 or raster_y/=0 or s_axis_tuser='1' else '0';
  step <= write_pixel when raster_y<FRAME_HEIGHT else advance and aresetn;
  read_pixel <= step when raster_y>=LOOKAHEAD else '0';
  write_y <= raster_y when raster_y<FRAME_HEIGHT else 0;
  read_y <= raster_y-LOOKAHEAD when raster_y>=LOOKAHEAD else 0;
  stream_data(0)<=result; stream_valid(0)<=valid(13);
  stream_ready(FINISH_STAGES)<=m_axis_tready;
  m_axis_tvalid<=stream_valid(FINISH_STAGES);
  m_axis_tuser<=stream_sof(FINISH_STAGES); m_axis_tlast<=stream_eol(FINISH_STAGES);
  m_axis_tdata<=std_logic_vector(resize(unsigned(stream_data(FINISH_STAGES)),DATA_WIDTH));
  finish : for i in FINISH_SPACING'range generate
    smoother : entity work.portrait_range_smooth
      generic map (FRAME_WIDTH,FRAME_HEIGHT,FINISH_SPACING(i),FINISH_THRESHOLD(i))
      port map (aclk,aresetn,stream_data(i),stream_valid(i),stream_ready(i),stream_sof(i),stream_eol(i),
                stream_data(i+1),stream_valid(i+1),stream_ready(i+1),stream_sof(i+1),stream_eol(i+1));
  end generate;

  input_features : process(all)
    variable pixel : rgb10_t;
    variable axes : axes_t;
    variable texture, difference : code10_t;
  begin
    live_planes<=(others=>0); in_luma<=0;
    if write_pixel='1' then
      pixel:=unpack_rgb(s_axis_tdata(29 downto 0)); axes:=components(pixel);
      texture:=0;
      if x/=0 then
        if axes(0)>=prior_luma then difference:=axes(0)-prior_luma;
        else difference:=prior_luma-axes(0); end if;
        texture:=min_nat(1023,8*difference);
      end if;
      live_planes<=(pixel(0),pixel(1),pixel(2),texture); in_luma<=axes(0);
    end if;
  end process;
  -- Pack adjacent pixels into 64-bit words so the large delay can use both
  -- halves of a 72-bit FPGA memory port. An odd final pixel commits by itself.
  input_payload<=s_axis_tuser & s_axis_tlast & s_axis_tdata(29 downto 0);
  pair_write<=write_pixel when (wr_ptr mod 2)=1 or (x=FRAME_WIDTH-1 and write_y=FRAME_HEIGHT-1) else '0';
  pixel_pair<=input_payload & low_pixel when (wr_ptr mod 2)=1 else x"00000000" & input_payload;
  raw_store : entity work.portrait_sdp_ram
    generic map (WORD_BITS=>64,DEPTH=>PIXELS_STORED/2,MEMORY_STYLE=>PIXEL_RAM_STYLE)
    port map (clk=>aclk,wr_en=>pair_write,rd_en=>read_pixel,wr_addr=>wr_ptr/2,rd_addr=>rd_ptr/2,
              wr_data=>pixel_pair,rd_data=>pair_read);
  raw_read<=pair_read(63 downto 32) when read_high='1' else pair_read(31 downto 0);
  pair_control : process(aclk)
  begin
    if rising_edge(aclk) then
      if write_pixel='1' and (wr_ptr mod 2)=0 then low_pixel<=input_payload; end if;
      if read_pixel='1' then
        if (rd_ptr mod 2)=1 then read_high<='1'; else read_high<='0'; end if;
      end if;
    end if;
  end process;

  raster : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn='0' then x<=0; raster_y<=0; wr_ptr<=0; rd_ptr<=0; prior_luma<=0;
      elsif step='1' then
        if write_pixel='1' then
          prior_luma<=in_luma;
          if wr_ptr=PIXELS_STORED-1 then wr_ptr<=0; else wr_ptr<=wr_ptr+1; end if;
        end if;
        if read_pixel='1' then
          if rd_ptr=PIXELS_STORED-1 then rd_ptr<=0; else rd_ptr<=rd_ptr+1; end if;
        end if;
        if x=FRAME_WIDTH-1 then
          x<=0;
          if raster_y=FRAME_HEIGHT+LOOKAHEAD-1 then raster_y<=0; wr_ptr<=0; rd_ptr<=0;
          else raster_y<=raster_y+1; end if;
        else x<=x+1; end if;
      end if;
    end if;
  end process;
  contexts : for i in 0 to 2 generate
    grid : entity work.portrait_tile_context
      generic map (FRAME_WIDTH=>FRAME_WIDTH,FRAME_HEIGHT=>FRAME_HEIGHT,LOOKAHEAD=>LOOKAHEAD,LOG_TILE=>LOG_TILES(i))
      port map (clk=>aclk,resetn=>aresetn,advance=>advance,write_pixel=>write_pixel,read_pixel=>read_pixel,
                x=>x,write_y=>write_y,read_y=>read_y,sample_in=>live_planes,smooth=>smooth(i),slope=>slopes(i));
  end generate;

  align_and_grade : process(aclk)
    variable a : coords_t;
    variable original : axes_t;
    variable color : rgb10_t;
  begin
    if rising_edge(aclk) then
      if aresetn='0' then
        valid<=(others=>'0'); result<=(others=>'0'); stream_sof(0)<='0'; stream_eol(0)<='0';
      elsif advance='1' then
        valid<=read_pixel & valid(0 to 12);
        if valid(0)='1' then raw_pipe(1)<=raw_read; end if;
        if valid(1)='1' then raw_pipe(2)<=raw_pipe(1); end if;
        if valid(2)='1' then
          original:=components(unpack_rgb(raw_pipe(2)(29 downto 0)));
          for i in 0 to 2 loop
            a(i):=components((smooth(i)(0),smooth(i)(1),smooth(i)(2)));
            f(12+i)<=smooth(i)(3);
            for j in 0 to 3 loop f(15+4*i+j)<=slopes(i)(j); end loop;
          end loop;
          for j in 0 to 2 loop
            f(j)<=original(j)-a(0)(j); f(3+j)<=a(0)(j);
            f(6+j)<=a(1)(j)-a(0)(j); f(9+j)<=a(2)(j)-a(1)(j);
          end loop;
          base(0)<=(smooth(0)(0),smooth(0)(1),smooth(0)(2)); marks(0)<=raw_pipe(2)(31 downto 30);
        end if;
        for j in 1 to 9 loop
          if valid(j+2)='1' then base(j)<=base(j-1); marks(j)<=marks(j-1); end if;
        end loop;
        if valid(12)='1' then
          for j in 0 to 2 loop color(j):=saturate(base(9)(j)+correction(j),0,1023); end loop;
          result<=pack_rgb(color); stream_sof(0)<=marks(9)(1); stream_eol(0)<=marks(9)(0);
        end if;
      end if;
    end if;
  end process;
  first_layer : entity work.portrait_projection
    generic map (W1,B1,FRACTION1,0,16383) port map (aclk,aresetn,advance,valid(3),f,h1);
  second_layer : entity work.portrait_projection
    generic map (W2,B2,FRACTION2,0,16383) port map (aclk,aresetn,advance,valid(6),h1,h2);
  output_layer : entity work.portrait_projection
    generic map (W3,B3,FRACTION3,-2048,2047) port map (aclk,aresetn,advance,valid(9),h2,correction);
end architecture;
