library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.designer_geometry.all;
use work.pic2_types.all;

-- RGB888 AXI4-Stream. By default the style filter preserves the input raster.
-- The optional portrait geometry is calibrated for a 2048 by 1152 camera input.
entity designer_filter_axis is
  generic (
    G_MEDIUM_STEP : positive := 3; G_COARSE_STEP : positive := 6;
    G_CONTOUR_STEP : positive := 6; G_CHROMA_Q8 : natural range 256 to 384 := 384;
    G_LARGE_VIEW : boolean := true; G_DESIGNER1 : boolean := true;
    G_PORTRAIT_FRAMING : boolean := false;
    G_WIDTH : positive := INPUT_WIDTH; G_HEIGHT : positive := INPUT_HEIGHT;
    G_COLOR_PROFILE : string := "auto"  -- auto, source, designer1
  );
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

architecture rtl of designer_filter_axis is
  constant W_OUT : positive := stream_width(G_WIDTH,G_PORTRAIT_FRAMING,G_LARGE_VIEW);
  constant H_OUT : positive := stream_height(G_HEIGHT,G_PORTRAIT_FRAMING,G_LARGE_VIEW);
  signal filtered, framed : std_logic_vector(23 downto 0);
  signal fv, fr, fs, fl, pv, pr, ps, pl : std_logic;
  signal input_open, camera_ready, raw_room : std_logic;
  signal profile_ready, use_designer, output_open, output_designer : std_logic;
  signal finished : std_logic_vector(23 downto 0);
  signal finish_valid, finish_ready, finish_sof, finish_eol : std_logic;
  constant AUTO_PROFILE : boolean := G_COLOR_PROFILE="auto" and
    G_DESIGNER1 and G_LARGE_VIEW and not G_PORTRAIT_FRAMING;
  constant MATCH_SOURCE : boolean := G_DESIGNER1 and G_LARGE_VIEW and
    not G_PORTRAIT_FRAMING and G_COLOR_PROFILE/="designer1";
begin
  assert G_COLOR_PROFILE="auto" or G_COLOR_PROFILE="source" or G_COLOR_PROFILE="designer1"
    report "G_COLOR_PROFILE must be auto, source or designer1" severity failure;
  assert not G_PORTRAIT_FRAMING or (G_WIDTH=INPUT_WIDTH and G_HEIGHT=INPUT_HEIGHT)
    report "Portrait framing requires 2048 by 1152 input" severity failure;

  s_axis_tready <= aresetn and camera_ready and input_open and raw_room;

  -- The native filter already brightens luma, limits chroma gain and smooths
  -- edges. Apply its portrait-specific second grade only within its calibration.
  fixed_profile : if not AUTO_PROFILE generate
    input_open <= '1';
    profile_ready <= '1';
    use_designer <= '0' when G_COLOR_PROFILE="source" else '1';
    output_open <= '1';
    output_designer <= use_designer;
  end generate;

  meter : if AUTO_PROFILE generate
    -- The cascaded spatial windows take more than eight input rows to emit
    -- their first pixel. Meter accepted camera samples during that lookahead.
    constant N : positive := G_WIDTH * smallest(8,G_HEIGHT);
    signal count : natural range 0 to N := 0;
    signal sum_y, sum_span : natural range 0 to 255*N := 0;
    signal sum_gb : integer range -255*N to 255*N := 0;
    signal pending, decision, active_grade, active_output : std_logic := '0';
  begin
    -- One decision follows the raw, graded and finished frame starts. A new
    -- input SOF cannot overwrite it until the finish stage consumes its SOF.
    input_open <= not (s_axis_tuser and pending);
    profile_ready <= not ps or pending;
    decision <= '1' when sum_y <= 80*N and sum_gb >= 4*N and sum_span <= 32*N else '0';
    use_designer <= decision when ps='1' else active_grade;
    output_open <= not finish_sof or pending;
    output_designer <= decision when finish_sof='1' else active_output;

    measure : process(aclk)
      variable rgb : rgb_t;
      variable span, gb : integer;
    begin
      if rising_edge(aclk) then
        if aresetn='0' then
          count <= 0; pending <= '0'; active_grade <= '0'; active_output <= '0';
        else
          if pv='1' and pr='1' and ps='1' then
            active_grade <= decision;
            -- synthesis translate_off
            if decision='1' then report "Frame color profile: designer1";
            else report "Frame color profile: source"; end if;
            -- synthesis translate_on
          end if;
          if finish_valid='1' and finish_ready='1' and finish_sof='1' then
            active_output <= decision;
            pending <= '0';
          end if;
          if s_axis_tvalid='1' and s_axis_tready='1' and
             (s_axis_tuser='1' or count<N) then
            rgb := unpack(to_integer(unsigned(s_axis_tdata)));
            gb := rgb(1)-rgb(2);
            span := largest(rgb(0),largest(rgb(1),rgb(2))) -
                    smallest(rgb(0),smallest(rgb(1),rgb(2)));
            if s_axis_tuser='1' then
              count <= 1;
              sum_y <= luma(rgb); sum_gb <= gb; sum_span <= span;
              if N=1 then pending <= '1'; end if;
            else
              count <= count+1;
              sum_y <= sum_y+luma(rgb); sum_gb <= sum_gb+gb; sum_span <= sum_span+span;
              if count=N-1 then pending <= '1'; end if;
            end if;
          end if;
        end if;
      end if;
    end process;
  end generate;

  camera_filter : entity work.pic2_filter_axis
    generic map (G_WIDTH=>G_WIDTH, G_HEIGHT=>G_HEIGHT, G_MEDIUM_STEP=>G_MEDIUM_STEP,
                 G_COARSE_STEP=>G_COARSE_STEP, G_CONTOUR_STEP=>G_CONTOUR_STEP, G_CHROMA_Q8=>G_CHROMA_Q8)
    port map (aclk=>aclk, aresetn=>aresetn,
              active_width=>std_logic_vector(to_unsigned(G_WIDTH,16)),
              active_height=>std_logic_vector(to_unsigned(G_HEIGHT,16)),
              s_axis_tdata=>s_axis_tdata, s_axis_tvalid=>s_axis_tvalid and input_open and raw_room, s_axis_tready=>camera_ready,
              s_axis_tuser=>s_axis_tuser, s_axis_tlast=>s_axis_tlast,
              m_axis_tdata=>filtered, m_axis_tvalid=>fv, m_axis_tready=>fr,
              m_axis_tuser=>fs, m_axis_tlast=>fl);

  frame_view : entity work.axis_designer_view
    generic map (G_LARGE_VIEW=>G_LARGE_VIEW, G_DESIGNER1=>G_DESIGNER1,
                 G_PORTRAIT_FRAMING=>G_PORTRAIT_FRAMING)
    port map (aclk=>aclk, aresetn=>aresetn,
              s_axis_tdata=>filtered, s_axis_tvalid=>fv, s_axis_tready=>fr, s_axis_tuser=>fs, s_axis_tlast=>fl,
              m_axis_tdata=>framed, m_axis_tvalid=>pv, m_axis_tready=>pr, m_axis_tuser=>ps, m_axis_tlast=>pl);

  designer1 : if G_DESIGNER1 and G_LARGE_VIEW generate
    signal graded : std_logic_vector(23 downto 0);
    signal gv, gr, gs, gl, grade_ready : std_logic;
  begin
    pr <= grade_ready and profile_ready;
    grade : entity work.axis_designer1_grade
      port map (aclk=>aclk, aresetn=>aresetn,
                s_axis_tdata=>framed, s_axis_tvalid=>pv and profile_ready, s_axis_tready=>grade_ready,
                s_axis_tuser=>ps, s_axis_tlast=>pl, s_use_designer=>use_designer,
                m_axis_tdata=>graded, m_axis_tvalid=>gv, m_axis_tready=>gr, m_axis_tuser=>gs, m_axis_tlast=>gl);
    finish : entity work.axis_designer1_finish
      generic map (G_WIDTH=>W_OUT, G_HEIGHT=>H_OUT)
      port map (aclk=>aclk, aresetn=>aresetn,
                s_axis_tdata=>graded, s_axis_tvalid=>gv, s_axis_tready=>gr, s_axis_tuser=>gs, s_axis_tlast=>gl,
                m_axis_tdata=>finished, m_axis_tvalid=>finish_valid, m_axis_tready=>finish_ready,
                m_axis_tuser=>finish_sof, m_axis_tlast=>finish_eol);
  end generate;
  earlier_grade : if not (G_DESIGNER1 and G_LARGE_VIEW) generate
  portrait_grade : entity work.axis_designer_grade
    generic map (G_LARGE_VIEW=>G_LARGE_VIEW)
    port map (aclk=>aclk, aresetn=>aresetn,
              s_axis_tdata=>framed, s_axis_tvalid=>pv, s_axis_tready=>pr, s_axis_tuser=>ps, s_axis_tlast=>pl,
              m_axis_tdata=>finished, m_axis_tvalid=>finish_valid, m_axis_tready=>finish_ready,
              m_axis_tuser=>finish_sof, m_axis_tlast=>finish_eol);
  end generate;

  aligned_chroma : if MATCH_SOURCE generate
    -- Sum of the six window radii in rows and columns. One spare row and 128
    -- beats cover registered stages and skid buffers. Backpressure bounds use.
    constant RADIUS_SUM : positive := 2*(5+G_MEDIUM_STEP+G_COARSE_STEP+G_CONTOUR_STEP);
    constant FIFO_DEPTH : positive := smallest(G_HEIGHT,RADIUS_SUM+1)*G_WIDTH+RADIUS_SUM+128;
    signal chroma_ready : std_logic;
  begin
    finish_ready <= chroma_ready and output_open;
    chroma : entity work.axis_source_chroma
      generic map (G_DEPTH=>FIFO_DEPTH)
      port map (aclk=>aclk, aresetn=>aresetn, raw_rgb=>s_axis_tdata,
                raw_push=>s_axis_tvalid and s_axis_tready, raw_room=>raw_room,
                s_axis_tdata=>finished, s_axis_tvalid=>finish_valid and output_open, s_axis_tready=>chroma_ready,
                s_axis_tuser=>finish_sof, s_axis_tlast=>finish_eol, s_use_designer=>output_designer,
                m_axis_tdata=>m_axis_tdata, m_axis_tvalid=>m_axis_tvalid, m_axis_tready=>m_axis_tready,
                m_axis_tuser=>m_axis_tuser, m_axis_tlast=>m_axis_tlast);
  end generate;
  direct_output : if not MATCH_SOURCE generate
    raw_room <= '1'; finish_ready <= m_axis_tready;
    m_axis_tvalid <= finish_valid; m_axis_tdata <= finished;
    m_axis_tuser <= finish_sof; m_axis_tlast <= finish_eol;
  end generate;
end architecture;
