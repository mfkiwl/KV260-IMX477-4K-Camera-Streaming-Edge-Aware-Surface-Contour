-- Native camera defaults and output geometry for the optional Designer portrait.
package designer_geometry is
  constant INPUT_WIDTH   : positive := 2048;
  constant INPUT_HEIGHT  : positive := 1152;
  function profile_size(large_view : boolean; large, small : natural) return natural;
  function stream_width(source : positive; portrait, large_view : boolean) return positive;
  function stream_height(source : positive; portrait, large_view : boolean) return positive;
end package;

package body designer_geometry is
  function profile_size(large_view : boolean; large, small : natural) return natural is
  begin
    if large_view then return large; end if;
    return small;
  end function;
  function stream_width(source : positive; portrait, large_view : boolean) return positive is
  begin
    if portrait then return profile_size(large_view,2048,1536); end if;
    return source;
  end function;
  function stream_height(source : positive; portrait, large_view : boolean) return positive is
  begin
    if portrait then return profile_size(large_view,1365,1024); end if;
    return source;
  end function;
end package body;

library ieee;
use ieee.std_logic_1164.all;
use work.designer_geometry.all;

-- Default framing forwards the full raster. The optional portrait resampler
-- uses rational steps and a row-replay RAM for the PIC1 reference composition.
entity axis_designer_view is
  generic (G_LARGE_VIEW : boolean := true; G_DESIGNER1 : boolean := false;
           G_PORTRAIT_FRAMING : boolean := false);
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

architecture rtl of axis_designer_view is
begin
  aligned : if not G_PORTRAIT_FRAMING generate
    -- The upstream beat, downstream beat, SOF and EOL transfer on the same edge.
    -- The colour stages on both sides already register their outputs.
    s_axis_tready <= aresetn and m_axis_tready;
    m_axis_tvalid <= aresetn and s_axis_tvalid;
    m_axis_tdata <= s_axis_tdata;
    m_axis_tuser <= s_axis_tuser;
    m_axis_tlast <= s_axis_tlast;
  end generate;

  portrait : if G_PORTRAIT_FRAMING generate
    constant OUTPUT_WIDTH  : positive := profile_size(G_LARGE_VIEW,2048,1536);
    constant OUTPUT_HEIGHT : positive := profile_size(G_LARGE_VIEW,1365,1024);
    constant NEW_PORTRAIT : boolean := G_DESIGNER1 and G_LARGE_VIEW;
    constant FIRST_X : natural := profile_size(NEW_PORTRAIT,70,105);
    constant LAST_X  : natural := 1946;
    constant FIRST_Y : natural := profile_size(NEW_PORTRAIT,0,1);
    constant KNEE_IN  : positive := profile_size(NEW_PORTRAIT,1110,1066);
    constant KNEE_OUT : positive := profile_size(NEW_PORTRAIT,1245,profile_size(G_LARGE_VIEW,1195,896));
    -- The new frame uses different horizontal magnifications on the chair and face.
    -- Earlier profiles have one horizontal segment terminating at the right edge.
    constant X_KNEE_IN  : positive := profile_size(NEW_PORTRAIT,736,LAST_X);
    constant X1_DEN  : positive := profile_size(NEW_PORTRAIT,700,OUTPUT_WIDTH-1);
    constant X2_DEN  : positive := profile_size(NEW_PORTRAIT,1347,1);
    constant X1_BASE : natural := (X_KNEE_IN-FIRST_X)/X1_DEN;
    constant X1_REM  : natural := (X_KNEE_IN-FIRST_X) mod X1_DEN;
    constant X2_BASE : natural := (LAST_X-X_KNEE_IN)/X2_DEN;
    constant X2_REM  : natural := (LAST_X-X_KNEE_IN) mod X2_DEN;
    constant Y1_DEN  : positive := KNEE_OUT;
    constant Y1_BASE : natural := (KNEE_IN-FIRST_Y)/Y1_DEN;
    constant Y1_REM  : natural := (KNEE_IN-FIRST_Y) mod Y1_DEN;
    constant Y2_DEN  : positive := OUTPUT_HEIGHT-1-KNEE_OUT;
    constant Y2_BASE : natural := (INPUT_HEIGHT-1-KNEE_IN)/Y2_DEN;
    constant Y2_REM  : natural := (INPUT_HEIGHT-1-KNEE_IN) mod Y2_DEN;

    type row_t is array (0 to OUTPUT_WIDTH-1) of std_logic_vector(23 downto 0);
    signal line_memory : row_t;
    signal live_data, replay_data, row_write_data : std_logic_vector(23 downto 0);
    signal row_write_enable : std_logic;
    signal in_x : natural range 0 to INPUT_WIDTH-1 := 0;
    signal in_y : natural range 0 to INPUT_HEIGHT-1 := 0;
    signal out_x : natural range 0 to OUTPUT_WIDTH-1 := 0;
    signal out_y : natural range 0 to OUTPUT_HEIGHT-1 := 0;
    signal sample_x : natural range 0 to LAST_X := FIRST_X;
    signal sample_y : natural range 0 to INPUT_HEIGHT-1 := FIRST_Y;
    signal x_frac : natural range 0 to OUTPUT_WIDTH-1 := X1_DEN/2;
    signal y_frac : natural range 0 to OUTPUT_HEIGHT-1 := Y1_DEN/2;
    signal selected, slot_free, take_live, take_column, take_replay : std_logic;
    signal replay_row, repeat_column, using_ram, valid_q, sof_q, eol_q : std_logic := '0';
  begin
    selected <= '1' when in_x=sample_x and in_y=sample_y else '0';
    slot_free <= not valid_q or m_axis_tready;
    s_axis_tready <= aresetn and not replay_row and not repeat_column and (not selected or slot_free);
    take_live <= s_axis_tvalid and s_axis_tready and selected;
    take_column <= aresetn and repeat_column and slot_free;
    take_replay <= aresetn and replay_row and slot_free;

    row_write_enable <= take_live or take_column;
    row_write_data <= live_data when repeat_column='1' else s_axis_tdata;
    m_axis_tdata <= replay_data when using_ram='1' else live_data;
    m_axis_tvalid <= valid_q;
    m_axis_tuser <= sof_q;
    m_axis_tlast <= eol_q;

    -- Write the expanded output row, including repeated columns. The source
    -- beat is accepted once. live_data holds it for any horizontal duplicates.
    row_buffer : process (aclk)
    begin
      if rising_edge(aclk) then
        if row_write_enable='1' then
          line_memory(out_x) <= row_write_data;
        end if;
        if take_live='1' then live_data <= s_axis_tdata; end if;
        if take_replay='1' then
          replay_data <= line_memory(out_x);
        end if;
      end if;
    end process;

    raster : process (aclk)
      variable frac, step, den : natural;
    begin
      if rising_edge(aclk) then
        if aresetn='0' then
          in_x <= 0; in_y <= 0; out_x <= 0; out_y <= 0;
          sample_x <= FIRST_X; sample_y <= FIRST_Y;
          x_frac <= X1_DEN/2; y_frac <= Y1_DEN/2;
          replay_row <= '0'; repeat_column <= '0'; using_ram <= '0';
          valid_q <= '0'; sof_q <= '0'; eol_q <= '0';
        else
          if s_axis_tvalid='1' and s_axis_tready='1' then
            -- synthesis translate_off
            assert (s_axis_tuser='1')=(in_x=0 and in_y=0)
              report "Portrait input SOF is out of position" severity failure;
            assert (s_axis_tlast='1')=(in_x=INPUT_WIDTH-1)
              report "Portrait input EOL is out of position" severity failure;
            -- synthesis translate_on
            if in_x=INPUT_WIDTH-1 then
              in_x <= 0;
              if in_y=INPUT_HEIGHT-1 then in_y <= 0;
              else in_y <= in_y+1;
              end if;
            else
              in_x <= in_x+1;
            end if;
          end if;

          if slot_free='1' then
            valid_q <= take_live or take_column or take_replay;
            using_ram <= take_replay;
            sof_q <= '0'; eol_q <= '0';
            if take_live='1' or take_column='1' or take_replay='1' then
              repeat_column <= '0';
              if out_x=0 and out_y=0 then sof_q <= '1'; end if;
              if out_x=OUTPUT_WIDTH-1 then
                eol_q <= '1';
                out_x <= 0; sample_x <= FIRST_X; x_frac <= X1_DEN/2;
                replay_row <= '0';
                if out_y=OUTPUT_HEIGHT-1 then
                  out_y <= 0; sample_y <= FIRST_Y; y_frac <= Y1_DEN/2;
                else
                  out_y <= out_y+1;
                  if out_y<KNEE_OUT then
                    frac := y_frac+Y1_REM; step := Y1_BASE; den := Y1_DEN;
                  else
                    frac := y_frac+Y2_REM; step := Y2_BASE; den := Y2_DEN;
                  end if;
                  if frac>=den then frac := frac-den; step := step+1; end if;
                  if out_y+1=KNEE_OUT then y_frac <= Y2_DEN/2;
                  else y_frac <= frac;
                  end if;
                  sample_y <= sample_y+step;
                  if step=0 then replay_row <= '1'; end if;
                end if;
              else
                out_x <= out_x+1;
                if out_x<X1_DEN then
                  frac := x_frac+X1_REM; step := X1_BASE; den := X1_DEN;
                else
                  frac := x_frac+X2_REM; step := X2_BASE; den := X2_DEN;
                end if;
                if frac>=den then frac := frac-den; step := step+1; end if;
                if out_x+1=X1_DEN then x_frac <= X2_DEN/2;
                else x_frac <= frac;
                end if;
                sample_x <= sample_x+step;
                if step=0 and replay_row='0' then repeat_column <= '1'; end if;
              end if;
            end if;
          end if;
        end if;
      end if;
    end process;
  end generate;
end architecture;
