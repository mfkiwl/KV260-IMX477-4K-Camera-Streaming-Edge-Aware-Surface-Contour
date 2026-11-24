-- Directional contour smoothing. A 5-tap binomial average follows the local
-- edge tangent. Similar directions share the result on smooth surfaces.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pic2_types.all;

entity axis_contour_finish is
  generic (G_WIDTH : positive := 2048; G_HEIGHT : positive := 1152;
           G_SPACING : positive := 2; G_DIFF_THRESH : natural := 28);
  port (
    aclk, aresetn : in std_logic;
    active_width, active_height : in std_logic_vector(15 downto 0);
    s_axis_tdata : in std_logic_vector(23 downto 0);
    s_axis_tvalid : in std_logic; s_axis_tready : out std_logic;
    s_axis_tuser, s_axis_tlast : in std_logic;
    m_axis_tdata : out std_logic_vector(23 downto 0);
    m_axis_tvalid : out std_logic; m_axis_tready : in std_logic;
    m_axis_tuser, m_axis_tlast : out std_logic
  );
end entity;

architecture rtl of axis_contour_finish is
  constant STAGES : positive := 6;
  type indices_t is array (0 to 3,0 to 3) of natural range 0 to 24;
  constant TAP : indices_t := ((10,11,13,14),(2,7,17,22),(0,6,18,24),(20,16,8,4));
  type pixels_t is array (0 to 24) of rgb_t;
  type distance_t is array (0 to 24) of byte_t;
  type means_t is array (0 to 3) of rgb_t;
  type costs_t is array (0 to 3) of integer range 0 to 765;
  signal win : std_logic_vector(599 downto 0);
  signal valid, sof, eol, advance : std_logic;
  signal vp, sp, ep : std_logic_vector(1 to STAGES) := (others=>'0');
  signal pixels, originals, midpoints, limited : pixels_t;
  signal d2, d3 : distance_t;
  signal costs4, costs5 : costs_t;
  signal means4, means5 : means_t;
  signal winner : natural range 0 to 3;
begin
  neighborhood : entity work.axis_window5
    generic map (G_WIDTH,G_HEIGHT,G_SPACING)
    port map (aclk,aresetn,active_width,active_height,s_axis_tdata,s_axis_tvalid,s_axis_tready,
              s_axis_tuser,s_axis_tlast,win,valid,advance,sof,eol);
  advance <= (not vp(STAGES)) or m_axis_tready;
  m_axis_tvalid <= vp(STAGES); m_axis_tuser <= sp(STAGES); m_axis_tlast <= ep(STAGES);

  smooth : process(aclk)
    variable p : rgb8_t;
    variable a,b,d,e : natural range 0 to 24;
    variable best : natural range 0 to 3;
    variable total : integer range 0 to 1020;
    variable result_rgb : rgb_t;
  begin
    if rising_edge(aclk) then
      if aresetn='0' then
        vp <= (others=>'0'); sp <= (others=>'0'); ep <= (others=>'0');
        m_axis_tdata <= (others=>'0');
      elsif advance='1' then
        vp<=valid & vp(1 to STAGES-1); sp<=sof & sp(1 to STAGES-1); ep<=eol & ep(1 to STAGES-1);
        if valid='1' then
          for i in 0 to 24 loop
            p:=to_rgb8(win(24*i+23 downto 24*i)); pixels(i)<=(p.r,p.g,p.b);
          end loop;
        end if;
        if vp(1)='1' then
          originals<=pixels;
          for i in 0 to 24 loop
            d2(i)<=distance(pixels(i),pixels(12));
            for ch in 0 to 2 loop midpoints(i)(ch)<=(pixels(i)(ch)+pixels(12)(ch)+1)/2; end loop;
          end loop;
        end if;
        if vp(2)='1' then
          d3<=d2;
          for i in 0 to 24 loop
            if d2(i)>G_DIFF_THRESH then limited(i)<=midpoints(i); else limited(i)<=originals(i); end if;
          end loop;
        end if;
        if vp(3)='1' then
          for i in 0 to 3 loop
            a:=TAP(i,0); b:=TAP(i,1); d:=TAP(i,2); e:=TAP(i,3);
            costs4(i)<=d3(b)+d3(d)+(d3(a)+d3(e))/2;
            for ch in 0 to 2 loop
              means4(i)(ch)<=(limited(a)(ch)+limited(e)(ch)+4*(limited(b)(ch)+limited(d)(ch))+
                              6*limited(12)(ch)+8)/16;
            end loop;
          end loop;
        end if;
        if vp(4)='1' then
          best:=0;
          for i in 1 to 3 loop if costs4(i)<costs4(best) then best:=i; end if; end loop;
          winner<=best; costs5<=costs4; means5<=means4;
        end if;
        if vp(5)='1' then
          for ch in 0 to 2 loop
            total:=0;
            for i in 0 to 3 loop
              if costs5(i)<=costs5(winner)+4 then total:=total+means5(i)(ch);
              else total:=total+means5(winner)(ch); end if;
            end loop;
            result_rgb(ch):=(total+2)/4;
          end loop;
          m_axis_tdata<=std_logic_vector(to_unsigned(pack(result_rgb),24));
        end if;
      end if;
    end if;
  end process;
end architecture;
