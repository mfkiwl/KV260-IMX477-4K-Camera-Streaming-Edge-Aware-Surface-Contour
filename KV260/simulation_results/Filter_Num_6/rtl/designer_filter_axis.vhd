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
    G_WIDTH : positive := INPUT_WIDTH; G_HEIGHT : positive := INPUT_HEIGHT
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
  signal camera_valid, camera_ready, input_enable, grade_enable : std_logic;
  signal neutral_mix : natural range 0 to 32;
begin
  assert not G_PORTRAIT_FRAMING or (G_WIDTH=INPUT_WIDTH and G_HEIGHT=INPUT_HEIGHT)
    report "Portrait framing requires 2048 by 1152 input" severity failure;

  camera_valid <= s_axis_tvalid and input_enable;
  s_axis_tready <= camera_ready and input_enable;

  -- The first eight input lines arrive during the spatial filter's line fill.
  -- Meter accepted camera RGB, before the native filter lifts the shadows.
  aligned_colour : if G_DESIGNER1 and G_LARGE_VIEW and not G_PORTRAIT_FRAMING generate
    constant METER_ROWS : positive := smallest(8,G_HEIGHT);
    constant N : positive := G_WIDTH*METER_ROWS;
    signal rows_done : natural range 0 to METER_ROWS := 0;
    signal luma_sum : natural range 0 to 255*N := 0;
    signal pending : std_logic := '0';
    signal next_mix, current_mix : natural range 0 to 32 := 0;
  begin
    -- One queued result may wait for the corresponding filtered SOF. Older
    -- pixels continue to use their own latched mix until that SOF transfers.
    input_enable <= not (pending and s_axis_tuser and s_axis_tvalid);
    grade_enable <= not (pv and ps) or pending;
    neutral_mix <= next_mix when ps='1' else current_mix;

    meter : process(aclk)
      variable row : natural range 0 to METER_ROWS;
      variable total : natural range 0 to 255*N;
    begin
      if rising_edge(aclk) then
        if aresetn='0' then
          rows_done <= 0; luma_sum <= 0; pending <= '0';
          current_mix <= 0; next_mix <= 0;
        else
          if pv='1' and pr='1' and ps='1' then
            current_mix <= next_mix;
            pending <= '0';
          end if;
          if camera_valid='1' and camera_ready='1' then
            row := rows_done; total := luma_sum;
            if s_axis_tuser='1' then row := 0; total := 0; end if;
            if row<METER_ROWS then
              total := total+luma(unpack(to_integer(unsigned(s_axis_tdata))));
              luma_sum <= total;
              if s_axis_tlast='1' then row := row+1; end if;
              rows_done <= row;
              if row=METER_ROWS then
                -- Mean <= 64 selects the low-light reference. At 96 and above
                -- select the protected grade. The interval is a linear Q5 mix.
                next_mix <= clamp((total+N/2)/N-64,0,32);
                pending <= '1';
              end if;
            end if;
          end if;
        end if;
      end if;
    end process;
  end generate;

  fixed_colour : if not (G_DESIGNER1 and G_LARGE_VIEW and not G_PORTRAIT_FRAMING) generate
    input_enable <= '1'; grade_enable <= '1'; neutral_mix <= 0;
  end generate;

  camera_filter : entity work.pic2_filter_axis
    generic map (G_WIDTH=>G_WIDTH, G_HEIGHT=>G_HEIGHT, G_MEDIUM_STEP=>G_MEDIUM_STEP,
                 G_COARSE_STEP=>G_COARSE_STEP, G_CONTOUR_STEP=>G_CONTOUR_STEP, G_CHROMA_Q8=>G_CHROMA_Q8)
    port map (aclk=>aclk, aresetn=>aresetn,
              active_width=>std_logic_vector(to_unsigned(G_WIDTH,16)),
              active_height=>std_logic_vector(to_unsigned(G_HEIGHT,16)),
              s_axis_tdata=>s_axis_tdata, s_axis_tvalid=>camera_valid, s_axis_tready=>camera_ready,
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
    signal gv, gr, gs, gl, grade_input_ready : std_logic;
  begin
    pr <= grade_input_ready and grade_enable;
    grade : entity work.axis_designer1_grade
      port map (aclk=>aclk, aresetn=>aresetn,
                s_axis_tdata=>framed, s_axis_tvalid=>pv and grade_enable, s_axis_tready=>grade_input_ready,
                s_axis_tuser=>ps, s_axis_tlast=>pl, s_neutral_mix=>neutral_mix,
                m_axis_tdata=>graded, m_axis_tvalid=>gv, m_axis_tready=>gr, m_axis_tuser=>gs, m_axis_tlast=>gl);
    finish : entity work.axis_designer1_finish
      generic map (G_WIDTH=>W_OUT, G_HEIGHT=>H_OUT)
      port map (aclk=>aclk, aresetn=>aresetn,
                s_axis_tdata=>graded, s_axis_tvalid=>gv, s_axis_tready=>gr, s_axis_tuser=>gs, s_axis_tlast=>gl,
                m_axis_tdata=>m_axis_tdata, m_axis_tvalid=>m_axis_tvalid, m_axis_tready=>m_axis_tready,
                m_axis_tuser=>m_axis_tuser, m_axis_tlast=>m_axis_tlast);
  end generate;
  earlier_grade : if not (G_DESIGNER1 and G_LARGE_VIEW) generate
  portrait_grade : entity work.axis_designer_grade
    generic map (G_LARGE_VIEW=>G_LARGE_VIEW)
    port map (aclk=>aclk, aresetn=>aresetn,
              s_axis_tdata=>framed, s_axis_tvalid=>pv, s_axis_tready=>pr, s_axis_tuser=>ps, s_axis_tlast=>pl,
              m_axis_tdata=>m_axis_tdata, m_axis_tvalid=>m_axis_tvalid, m_axis_tready=>m_axis_tready,
              m_axis_tuser=>m_axis_tuser, m_axis_tlast=>m_axis_tlast);
  end generate;
end architecture;
