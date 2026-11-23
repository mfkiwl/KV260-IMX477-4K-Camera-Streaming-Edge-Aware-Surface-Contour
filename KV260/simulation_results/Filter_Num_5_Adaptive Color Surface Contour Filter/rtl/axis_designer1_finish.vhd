library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pic2_types.all;

-- Smooth the eight nearest taps with a colour-distance gate. Use opposing
-- outer taps to steepen transitions across a contour and darken a narrow ridge.
entity axis_designer1_finish is
  generic (G_WIDTH : positive := 2048; G_HEIGHT : positive := 1365);
  port (
    aclk, aresetn : in std_logic;
    s_axis_tdata : in std_logic_vector(23 downto 0);
    s_axis_tvalid, s_axis_tuser, s_axis_tlast : in std_logic;
    s_axis_tready : out std_logic;
    m_axis_tdata : out std_logic_vector(23 downto 0);
    m_axis_tvalid, m_axis_tuser, m_axis_tlast : out std_logic;
    m_axis_tready : in std_logic
  );
end entity;

architecture rtl of axis_designer1_finish is
  type indices_t is array (0 to 7) of natural range 0 to 24;
  -- Ordered left/right, top/bottom, upper-left/lower-right, upper-right/lower-left.
  constant INNER_TAPS : indices_t := (11,13,7,17,6,18,8,16);
  constant OUTER_TAPS : indices_t := (10,14,2,22,0,24,4,20);
  constant RANGE_LIMIT : natural := 18;
  type neighbors_t is array (0 to 7) of rgb_t;
  type levels_t is array (0 to 7) of byte_t;
  type delta_t is array (0 to 7, 0 to 2) of integer range -510 to 510;
  type pairs_t is array (0 to 3, 0 to 2) of integer range -1020 to 1020;
  type partial_t is array (0 to 1, 0 to 2) of integer range -2040 to 2040;
  type rgb_pipe_t is array (0 to 4) of rgb_t;
  type edge_t is record
    contrast : byte_t;
    curvature : integer range -255 to 255;
    darker_room, lighter_room, ridge : byte_t;
  end record;
  type edges_t is array (natural range <>) of edge_t;

  function strongest(a,b : edge_t) return edge_t is
    variable chosen : edge_t;
  begin
    if b.contrast>a.contrast then chosen := b; else chosen := a; end if;
    -- A thin line can be detected by a different orientation than the edge.
    chosen.ridge := largest(a.ridge,b.ridge);
    return chosen;
  end function;
  function tap(data : std_logic_vector(599 downto 0); i : natural) return rgb_t is
  begin
    return unpack(to_integer(unsigned(data(24*i+23 downto 24*i))));
  end function;

  signal win : std_logic_vector(599 downto 0);
  signal wv, ws, wl, advance : std_logic;
  signal v, sof, eol : std_logic_vector(0 to 6) := (others=>'0');
  signal center : rgb_pipe_t;
  signal center_y : byte_t;
  signal inner_rgb : neighbors_t;
  signal outer_y, distance1 : levels_t;
  signal raw_delta, weighted_delta : delta_t;
  signal edge1 : edges_t(0 to 3);
  signal edge2 : edges_t(0 to 1);
  signal edge3 : edge_t;
  signal pairs : pairs_t;
  signal partial : partial_t;
  signal shift4, shift5 : integer range -24 to 16;
  signal surface5 : rgb_t;
begin
  neighborhood : entity work.axis_window5
    generic map (G_WIDTH=>G_WIDTH, G_HEIGHT=>G_HEIGHT, G_SPACING=>3)
    port map (aclk=>aclk, aresetn=>aresetn,
              active_width=>std_logic_vector(to_unsigned(G_WIDTH,16)),
              active_height=>std_logic_vector(to_unsigned(G_HEIGHT,16)),
              s_axis_tdata=>s_axis_tdata, s_axis_tvalid=>s_axis_tvalid,
              s_axis_tready=>s_axis_tready, s_axis_tuser=>s_axis_tuser, s_axis_tlast=>s_axis_tlast,
              m_window_data=>win, m_valid=>wv, m_ready=>advance, m_sof=>ws, m_eol=>wl);
  advance <= not v(6) or m_axis_tready;
  m_axis_tvalid <= v(6); m_axis_tuser <= sof(6); m_axis_tlast <= eol(6);

  finish_pixel : process(aclk)
    variable lo, hi, darken, brighten, ink, value : integer;
    variable pixel : rgb_t;
  begin
    if rising_edge(aclk) then
      if aresetn='0' then
        v <= (others=>'0'); sof <= (others=>'0'); eol <= (others=>'0');
        m_axis_tdata <= (others=>'0');
      elsif advance='1' then
        v <= wv & v(0 to 5);
        sof <= ws & sof(0 to 5);
        eol <= wl & eol(0 to 5);

        if wv='1' then
          pixel := tap(win,12); center(0) <= pixel; center_y <= luma(pixel);
          for i in 0 to 7 loop
            inner_rgb(i) <= tap(win,INNER_TAPS(i));
            outer_y(i) <= luma(tap(win,OUTER_TAPS(i)));
          end loop;
        end if;
        for k in 1 to 4 loop center(k) <= center(k-1); end loop;

        if v(0)='1' then
          for i in 0 to 7 loop
            distance1(i) <= distance(inner_rgb(i),center(0));
            for ch in 0 to 2 loop raw_delta(i,ch) <= inner_rgb(i)(ch)-center(0)(ch); end loop;
          end loop;
          for d in 0 to 3 loop
            lo := smallest(outer_y(2*d),outer_y(2*d+1));
            hi := largest(outer_y(2*d),outer_y(2*d+1));
            edge1(d).contrast <= hi-lo;
            edge1(d).curvature <= center_y-(lo+hi)/2;
            edge1(d).darker_room <= largest(center_y-lo,0);
            edge1(d).lighter_room <= largest(hi-center_y,0);
            edge1(d).ridge <= largest(lo-center_y,0);
          end loop;
        end if;

        if v(1)='1' then
          for i in 0 to 7 loop
            for ch in 0 to 2 loop
              if distance1(i)<=RANGE_LIMIT then weighted_delta(i,ch) <= 2*raw_delta(i,ch);
              elsif distance1(i)<=2*RANGE_LIMIT then weighted_delta(i,ch) <= raw_delta(i,ch);
              else weighted_delta(i,ch) <= 0;
              end if;
            end loop;
          end loop;
          edge2(0) <= strongest(edge1(0),edge1(1));
          edge2(1) <= strongest(edge1(2),edge1(3));
        end if;

        if v(2)='1' then
          edge3 <= strongest(edge2(0),edge2(1));
          for d in 0 to 3 loop
            for ch in 0 to 2 loop
              pairs(d,ch) <= weighted_delta(2*d,ch)+weighted_delta(2*d+1,ch);
            end loop;
          end loop;
        end if;

        if v(3)='1' then
          -- A three-level dead band suppresses texture in flat regions.
          darken := clamp(2*largest(-edge3.curvature-3,0),0,smallest(edge3.darker_room,24));
          brighten := clamp(3*largest(edge3.curvature-3,0)/2,0,smallest(edge3.lighter_room,16));
          ink := clamp(edge3.ridge-8,0,16);
          shift4 <= brighten-largest(ink,darken);
          for ch in 0 to 2 loop
            partial(0,ch) <= pairs(0,ch)+pairs(1,ch);
            partial(1,ch) <= pairs(2,ch)+pairs(3,ch);
          end loop;
        end if;

        if v(4)='1' then
          shift5 <= shift4;
          for ch in 0 to 2 loop
            -- Rejected weight goes to the centre. The numerator is nonnegative.
            surface5(ch) <= (16*center(4)(ch)+partial(0,ch)+partial(1,ch)+8)/16;
          end loop;
        end if;
        if v(5)='1' then
          for ch in 0 to 2 loop
            value := clamp(surface5(ch)+shift5,0,255);
            m_axis_tdata(23-8*ch downto 16-8*ch) <= std_logic_vector(to_unsigned(value,8));
          end loop;
        end if;
      end if;
    end if;
  end process;
end architecture;
