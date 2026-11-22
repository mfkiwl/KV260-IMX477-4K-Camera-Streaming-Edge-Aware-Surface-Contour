library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pic2_types.all;
use work.designer_geometry.all;

-- A fine dark-side outline, evaluated on the selected raster. The four immediate
-- neighbours lightly antialias the RGB surface before ink is subtracted.
entity axis_designer_ink is
  generic (G_PROFILE : profile_t := 3; G_WIDTH : positive := INPUT_WIDTH;
           G_HEIGHT : positive := output_height(G_PROFILE));
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

architecture rtl of axis_designer_ink is
  type positions_t is array(natural range <>) of natural;
  constant RING : positions_t(0 to 7) := (2,22,10,14,6,18,8,16);
  constant CROSS : positions_t(0 to 3) := (7,17,11,13);
  type luma_taps_t is array(0 to 7) of byte_t;
  type cross_taps_t is array(0 to 3) of rgb_t;
  signal win : std_logic_vector(599 downto 0);
  signal wvalid, wready, wsof, weol, advance : std_logic;
  signal valid, sof, eol : std_logic_vector(0 to 3) := (others=>'0');
  signal luma0 : luma_taps_t;
  signal near0 : cross_taps_t;
  signal center0, mean1, mean2 : rgb_t;
  signal level0, level1, light1, dark1 : byte_t;
  signal ink2 : natural range 0 to 24;
begin
  window_stage : entity work.axis_window5
    generic map(G_WIDTH=>G_WIDTH,G_HEIGHT=>G_HEIGHT,G_SPACING=>1)
    port map(aclk=>aclk,aresetn=>aresetn,
      active_width=>std_logic_vector(to_unsigned(G_WIDTH,16)),
      active_height=>std_logic_vector(to_unsigned(G_HEIGHT,16)),
      s_axis_tdata=>s_axis_tdata,s_axis_tvalid=>s_axis_tvalid,s_axis_tready=>s_axis_tready,
      s_axis_tuser=>s_axis_tuser,s_axis_tlast=>s_axis_tlast,
      m_window_data=>win,m_valid=>wvalid,m_ready=>wready,m_sof=>wsof,m_eol=>weol);
  advance <= not valid(3) or m_axis_tready;
  wready <= aresetn and advance;
  m_axis_tvalid <= valid(3); m_axis_tuser <= sof(3); m_axis_tlast <= eol(3);

  pipeline : process(aclk)
    variable c : rgb8_t;
    variable lo, hi, index : natural;
  begin
    if rising_edge(aclk) then
      if aresetn='0' then
        valid <= (others=>'0'); sof <= (others=>'0'); eol <= (others=>'0');
        m_axis_tdata <= (others=>'0');
      elsif advance='1' then
        valid <= wvalid & valid(0 to 2);
        sof <= wsof & sof(0 to 2);
        eol <= weol & eol(0 to 2);
        if wvalid='1' then
          c := to_rgb8(win(311 downto 288));
          center0 <= (c.r,c.g,c.b); level0 <= luma_y(c);
          for k in RING'range loop
            index := RING(k);
            luma0(k) <= luma_y(to_rgb8(win(24*index+23 downto 24*index)));
          end loop;
          for k in CROSS'range loop
            index := CROSS(k); c := to_rgb8(win(24*index+23 downto 24*index));
            near0(k) <= (c.r,c.g,c.b);
          end loop;
        end if;
        if valid(0)='1' then
          lo := 255; hi := 0;
          for k in luma0'range loop
            lo := smallest(lo,luma0(k)); hi := largest(hi,luma0(k));
          end loop;
          dark1 <= lo; light1 <= hi; level1 <= level0;
          for ch in 0 to 2 loop
            mean1(ch) <= (4*center0(ch)+(near0(0)(ch)+near0(1)(ch))
                         +(near0(2)(ch)+near0(3)(ch))+4)/8;
          end loop;
        end if;
        if valid(1)='1' then
          ink2 <= smallest(clamp(light1-level1-7,0,48),clamp(light1+dark1-2*level1-2,0,48))/2;
          mean2 <= mean1;
        end if;
        if valid(2)='1' then
          for ch in 0 to 2 loop
            m_axis_tdata(23-ch*8 downto 16-ch*8) <=
              std_logic_vector(to_unsigned(largest(0,mean2(ch)-ink2),8));
          end loop;
        end if;
      end if;
    end if;
  end process;
end architecture;
