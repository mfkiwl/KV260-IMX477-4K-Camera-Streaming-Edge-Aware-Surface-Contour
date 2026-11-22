-- Continuous fixed-point color correction driven by the center, broad surround
-- and fine directional features. The twelve inputs and all coefficients are
-- independent of raster position. One output beat per enabled pipeline clock.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pic2_types.all;
use work.pic2_grade_coeffs.all;

entity axis_tone_contour is
  generic (G_WIDTH : positive := 2048; G_HEIGHT : positive := 1152;
           G_SPACING : positive := 4; G_CHROMA_Q8 : integer range 256 to 384 := 384;
           G_LEGACY_PIC2 : boolean := false);
  port (
    aclk, aresetn : in std_logic;
    active_width, active_height : in std_logic_vector(15 downto 0);
    s_axis_tdata : in std_logic_vector(23 downto 0);
    s_context : in std_logic_vector(31 downto 0); -- mean R,G,B, then mean |Y-Yc|
    s_axis_tvalid : in std_logic; s_axis_tready : out std_logic;
    s_axis_tuser, s_axis_tlast : in std_logic;
    m_axis_tdata : out std_logic_vector(23 downto 0);
    m_axis_tvalid : out std_logic; m_axis_tready : in std_logic;
    m_axis_tuser, m_axis_tlast : out std_logic
  );
end entity;

architecture rtl of axis_tone_contour is
  constant STAGES : positive := 13;
  constant SATURATION : integer := (G_CHROMA_Q8*256+192)/384;
  constant FIFO_DEPTH : positive := 2*G_SPACING*(G_WIDTH+1)+4;
  subtype context_t is std_logic_vector(31 downto 0);
  type context_ram_t is array (0 to FIFO_DEPTH-1) of context_t;
  signal context_ram : context_ram_t;
  attribute ram_style : string;
  attribute ram_style of context_ram : signal is "block";
  signal head, tail, read_address : natural range 0 to FIFO_DEPTH-1 := 0;
  signal used : natural range 0 to FIFO_DEPTH := 0;
  signal space, push, pop, in_ready, in_valid : std_logic;
  signal front : context_t;
  function successor(p : natural) return natural is
  begin if p=FIFO_DEPTH-1 then return 0; end if; return p+1; end;

  signal win : std_logic_vector(599 downto 0);
  signal win_valid, win_sof, win_eol, advance : std_logic;
  signal vp, sp, ep : std_logic_vector(1 to STAGES) := (others=>'0');
  type centers_t is array (1 to 11) of rgb8_t;
  signal centers : centers_t;
  signal ys : tap_luma_array_t;
  type byte4_t is array (0 to 3) of byte_t;
  type byte5_t is array (0 to 4) of byte_t;
  signal opposing_min, opposing_max : byte4_t;
  signal row_min, row_max : byte5_t;
  signal inner_a, inner_b, outer_a, outer_b : integer range 0 to 1020;
  signal yc2 : byte_t;
  signal ctx1, ctx2 : context_t;

  signal features : grade_features_t;
  signal legacy_data : std_logic_vector(23 downto 0);
  type products_t is array (0 to N_FORMS-1,0 to N_FEATURES-1) of integer range -2097152 to 2097151;
  type sums_t is array (0 to N_FORMS-1,0 to 3) of integer range -8388608 to 8388607;
  type forms_t is array (0 to N_FORMS-1) of integer range -8388608 to 8388607;
  type hidden_t is array (0 to N_HIDDEN-1) of integer range 0 to 2047;
  type head_products_t is array (0 to 2,0 to N_HIDDEN-1) of integer range -1048576 to 1048575;
  type head_groups_t is array (0 to 2,0 to 5) of integer range -4194304 to 4194303;
  type accum3_t is array (0 to 2) of integer range -33554432 to 33554431;
  type strength_t is array (3 to 11) of integer range 0 to 32;
  signal products : products_t;
  signal groups : sums_t;
  signal affine : forms_t;
  signal hidden : hidden_t;
  signal correction7, correction8, correction9, correction10 : accum3_t;
  signal head_products : head_products_t;
  signal head_groups : head_groups_t;
  signal left_sum, right_sum : accum3_t;
  signal strength : strength_t;
  signal graded, blended : rgb_t;
begin
  -- Context is one word per real pixel. Only the center context is needed by
  -- the fine window. A FIFO avoids shifting all 32 bits through 25 spatial taps.
  space <= '1' when used < FIFO_DEPTH else '0';
  in_valid <= s_axis_tvalid and space;
  s_axis_tready <= in_ready and space;
  push <= in_valid and in_ready;
  pop <= win_valid and advance;
  read_address <= successor(head) when pop='1' else head;

  context_queue : process(aclk)
  begin
    if rising_edge(aclk) then
      if push='1' then context_ram(tail) <= s_context; end if;
      if push='1' and tail=read_address then front <= s_context;
      else front <= context_ram(read_address);
      end if;
      if aresetn='0' then
        used <= 0; head <= 0; tail <= 0;
      else
        if push='1' then tail <= successor(tail); end if;
        if pop='1' then head <= successor(head); end if;
        if push='1' and pop='0' then used <= used+1;
        elsif push='0' and pop='1' then used <= used-1;
        end if;
        -- synthesis translate_off
        assert pop='0' or used>0 report "Fine window has no matching context" severity failure;
        -- synthesis translate_on
      end if;
    end if;
  end process;

  neighborhood : entity work.axis_window5
    generic map (G_WIDTH,G_HEIGHT,G_SPACING)
    port map (aclk,aresetn,active_width,active_height,s_axis_tdata,in_valid,in_ready,
              s_axis_tuser,s_axis_tlast,win,win_valid,advance,win_sof,win_eol);
  -- Only the selected grade is elaborated. The first three registers align the
  -- center and neighborhood statistics for both profiles.
  original_grade : if G_LEGACY_PIC2 generate
    advance <= (not vp(STAGES)) or m_axis_tready;
    m_axis_tdata <= legacy_data;
    m_axis_tvalid <= vp(STAGES);
    m_axis_tuser <= sp(STAGES);
    m_axis_tlast <= ep(STAGES);
  end generate;
  full_grade : if not G_LEGACY_PIC2 generate
    grade : entity work.axis_full_grade
      generic map (G_CHROMA_Q8 => G_CHROMA_Q8)
      port map (
        aclk => aclk, aresetn => aresetn,
        s_center => centers(3), s_features => features,
        s_valid => vp(3), s_ready => advance, s_sof => sp(3), s_eol => ep(3),
        m_data => m_axis_tdata, m_valid => m_axis_tvalid, m_ready => m_axis_tready,
        m_sof => m_axis_tuser, m_eol => m_axis_tlast);
  end generate;

  render : process(aclk)
    variable a,b,c,d,e : byte_t;
    variable mn,mx,low_pair,high_pair : byte_t;
    variable u,v,base_y : integer;
    variable mean_color : rgb8_t;
    variable orig, result_rgb : rgb_t;
    variable total : integer;
  begin
    if rising_edge(aclk) then
      if aresetn='0' then
        vp <= (others=>'0'); sp <= (others=>'0'); ep <= (others=>'0');
        legacy_data <= (others=>'0');
      elsif advance='1' then
        vp <= win_valid & vp(1 to STAGES-1);
        sp <= win_sof & sp(1 to STAGES-1);
        ep <= win_eol & ep(1 to STAGES-1);
        centers(2 to 11) <= centers(1 to 10);
        strength(4 to 11) <= strength(3 to 10);
        if win_valid='1' then
          centers(1) <= to_rgb8(win(311 downto 288));
          ctx1 <= front;
          for i in 0 to 24 loop ys(i) <= luma_y(to_rgb8(win(24*i+23 downto 24*i))); end loop;
        end if;
        if vp(1)='1' then
          ctx2 <= ctx1; yc2 <= ys(12);
          inner_a <= ys(6)+ys(7)+ys(8)+ys(11); inner_b <= ys(13)+ys(16)+ys(17)+ys(18);
          outer_a <= ys(0)+ys(2)+ys(4)+ys(10); outer_b <= ys(14)+ys(20)+ys(22)+ys(24);
          opposing_min <= (smallest(ys(0),ys(24)),smallest(ys(2),ys(22)),
                           smallest(ys(4),ys(20)),smallest(ys(10),ys(14)));
          opposing_max <= (largest(ys(0),ys(24)),largest(ys(2),ys(22)),
                           largest(ys(4),ys(20)),largest(ys(10),ys(14)));
          for k in 0 to 4 loop
            a:=ys(5*k); b:=ys(5*k+1); c:=ys(5*k+2); d:=ys(5*k+3); e:=ys(5*k+4);
            row_min(k)<=smallest(smallest(a,b),smallest(c,smallest(d,e)));
            row_max(k)<=largest(largest(a,b),largest(c,largest(d,e)));
          end loop;
        end if;
        if vp(2)='1' then
          u:=centers(2).r-centers(2).g; v:=centers(2).g-centers(2).b;
          mean_color:=to_rgb8(ctx2(31 downto 8)); base_y:=luma_y(mean_color);
          mn:=row_min(0); mx:=row_max(0);
          for k in 1 to 4 loop mn:=smallest(mn,row_min(k)); mx:=largest(mx,row_max(k)); end loop;
          low_pair:=largest(largest(opposing_min(0),opposing_min(1)),largest(opposing_min(2),opposing_min(3)));
          high_pair:=smallest(smallest(opposing_max(0),opposing_max(1)),smallest(opposing_max(2),opposing_max(3)));
          -- Y, R-G, G-B, broad luma residual, local contrast, two chroma residuals,
          -- inner luma detail, dark/bright ridge, fine span, outer luma residual.
          features <= (yc2,u,v,yc2-base_y,to_integer(unsigned(ctx2(7 downto 0))),
                       u-(mean_color.r-mean_color.g),v-(mean_color.g-mean_color.b),
                       yc2-(inner_a+inner_b+4)/8,low_pair-yc2,yc2-high_pair,
                       mx-mn,(outer_a+outer_b+4)/8-yc2);
          strength(3) <= clamp(smallest(224-yc2,96-largest(magnitude(u),magnitude(v))),0,32);
        end if;
        -- Original PIC2 portrait response, selected at elaboration.
        if G_LEGACY_PIC2 then
          if vp(3)='1' then
            for j in 0 to N_FORMS-1 loop
              for k in 0 to N_FEATURES-1 loop products(j,k)<=features(k)*INPUT_WEIGHTS(j)(k); end loop;
            end loop;
          end if;
          if vp(4)='1' then
            for j in 0 to N_FORMS-1 loop
              for k in 0 to 3 loop groups(j,k)<=products(j,3*k)+products(j,3*k+1)+products(j,3*k+2); end loop;
            end loop;
          end if;
          if vp(5)='1' then
            for j in 0 to N_FORMS-1 loop
              affine(j)<=(groups(j,0)+groups(j,1))+(groups(j,2)+groups(j,3))+INPUT_BIAS(j);
            end loop;
          end if;
          if vp(6)='1' then
            for j in 0 to N_HIDDEN-1 loop hidden(j)<=clamp((affine(j)+128)/256,0,2047); end loop;
            for ch in 0 to 2 loop correction7(ch)<=affine(N_HIDDEN+ch); end loop;
          end if;
          if vp(7)='1' then
            correction8<=correction7;
            for ch in 0 to 2 loop
              for j in 0 to N_HIDDEN-1 loop head_products(ch,j)<=hidden(j)*OUTPUT_WEIGHTS(ch)(j); end loop;
            end loop;
          end if;
          if vp(8)='1' then
            correction9<=correction8;
            for ch in 0 to 2 loop
              for k in 0 to 5 loop
                head_groups(ch,k)<=(head_products(ch,4*k)+head_products(ch,4*k+1))+
                                   (head_products(ch,4*k+2)+head_products(ch,4*k+3));
              end loop;
            end loop;
          end if;
          if vp(9)='1' then
            correction10<=correction9;
            for ch in 0 to 2 loop
              left_sum(ch)<=head_groups(ch,0)+head_groups(ch,1)+head_groups(ch,2);
              right_sum(ch)<=head_groups(ch,3)+head_groups(ch,4)+head_groups(ch,5);
            end loop;
          end if;
          if vp(10)='1' then
            orig:=(centers(10).r,centers(10).g,centers(10).b);
            for ch in 0 to 2 loop
              total:=256*orig(ch)+correction10(ch)+left_sum(ch)+right_sum(ch);
              graded(ch)<=clamp((total+128)/256,0,255);
            end loop;
          end if;
          if vp(11)='1' then
            orig:=(centers(11).r,centers(11).g,centers(11).b);
            for ch in 0 to 2 loop
              blended(ch)<=((32-strength(11))*orig(ch)+strength(11)*graded(ch)+16)/32;
            end loop;
          end if;
          if vp(12)='1' then
            base_y:=luma(blended);
            for ch in 0 to 2 loop result_rgb(ch):=(SATURATION*blended(ch)+(256-SATURATION)*base_y+128)/256; end loop;
            legacy_data<=std_logic_vector(to_unsigned(pack(result_rgb),24));
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
