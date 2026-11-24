library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.stroke_math_pkg.all;

-- A cross-scale seed must survive suppression across the normal and have
-- spatial support along its own tangent before it can reinforce a contour.
entity portrait_stroke_axis is
  generic (G_WIDTH, G_HEIGHT : positive);
  port (
    clk, reset_n : in std_logic;
    s_word : in natural range 0 to 2**26-1;
    s_guide : in natural range 0 to 2**28-1;
    s_valid : in std_logic;
    s_ready : out std_logic;
    m_word : out natural range 0 to 2**26-1;
    m_valid : out std_logic;
    m_ready : in std_logic
  );
end entity;

architecture rtl of portrait_stroke_axis is
  -- Metadata is center-aligned through each window: source guides and framed RGB.
  constant MB : positive := 46;
  subtype meta_t is std_logic_vector(MB-1 downto 0);
  signal source, seed_meta, stats_meta, packed_meta, normal_meta, peak_meta : meta_t;
  subtype guide_flags_t is std_logic_vector(MB-1 downto 24);
  signal line_meta : guide_flags_t;
  signal src_rgb : rgb_t;
  signal src_luma : std_logic_vector(8 downto 0);
  signal values : std_logic_vector(18*9-1 downto 0);
  signal seed_valid,seed_ready,v_stats,v_packed,normal_valid,normal_ready : std_logic := '0';
  signal peak_valid,peak_ready,line_valid,line_ready : std_logic := '0';
  signal step_fine,step_wide : directions_t;
  signal packed_seeds,peaks : seeds_t;
  signal seed_window : std_logic_vector(18*24-1 downto 0);
  signal line_input : std_logic_vector(47 downto 0);
  signal line_window : std_logic_vector(18*48-1 downto 0);
  signal reconstruct_ready : std_logic;
  signal v1,v2,v3,v4 : std_logic := '0';
  signal colors1,colors2 : rgb9_t;
  signal ys1,ys2 : luma9_t;
  type scores_t is array(0 to 3) of natural range 0 to 65;
  signal tracks1 : scores_t;
  signal strength2 : natural range 0 to 65;
  signal median2,y3 : natural range 0 to 255;
  signal center3,anchor3 : rgb_t;
  signal info1,info2,info3 : guide_flags_t;
  signal strength3 : natural range 0 to 65;
  signal base4 : rgb_t;
  signal ink4 : natural range 0 to 63;
  signal flags4 : std_logic_vector(1 downto 0);
  signal lift4 : std_logic_vector(4 downto 0);
  signal mask_sample : std_logic_vector(5 downto 0);
  signal mask_in,mask_out : std_logic_vector(30 downto 0);
  signal neighbors : std_logic_vector(18*6-1 downto 0);
  signal mask_valid,mask_ready,output_advance : std_logic := '0';

  function response(bus_word : std_logic_vector; index,direction,stride : natural) return natural is
    constant first : natural := stride*index+6*direction;
  begin return as_nat(bus_word(first+5 downto first)); end;
begin
  source<=std_logic_vector(to_unsigned(s_guide mod 2**20,20)) & std_logic_vector(to_unsigned(s_word,26));
  src_rgb<=source(23 downto 0);
  src_luma<=std_logic_vector(to_unsigned(2*luma(src_rgb),9)) when s_valid='1' else (others=>'0');
  seed_samples : entity work.axis_stencil
    generic map (G_WIDTH,G_HEIGHT,3,12,9,MB)
    port map (clk,reset_n,src_luma,source,s_valid,s_ready,values,seed_meta,seed_valid,seed_ready);

  seed_ready<=(not v_packed) or normal_ready;
  seed_pipeline : process(clk)
    variable fine,wide : luma9_t;
  begin
    if rising_edge(clk) then
      if reset_n='0' then v_stats<='0'; v_packed<='0';
      elsif seed_ready='1' then
        v_stats<=seed_valid; v_packed<=v_stats;
        if seed_valid='1' then
          for i in 0 to 8 loop
            fine(i):=as_nat(values(9*i+8 downto 9*i));
            wide(i):=as_nat(values(9*(i+9)+8 downto 9*(i+9)));
          end loop;
          step_fine<=strips(fine); step_wide<=strips(wide); stats_meta<=seed_meta;
        end if;
        if v_stats='1' then
          for i in 0 to 3 loop
            packed_seeds(6*i+5 downto 6*i)<=std_logic_vector(to_unsigned(seed(step_fine(i),step_wide(i)),6));
          end loop;
          packed_meta<=stats_meta;
        end if;
      end if;
    end if;
  end process;

  normal_samples : entity work.axis_stencil
    generic map (G_WIDTH,G_HEIGHT,3,3,24,MB)
    port map (clk,reset_n,packed_seeds,packed_meta,v_packed,normal_ready,
              seed_window,normal_meta,normal_valid,peak_ready);
  peak_ready<=(not peak_valid) or line_ready;
  suppress_normal : process(clk)
    variable a,b,c,peak : natural range 0 to 63;
  begin
    if rising_edge(clk) then
      if reset_n='0' then peak_valid<='0';
      elsif peak_ready='1' then
        peak_valid<=normal_valid;
        if normal_valid='1' then
          for d in 0 to 3 loop
            a:=response(seed_window,NORM_A(d),d,24); b:=response(seed_window,NORM_B(d),d,24);
            c:=response(seed_window,4,d,24);
            peak:=lo(c,hi(0,10+2*(integer(c)-hi(a,b))));
            peaks(6*d+5 downto 6*d)<=std_logic_vector(to_unsigned(peak,6));
          end loop;
          peak_meta<=normal_meta;
        end if;
      end if;
    end if;
  end process;

  line_input<=peak_meta(23 downto 0) & peaks;
  tangent_samples : entity work.axis_stencil
    generic map (G_WIDTH,G_HEIGHT,3,3,48,MB-24)
    port map (clk,reset_n,line_input,peak_meta(MB-1 downto 24),peak_valid,line_ready,
              line_window,line_meta,line_valid,reconstruct_ready);

  reconstruct_ready<=(not v4) or mask_ready;
  reconstruct : process(clk)
    variable a,b,c,support,track : natural;
    variable color,anchor : rgb_t;
    variable olive,side,room,lift,w : natural;
  begin
    if rising_edge(clk) then
      if reset_n='0' then v1<='0'; v2<='0'; v3<='0'; v4<='0';
      elsif reconstruct_ready='1' then
        v1<=line_valid; v2<=v1; v3<=v2; v4<=v3;
        if line_valid='1' then
          info1<=line_meta;
          for i in 0 to 8 loop
            color:=line_window(48*i+47 downto 48*i+24);
            colors1(i)<=color; ys1(i)<=luma(color);
          end loop;
          for d in 0 to 3 loop
            a:=response(line_window,TAN_A(d),d,48); b:=response(line_window,TAN_B(d),d,48);
            c:=response(line_window,4,d,48);
            support:=hi(lo(c,hi(a,b)),lo(lo(a,b),c+8));
            track:=lo((a+2*c+b+2)/4+2,support+2);
            tracks1(d)<=track;
          end loop;
        end if;
        if v1='1' then
          info2<=info1; colors2<=colors1; ys2<=ys1;
          strength2<=hi(hi(tracks1(0),tracks1(1)),hi(tracks1(2),tracks1(3)));
          median2<=median_luma(ys1);
        end if;
        if v2='1' then
          anchor:=rank_color(colors2,ys2,median2);
          anchor3<=anchor; center3<=colors2(4); y3<=ys2(4);
          info3<=info2; strength3<=strength2;
        end if;
        if v3='1' then
          side:=as_nat(info3(30 downto 26)); olive:=as_nat(info3(35 downto 31));
          room:=as_nat(info3(40 downto 36)); lift:=as_nat(info3(45 downto 41));
          w:=surface_weight(center3,anchor3,olive,strength3);
          base4<=paint_surface(center3,anchor3,w);
          ink4<=ink_amount(strength3,side,olive,room,y3);
          lift4<=std_logic_vector(to_unsigned(lift,5)); flags4<=info3(25 downto 24);
        end if;
      end if;
    end if;
  end process;

  mask_sample<=std_logic_vector(to_unsigned(ink4,6));
  mask_in<=flags4 & lift4 & base4;
  coverage_samples : entity work.axis_stencil
    generic map (G_WIDTH,G_HEIGHT,1,1,6,31)
    port map (clk,reset_n,mask_sample,mask_in,v4,mask_ready,
              neighbors,mask_out,mask_valid,output_advance);
  output_advance<=(not m_valid) or m_ready;
  composite : process(clk)
    variable rows : luma9_t;
    variable left,center,right,smooth_ink,coverage : natural;
    variable rgb : rgb_t;
  begin
    if rising_edge(clk) then
      if reset_n='0' then m_valid<='0'; m_word<=0;
      elsif output_advance='1' then
        m_valid<=mask_valid;
        if mask_valid='1' then
          for r in 0 to 2 loop
            left:=response(neighbors,3*r,0,6); center:=response(neighbors,3*r+1,0,6);
            right:=response(neighbors,3*r+2,0,6);
            rows(r):=(left+2*center+right+2)/4;
          end loop;
          smooth_ink:=(rows(0)+2*rows(1)+rows(2)+2)/4;
          coverage:=(3*response(neighbors,4,0,6)+smooth_ink+2)/4;
          rgb:=apply_ink(mask_out(23 downto 0),coverage,as_nat(mask_out(28 downto 24)));
          m_word<=as_nat(mask_out(30 downto 29) & rgb);
        end if;
      end if;
    end if;
  end process;
end architecture;
