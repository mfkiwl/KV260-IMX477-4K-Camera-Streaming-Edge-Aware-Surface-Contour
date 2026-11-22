-- Profile 3 keeps native pixel coordinates. Profile 2 uses the legacy artwork framing.
package designer_geometry is
  constant INPUT_WIDTH  : positive := 2048;
  constant INPUT_HEIGHT : positive := 1152;
  subtype profile_t is integer range 2 to 3;
  function output_height(profile : profile_t; native_height : positive := INPUT_HEIGHT) return positive;
  function source_x(profile : profile_t; x : natural) return natural;
  function source_y(profile : profile_t; y : natural) return natural;
end package;

package body designer_geometry is
  type knots_t is array(natural range <>) of natural;
  function interpolate(x : natural; at_out, at_in : knots_t) return natural is
    variable span : positive;
  begin
    for k in 1 to at_out'high loop
      if x <= at_out(k) then
        span := at_out(k) - at_out(k-1);
        return at_in(k-1) + ((x-at_out(k-1)) * (at_in(k)-at_in(k-1)) + span/2) / span;
      end if;
    end loop;
    return at_in(at_in'high);
  end function;

  function output_height(profile : profile_t; native_height : positive := INPUT_HEIGHT) return positive is
  begin
    if profile = 2 then return 1143; end if;
    return native_height;
  end function;

  function source_x(profile : profile_t; x : natural) return natural is
  begin
    if profile = 2 then
      return interpolate(x, (0, 208, 645, 1637, 1885, 2047), (0, 119, 623, 1679, 1906, 2047));
    end if;
    return x;
  end function;

  function source_y(profile : profile_t; y : natural) return natural is
  begin
    if profile = 2 then
      return interpolate(y, (0, 437, 943, 1052, 1142), (4, 464, 1004, 1102, 1151));
    end if;
    return y;
  end function;

end package body;

library ieee;
use ieee.std_logic_1164.all;
use work.designer_geometry.all;

-- The native view forwards data and both markers together on each AXI transfer.
entity axis_designer_view is
  generic (G_PROFILE : profile_t := 3);
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
  native_view : if G_PROFILE = 3 generate
    signal valid_q : std_logic := '0';
    signal advance : std_logic;
  begin
    advance <= not valid_q or m_axis_tready;
    s_axis_tready <= aresetn and advance;
    m_axis_tvalid <= valid_q;

    stream_register : process (aclk)
    begin
      if rising_edge(aclk) then
        if aresetn = '0' then
          valid_q <= '0';
          m_axis_tdata <= (others => '0');
          m_axis_tuser <= '0';
          m_axis_tlast <= '0';
        elsif advance = '1' then
          valid_q <= s_axis_tvalid;
          if s_axis_tvalid = '1' then
            m_axis_tdata <= s_axis_tdata;
            m_axis_tuser <= s_axis_tuser;
            m_axis_tlast <= s_axis_tlast;
          end if;
        end if;
      end if;
    end process;
  end generate;

  -- Only the optional 1143-line artwork profile selects and replays samples.
  artwork_view : if G_PROFILE = 2 generate
    constant OUTPUT_WIDTH : positive := INPUT_WIDTH;
    constant ROWS_OUT : positive := output_height(G_PROFILE);
    constant FIRST_Y : natural := source_y(G_PROFILE,0);
    type steps_t is array (natural range <>) of natural range 0 to 2;

    function horizontal_steps return steps_t is
      variable steps : steps_t(0 to OUTPUT_WIDTH-1) := (others => 0);
    begin
      for x in 0 to OUTPUT_WIDTH-2 loop
        steps(x) := source_x(G_PROFILE,x+1) - source_x(G_PROFILE,x);
      end loop;
      return steps;
    end function;

    function vertical_steps return steps_t is
      variable steps : steps_t(0 to ROWS_OUT-1) := (others => 0);
    begin
      for y in 0 to ROWS_OUT-2 loop
        steps(y) := source_y(G_PROFILE,y+1) - source_y(G_PROFILE,y);
      end loop;
      return steps;
    end function;

    constant DX : steps_t := horizontal_steps;
    constant DY : steps_t := vertical_steps;
    type row_t is array (0 to OUTPUT_WIDTH-1) of std_logic_vector(23 downto 0);
    signal line_memory : row_t;
    signal live_data, replay_data, row_write_data : std_logic_vector(23 downto 0);
    signal row_write_enable : std_logic;
    signal in_x : natural range 0 to INPUT_WIDTH-1 := 0;
    signal in_y : natural range 0 to INPUT_HEIGHT-1 := 0;
    signal out_x : natural range 0 to OUTPUT_WIDTH-1 := 0;
    signal out_y : natural range 0 to ROWS_OUT-1 := 0;
    signal sample_x : natural range 0 to INPUT_WIDTH-1 := 0;
    signal sample_y : natural range 0 to INPUT_HEIGHT-1 := FIRST_Y;
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
    begin
      if rising_edge(aclk) then
        if aresetn='0' then
          in_x <= 0; in_y <= 0; out_x <= 0; out_y <= 0;
          sample_x <= 0; sample_y <= FIRST_Y;
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
                out_x <= 0; sample_x <= 0;
                replay_row <= '0';
                if out_y=ROWS_OUT-1 then
                  out_y <= 0; sample_y <= FIRST_Y;
                else
                  out_y <= out_y+1;
                  sample_y <= sample_y + DY(out_y);
                  if DY(out_y)=0 then replay_row <= '1'; end if;
                end if;
              else
                out_x <= out_x+1;
                sample_x <= sample_x + DX(out_x);
                if DX(out_x)=0 and replay_row='0' then
                  repeat_column <= '1';
                end if;
              end if;
            end if;
          end if;
        end if;
      end if;
    end process;
  end generate;
end architecture;
