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
  signal tracks1,continued1 : scores_t;
  signal continued2,continued3 : natural range 0 to 65;
  signal unsupported1,unsupported2,unsupported3 : boolean;
  signal strength2 : natural range 0 to 65;
  signal median2,flank_level2,y3 : natural range 0 to 255;
  signal center3,anchor3,flank3 : rgb_t;
  signal info1,info2,info3 : guide_flags_t;
  signal strength3 : natural range 0 to 65;
  signal base4,flank4 : rgb_t;
  signal ink4 : natural range 0 to 63;
  signal flags4 : std_logic_vector(1 downto 0);
  signal lift4 : std_logic_vector(4 downto 0);
  signal mask_sample : std_logic_vector(5 downto 0);
  signal mask_in,mask_out : std_logic_vector(54 downto 0);
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
    generic map (G_WIDTH,G_HEIGHT,3,6,48,MB-24)
    port map (clk,reset_n,line_input,peak_meta(MB-1 downto 24),peak_valid,line_ready,
              line_window,line_meta,line_valid,reconstruct_ready);

  reconstruct_ready<=(not v4) or mask_ready;
  reconstruct : process(clk)
    variable a,b,c,support,track,near_count,far_count,center_y : natural;
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
          center_y:=luma(line_window(48*4+47 downto 48*4+24));
          near_count:=0; far_count:=0;
          for t in 0 to 8 loop
            if t/=4 then
              if luma(line_window(48*t+47 downto 48*t+24))<=center_y+5 then near_count:=near_count+1; end if;
              if luma(line_window(48*(9+t)+47 downto 48*(9+t)+24))<=center_y+7 then far_count:=far_count+1; end if;
            end if;
          end loop;
          unsupported1<=near_count<=2 and far_count<=3;
          for d in 0 to 3 loop
            a:=response(line_window,TAN_A(d),d,48); b:=response(line_window,TAN_B(d),d,48);
            c:=response(line_window,4,d,48);
            support:=hi(lo(c,hi(a,b)),lo(lo(a,b),c+8));
            track:=lo((a+2*c+b+2)/4+2,support+2);
            tracks1(d)<=track;
            a:=response(line_window,9+TAN_A(d),d,48); b:=response(line_window,9+TAN_B(d),d,48);
            continued1(d)<=lo(track,lo(a,b)+8+hi(a,b)/2);
          end loop;
        end if;
        if v1='1' then
          info2<=info1; colors2<=colors1; ys2<=ys1;
          strength2<=hi(hi(tracks1(0),tracks1(1)),hi(tracks1(2),tracks1(3)));
          continued2<=hi(hi(continued1(0),continued1(1)),hi(continued1(2),continued1(3)));
          unsupported2<=unsupported1;
          median2<=median_luma(ys1); flank_level2<=dark_flank_level(ys1);
        end if;
        if v2='1' then
          anchor:=rank_color(colors2,ys2,median2);
          flank3<=rank_color(colors2,ys2,flank_level2); anchor3<=anchor; center3<=colors2(4); y3<=ys2(4);
          unsupported3<=unsupported2 and median2>=ys2(4)+3 and continued2<30;
          continued3<=continued2;
          info3<=info2; strength3<=strength2;
        end if;
        if v3='1' then
          side:=as_nat(info3(30 downto 26)); olive:=as_nat(info3(35 downto 31));
          room:=as_nat(info3(40 downto 36)); lift:=as_nat(info3(45 downto 41));
          w:=surface_weight(center3,anchor3,olive,strength3);
          flank4<=flank3;
          if unsupported3 then
            w:=hi(w,lo(48,24+(luma(anchor3)-y3)/2));
          else w:=3*w;
          end if;
          base4<=blend48(center3,anchor3,w);
          if continued3>=18 then ink4<=ink_amount(strength3,side,olive,room,y3);
          else ink4<=0; end if;
          lift4<=std_logic_vector(to_unsigned(lift,5)); flags4<=info3(25 downto 24);
        end if;
      end if;
    end if;
  end process;

  mask_sample<=std_logic_vector(to_unsigned(ink4,6));
  mask_in<=flags4 & lift4 & flank4 & base4;
  coverage_samples : entity work.axis_stencil
    generic map (G_WIDTH,G_HEIGHT,1,3,6,55)
    port map (clk,reset_n,mask_sample,mask_in,v4,mask_ready,
              neighbors,mask_out,mask_valid,output_advance);
  output_advance<=(not m_valid) or m_ready;
  composite : process(clk)
    variable tight,broad,votes,sample,coverage,pair_strength,core,shoulder : natural;
    variable rgb : rgb_t;
  begin
    if rising_edge(clk) then
      if reset_n='0' then m_valid<='0'; m_word<=0;
      elsif output_advance='1' then
        m_valid<=mask_valid;
        if mask_valid='1' then
          tight:=0; broad:=0; votes:=0;
          for i in 0 to 8 loop
            sample:=response(neighbors,i,0,6);
            tight:=tight+sample;
            if sample>0 then votes:=votes+1; end if;
            broad:=broad+response(neighbors,9+i,0,6);
          end loop;
          tight:=(tight+4)/9; broad:=(broad+4)/9;
          coverage:=0;
          if votes>=3 then
            pair_strength:=0;
            for i in 0 to 3 loop
              pair_strength:=hi(pair_strength,lo(response(neighbors,i,0,6),response(neighbors,8-i,0,6)));
            end loop;
            core:=(lo(response(neighbors,4,0,6),2*tight)+tight+1)/2;
            shoulder:=lo(48,(2*tight+broad+1)/3+lo(broad,pair_strength)/2);
            coverage:=hi(core,shoulder);
          elsif broad>=5 then coverage:=broad/2;
          end if;
          rgb:=apply_ink(mask_out(23 downto 0),mask_out(47 downto 24),coverage,as_nat(mask_out(52 downto 48)));
          m_word<=as_nat(mask_out(54 downto 53) & rgb);
        end if;
      end if;
    end if;
  end process;
end architecture;
