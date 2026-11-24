library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Dense minimum-variance quadrant filter. Each pixel generates one completed
-- square statistic, reused by four neighboring output positions.
entity portrait_sector is
  generic (G_WIDTH, G_HEIGHT : positive; G_RADIUS : positive range 1 to 7 := 4);
  port (
    aclk, aresetn : in std_logic;
    s_word : in natural range 0 to 2**26-1;
    s_ridge : in natural range 0 to 2**28-1;
    s_valid : in std_logic; s_ready : out std_logic;
    m_word : out natural range 0 to 2**26-1;
    m_ridge : out natural range 0 to 2**28-1;
    m_valid : out std_logic; m_ready : in std_logic
  );
end entity;

architecture rtl of portrait_sector is
  constant R : positive := G_RADIUS;
  constant SIDE : positive := R+1;
  constant N : positive := SIDE*SIDE;
  constant TOLERANCE : natural := 4*N*N;
  constant INF : natural := 500000000;
  subtype rgb_t is natural range 0 to 2**24-1;
  subtype meta_t is std_logic_vector(53 downto 0);
  -- Four 12-bit horizontal channel sums (R,G,B,Y), then a 19-bit sum of Y squared.
  subtype horizontal_t is std_logic_vector(66 downto 0);
  subtype box_t is std_logic_vector(51 downto 0); -- 28-bit variance numerator, RGB888 mean
  type sums_t is array (0 to 4) of natural range 0 to 64*65025;
  type boxes_t is array (0 to 3) of box_t;
  type costs_t is array (0 to 3) of natural range 0 to INF;
  type samples_t is array (natural range <>) of horizontal_t;
  type row_boxes_t is array (natural range <>) of box_t;

  function horizontal(v : sums_t) return horizontal_t is
    variable q : horizontal_t;
  begin
    for i in 0 to 3 loop q(12*i+11 downto 12*i):=std_logic_vector(to_unsigned(v(i),12)); end loop;
    q(66 downto 48):=std_logic_vector(to_unsigned(v(4),19));
    return q;
  end;

  function unpack(q : horizontal_t) return sums_t is
    variable v : sums_t;
  begin
    for i in 0 to 3 loop v(i):=to_integer(unsigned(q(12*i+11 downto 12*i))); end loop;
    v(4):=to_integer(unsigned(q(66 downto 48))); return v;
  end;

  function raw_planes(p : rgb_t) return sums_t is
    variable v : sums_t;
  begin
    v(0):=p/65536; v(1):=p/256 mod 256; v(2):=p mod 256;
    v(3):=(v(0)+2*v(1)+v(2)+2)/4; v(4):=v(3)*v(3); return v;
  end;

  function make_box(v : sums_t) return box_t is
    variable q : box_t; variable cost : natural;
  begin
    cost:=N*v(4)-v(3)*v(3);
    q(51 downto 24):=std_logic_vector(to_unsigned(cost,28));
    for i in 0 to 2 loop
      q(23-8*i downto 16-8*i):=std_logic_vector(to_unsigned((v(i)+N/2)/N,8));
    end loop;
    return q;
  end;

  function box_cost(q : box_t) return natural is
  begin return to_integer(unsigned(q(51 downto 24))); end;
  function luma(v : std_logic_vector(23 downto 0)) return natural is
  begin
    return (to_integer(unsigned(v(23 downto 16))) + 2*to_integer(unsigned(v(15 downto 8))) +
            to_integer(unsigned(v(7 downto 0))) + 2)/4;
  end function;

  -- Penalize quadrant colors on the wrong side of a measured contour.
  -- The base cost is N squared times variance, so use the same scale here.
  function guided_cost(box_value : box_t; guide : integer; strength : natural) return natural is
    variable difference : integer range -267 to 267;
    variable deviation, penalty : natural;
  begin
    difference := guide-integer(luma(box_value(23 downto 0)));
    if difference < 0 then difference := -difference; end if;
    if difference <= 1 or strength < 8 then
      return box_cost(box_value);
    end if;
    deviation := difference-1;
    if strength >= 24 then penalty := 16*deviation;
    else penalty := 8*deviation;
    end if;
    return box_cost(box_value) + N*N*penalty;
  end function;
begin
  small : if G_WIDTH<=R or G_HEIGHT<=R generate
    m_word<=s_word; m_ridge<=s_ridge; m_valid<=s_valid; s_ready<=m_ready;
  end generate;

  filter_pixels : if G_WIDTH>R and G_HEIGHT>R generate
    constant PITCH : positive := G_WIDTH+R;
    constant ROW_LAG : positive := R*PITCH;
    constant CENTER_LAG : positive := ROW_LAG+R;
    type line_t is array(0 to PITCH-1) of std_logic_vector(67*R-1 downto 0);
    type box_ram_t is array(0 to ROW_LAG-1) of box_t;
    type center_ram_t is array(0 to CENTER_LAG-1) of meta_t;
    signal lines : line_t;
    signal box_ram : box_ram_t;
    signal center_ram : center_ram_t;
    signal x,x0,x1,x2 : natural range 0 to PITCH-1 := 0;
    signal y,y0,y1,y2 : natural range 0 to G_HEIGHT+R-1 := 0;
    signal center_addr : natural range 0 to CENTER_LAG-1 := 0;
    signal box_addr : natural range 0 to ROW_LAG-1 := 0;
    signal advance,active,step : std_logic;
    signal v0,v1,v2,v3,v4 : std_logic := '0';
    signal taps : samples_t(0 to R-1);
    signal hsum0 : horizontal_t;
    signal rows0 : std_logic_vector(67*R-1 downto 0);
    signal total1 : sums_t;
    signal center0,center1,center2,center3 : meta_t;
    signal upper2,lower2 : box_t;
    signal upper_taps,lower_taps : row_boxes_t(0 to R-1);
    signal quads3 : boxes_t;
    signal eligible3 : std_logic_vector(0 to 3);
    signal costs3 : costs_t;
    signal best3 : natural range 0 to INF;
  begin
    advance<=not v4 or m_ready;
    active<='1' when x<G_WIDTH and y<G_HEIGHT else '0';
    s_ready<=advance and active and aresetn;
    step<=advance and aresetn and ((not active) or s_valid);
    m_valid<=v4;

    -- Delay the original center word and its contour magnitudes in one RAM.
    -- Each square and each memory pointer advances only on its own valid token.
    process(aclk)
      variable s,t,p : sums_t;
      variable updated_rows : std_logic_vector(67*R-1 downto 0);
      variable corners : boxes_t;
      variable good : std_logic_vector(0 to 3);
      variable minimum_cost : natural range 0 to INF;
      variable costs : costs_t;
      variable dark, light, strength : natural range 0 to 255;
      variable phase : integer range -64 to 64;
      variable guide : integer range -12 to 267;
      variable number : natural range 0 to 4;
      variable v : natural range 0 to 1020;
      variable color : natural range 0 to 2**24-1;
      variable cur : box_t;
    begin
      if rising_edge(aclk) then
        if aresetn='0' then
          x<=0; y<=0; center_addr<=0; box_addr<=0;
          v0<='0'; v1<='0'; v2<='0'; v3<='0'; v4<='0';
          m_word<=0; m_ridge<=0;
        elsif advance='1' then
          v0<=step; v1<=v0; v2<=v1; v3<='0'; v4<=v3;
          if step='1' then
            x0<=x; y0<=y;
            if x=PITCH-1 then
              x<=0; if y=G_HEIGHT+R-1 then y<=0; else y<=y+1; end if;
            else x<=x+1; end if;
            center0<=center_ram(center_addr);
            -- Padding centers are never emitted. One unconditionally addressed
            -- write port allows read-before-write inference of this delay RAM.
            center_ram(center_addr)<=std_logic_vector(to_unsigned(s_ridge,28)) & std_logic_vector(to_unsigned(s_word,26));
            if active='1' then p:=raw_planes(s_word mod 2**24); else p:=(others=>0); end if;
            if center_addr=CENTER_LAG-1 then center_addr<=0; else center_addr<=center_addr+1; end if;
            s:=p;
            for j in 0 to R-1 loop
              if x>j then
                t:=unpack(taps(j));
                for k in s'range loop s(k):=s(k)+t(k); end loop;
              end if;
            end loop;
            for j in 1 to R-1 loop taps(j)<=taps(j-1); end loop;
            taps(0)<=horizontal(p); hsum0<=horizontal(s);
            rows0<=lines(x);
          end if;
          if v0='1' then
            x1<=x0; y1<=y0; center1<=center0;
            s:=unpack(hsum0);
            updated_rows(66 downto 0):=hsum0;
            for j in 0 to R-1 loop
              if y0>j then
                t:=unpack(rows0((j+1)*67-1 downto j*67));
                for k in s'range loop s(k):=s(k)+t(k); end loop;
              end if;
            end loop;
            for j in 1 to R-1 loop
              updated_rows((j+1)*67-1 downto j*67):=rows0(j*67-1 downto (j-1)*67);
            end loop;
            lines(x0)<=updated_rows; total1<=s;
          end if;
          if v1='1' then
            x2<=x1; y2<=y1; center2<=center1;
            -- Incomplete squares are ineligible. The zero value also prevents
            -- uninitialized line RAM from reaching the variance calculation.
            if x1>=R and y1>=R then cur:=make_box(total1); else cur:=(others=>'0'); end if;
            upper2<=box_ram(box_addr); lower2<=cur; box_ram(box_addr)<=cur;
            if box_addr=ROW_LAG-1 then box_addr<=0; else box_addr<=box_addr+1; end if;
          end if;
          if v2='1' then
            for j in 1 to R-1 loop
              upper_taps(j)<=upper_taps(j-1); lower_taps(j)<=lower_taps(j-1);
            end loop;
            upper_taps(0)<=upper2; lower_taps(0)<=lower2;
            if x2>=R and y2>=R then
              v3<='1'; center3<=center2;
              corners:=(upper_taps(R-1),upper2,lower_taps(R-1),lower2);
              good:=(others=>'0');
              if x2>=2*R and y2>=2*R then good(0):='1'; end if;
              if x2<G_WIDTH and y2>=2*R then good(1):='1'; end if;
              if x2>=2*R and y2<G_HEIGHT then good(2):='1'; end if;
              if x2<G_WIDTH and y2<G_HEIGHT then good(3):='1'; end if;
              dark:=to_integer(unsigned(center2(41 downto 34)));
              light:=to_integer(unsigned(center2(33 downto 26)));
              strength:=dark;
              if light>dark then strength:=light; end if;
              -- Unsigned offset implements floor division for a signed Q2 phase.
              phase:=(light-dark+2+1024)/4-256;
              if phase < -12 then phase:=-12;
              elsif phase > 12 then phase:=12;
              end if;
              guide:=integer(luma(center2(23 downto 0)))+phase;
              minimum_cost:=INF;
              for i in 0 to 3 loop
                costs(i):=INF;
                if good(i)='1' then
                  costs(i):=guided_cost(corners(i),guide,strength);
                  if costs(i)<minimum_cost then minimum_cost:=costs(i); end if;
                end if;
              end loop;
              costs3<=costs;
              quads3<=corners; eligible3<=good; best3<=minimum_cost;
            end if;
          end if;
          if v3='1' then
            color:=to_integer(unsigned(center3(23 downto 0)));
            good:=(others=>'0'); number:=0;
            for i in 0 to 3 loop
              if eligible3(i)='1' then
                if costs3(i)<=best3+TOLERANCE then good(i):='1'; number:=number+1; end if;
              end if;
            end loop;
            if number>0 then
              color:=0;
              for k in 0 to 2 loop
                v:=0;
                for i in 0 to 3 loop
                  if good(i)='1' then v:=v+to_integer(unsigned(quads3(i)(23-8*k downto 16-8*k))); end if;
                end loop;
                case number is
                  when 1 => color:=256*color+v;
                  when 2 => color:=256*color+(v+1)/2;
                  when 3 => color:=256*color+(v+1)/3;
                  when others => color:=256*color+(v+2)/4;
                end case;
              end loop;
            end if;
            m_word<=to_integer(unsigned(center3(25 downto 24)))*2**24+color;
            m_ridge<=to_integer(unsigned(center3(53 downto 26)));
          end if;
        end if;
      end if;
    end process;
  end generate;
end architecture;
