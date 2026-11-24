library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.portrait_types.all;

-- Nine native RGB10 taps with replicated borders. Neighbors with similar
-- luminance and color contribute more strongly to the center pixel.
entity portrait_range_smooth is
  generic (FRAME_WIDTH, FRAME_HEIGHT, SPACING, THRESHOLD : positive);
  port (aclk, aresetn : in std_logic;
        s_data : in std_logic_vector(29 downto 0);
        s_valid : in std_logic; s_ready : out std_logic; s_sof, s_eol : in std_logic;
        m_data : out std_logic_vector(29 downto 0);
        m_valid : out std_logic; m_ready : in std_logic; m_sof, m_eol : out std_logic);
end entity;
architecture rtl of portrait_range_smooth is
  constant ROWS_BACK : positive := 2*SPACING;
  constant HISTORY_BITS : positive := ROWS_BACK*30;
  subtype pixel_t is std_logic_vector(29 downto 0);
  subtype pixel_number_t is integer range 0 to 2**30-1;
  type taps_t is array (0 to 2,0 to ROWS_BACK) of pixel_number_t;
  type deltas_t is array (0 to 7,0 to 2) of integer range -1023 to 1023;
  type distances_t is array (0 to 7) of integer range 0 to 1023;
  type terms_t is array (natural range <>,natural range <>) of integer range -131072 to 131071;
  type centers_t is array (0 to 3) of rgb10_t;
  signal x,xq : natural range 0 to FRAME_WIDTH+SPACING-1 := 0;
  signal y,yq : natural range 0 to FRAME_HEIGHT+SPACING-1 := 0;
  signal real_pixel, issue, move_window, move_filter, pending, w_valid, w_sof, w_eol : std_logic := '0';
  signal row_read, row_write : std_logic;
  signal raddr,waddr : natural range 0 to FRAME_WIDTH-1;
  signal history, updated : std_logic_vector(HISTORY_BITS-1 downto 0);
  signal input_q, current_pixel : pixel_t;
  signal taps : taps_t;
  signal v,sof,eol : std_logic_vector(0 to 4) := (others=>'0');
  signal delta : deltas_t;
  signal distance : distances_t;
  signal product : terms_t(0 to 7,0 to 2);
  signal pair_sum : terms_t(0 to 3,0 to 2);
  signal half_sum : terms_t(0 to 1,0 to 2);
  signal center : centers_t;

  function magnitude(n : integer) return natural is
  begin if n<0 then return -n; end if; return n; end;
  function max_nat(a,b : natural) return natural is
  begin if a>b then return a; end if; return b; end;
  function rgb(p : pixel_number_t) return rgb10_t is
  begin return (p/1048576,(p/1024) mod 1024,p mod 1024); end;
begin
  real_pixel<='1' when x<FRAME_WIDTH and y<FRAME_HEIGHT else '0';
  move_filter<=not v(4) or m_ready;
  move_window<=not w_valid or move_filter;
  s_ready<=aresetn and move_window and real_pixel;
  issue<=s_valid or not real_pixel;
  m_valid<=v(4); m_sof<=sof(4); m_eol<=eol(4);
  row_read<=aresetn and move_window and issue when x<FRAME_WIDTH else '0';
  row_write<=aresetn and move_window and pending when xq<FRAME_WIDTH else '0';
  raddr<=x when x<FRAME_WIDTH else 0; waddr<=xq when xq<FRAME_WIDTH else 0;
  current_pixel<=input_q when yq<FRAME_HEIGHT else history(29 downto 0);
  updated(29 downto 0)<=current_pixel;
  retain_rows : for i in 1 to ROWS_BACK-1 generate
    updated(30*i+29 downto 30*i)<=current_pixel when yq=0 else history(30*i-1 downto 30*i-30);
  end generate;
  -- Two 30-bit pixels fit a 72-bit physical memory word. Writeback occurs
  -- one clock after the read. Right-border steps separate reuse at width=1.
  line_banks : for i in 0 to SPACING-1 generate
    line_ram : entity work.portrait_sdp_ram
      generic map (WORD_BITS=>60,DEPTH=>FRAME_WIDTH)
      port map (clk=>aclk,wr_en=>row_write,rd_en=>row_read,wr_addr=>waddr,rd_addr=>raddr,
                wr_data=>updated(60*i+59 downto 60*i),rd_data=>history(60*i+59 downto 60*i));
  end generate;

  raster : process(aclk)
    variable sample : pixel_number_t;
  begin
    if rising_edge(aclk) then
      if aresetn='0' then x<=0; y<=0; pending<='0'; w_valid<='0'; w_sof<='0'; w_eol<='0';
      elsif move_window='1' then
        w_valid<='0'; w_sof<='0'; w_eol<='0';
        if pending='1' then
          for r in 0 to 2 loop
            if xq>=FRAME_WIDTH then sample:=taps(r,0);
            elsif r=2 or yq=0 then sample:=to_integer(unsigned(current_pixel));
            else sample:=to_integer(unsigned(history((2-r)*SPACING*30-1 downto ((2-r)*SPACING-1)*30))); end if;
            taps(r,0)<=sample;
            for k in 1 to ROWS_BACK loop
              if xq=0 then taps(r,k)<=sample; else taps(r,k)<=taps(r,k-1); end if;
            end loop;
          end loop;
          if xq>=SPACING and yq>=SPACING then
            w_valid<='1';
            if xq=SPACING and yq=SPACING then w_sof<='1'; end if;
            if xq=FRAME_WIDTH+SPACING-1 then w_eol<='1'; end if;
          end if;
        end if;
        pending<=issue;
        if issue='1' then
          xq<=x; yq<=y; input_q<=s_data;
          -- synthesis translate_off
          if real_pixel='1' then
            assert (s_sof='1')=(x=0 and y=0) report "Smooth input SOF at wrong pixel" severity failure;
            assert (s_eol='1')=(x=FRAME_WIDTH-1) report "Smooth input EOL at wrong pixel" severity failure;
          end if;
          -- synthesis translate_on
          if x=FRAME_WIDTH+SPACING-1 then
            x<=0;
            if y=FRAME_HEIGHT+SPACING-1 then y<=0; else y<=y+1; end if;
          else x<=x+1; end if;
        end if;
      end if;
    end if;
  end process;
  filter_pipeline : process(aclk)
    variable c,p : rgb10_t;
    variable yc,yp : axes_t;
    variable n,spread,weight : natural;
    variable d,total : integer;
  begin
    if rising_edge(aclk) then
      if aresetn='0' then v<=(others=>'0'); sof<=(others=>'0'); eol<=(others=>'0'); m_data<=(others=>'0');
      elsif move_filter='1' then
        v<=w_valid & v(0 to 3); sof<=w_sof & sof(0 to 3); eol<=w_eol & eol(0 to 3);
        if w_valid='1' then
          c:=rgb(taps(1,SPACING)); yc:=components(c); center(0)<=c; n:=0;
          for row in 0 to 2 loop
            for col in 0 to 2 loop
              if row/=1 or col/=1 then
                p:=rgb(taps(row,(2-col)*SPACING)); yp:=components(p); spread:=0;
                for ch in 0 to 2 loop d:=p(ch)-c(ch); delta(n,ch)<=d; spread:=max_nat(spread,magnitude(d)); end loop;
                distance(n)<=max_nat(magnitude(yp(0)-yc(0)),(spread+1)/2); n:=n+1;
              end if;
            end loop;
          end loop;
        end if;
        if v(0)='1' then
          center(1)<=center(0);
          for i in 0 to 7 loop
            weight:=0;
            if distance(i)<THRESHOLD then weight:=min_nat(16,(THRESHOLD-distance(i)+3)/4); end if;
            for ch in 0 to 2 loop product(i,ch)<=delta(i,ch)*integer(weight); end loop;
          end loop;
        end if;
        if v(1)='1' then
          center(2)<=center(1);
          for i in 0 to 3 loop
            for ch in 0 to 2 loop pair_sum(i,ch)<=product(2*i,ch)+product(2*i+1,ch); end loop;
          end loop;
        end if;
        if v(2)='1' then
          center(3)<=center(2);
          for i in 0 to 1 loop
            for ch in 0 to 2 loop half_sum(i,ch)<=pair_sum(2*i,ch)+pair_sum(2*i+1,ch); end loop;
          end loop;
        end if;
        if v(3)='1' then
          for ch in 0 to 2 loop
            total:=half_sum(0,ch)+half_sum(1,ch);
            c(ch):=center(3)(ch)+(total+64+131072)/128-1024;
          end loop;
          m_data<=pack_rgb(c);
        end if;
      end if;
    end if;
  end process;
end architecture;
