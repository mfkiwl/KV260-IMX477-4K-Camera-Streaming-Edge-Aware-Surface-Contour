library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_axis_portrait_filter is
  generic (
    G_WIDTH  : positive := 2048;
    G_HEIGHT : positive := 1152;
    G_STRESS : boolean := false;
    G_SHIFT  : boolean := true;
    G_TRACE  : boolean := false;
    G_RETURN_TO_TCL : boolean := false
  );
end entity;

architecture bench of tb_axis_portrait_filter is
  constant C_PIXELS : positive := G_WIDTH * G_HEIGHT;
  constant C_PERIOD : time := 10 ns;
  -- Wait past the output pipeline and several line periods to catch trailing beats.
  constant C_DRAIN_CYCLES : positive := 4 * G_WIDTH + 1024;
  signal aclk, complete : std_logic := '0';
  signal aresetn : std_logic := '0';
  signal s_data, m_data : std_logic_vector(31 downto 0);
  signal s_valid, s_ready, s_user, s_last : std_logic;
  signal m_valid, m_ready, m_user, m_last : std_logic;

  type byte_file is file of character;

  impure function read_rgb10(file input_bytes : byte_file)
    return std_logic_vector is
    variable packed : std_logic_vector(31 downto 0) := (others => '0');
    variable b : character;
    variable rgb8 : std_logic_vector(7 downto 0);
  begin
    for channel in 2 downto 0 loop  -- R, G, B in raw-file order
      assert not endfile(input_bytes) report "Truncated input RGB file" severity failure;
      read(input_bytes, b);
      rgb8 := std_logic_vector(to_unsigned(character'pos(b), 8));
      if G_SHIFT then
        packed(10*channel+9 downto 10*channel) := rgb8 & "00";
      else
        packed(10*channel+9 downto 10*channel) := rgb8 & rgb8(7 downto 6);
      end if;
    end loop;
    return packed;
  end function;

  procedure write_rgb8(file output_bytes : byte_file;
                       constant packed : in std_logic_vector(31 downto 0)) is
    variable rgb8 : natural;
  begin
    for channel in 2 downto 0 loop
      rgb8 := to_integer(unsigned(packed(10*channel+9 downto 10*channel+2)));
      write(output_bytes, character'val(rgb8));
    end loop;
  end procedure;
begin
  aclk <= not aclk after C_PERIOD / 2 when complete = '0' else '0';

  dut : entity work.axis_portrait_filter
    generic map (G_WIDTH => G_WIDTH, G_HEIGHT => G_HEIGHT)
    port map (
      aclk => aclk, aresetn => aresetn,
      s_axis_tdata => s_data, s_axis_tvalid => s_valid, s_axis_tready => s_ready,
      s_axis_tuser => s_user, s_axis_tlast => s_last,
      m_axis_tdata => m_data, m_axis_tvalid => m_valid, m_axis_tready => m_ready,
      m_axis_tuser => m_user, m_axis_tlast => m_last
    );

  stream : process
    file input_bytes : byte_file open read_mode is "source.rgb";
    file output_bytes : byte_file open write_mode is "capture.rgb";
    file trace_bytes : byte_file;
    file passed : byte_file;
    variable sent, received, cycles, idle_cycles : natural := 0;
    variable held : boolean := false;
    variable held_data : std_logic_vector(31 downto 0);
    variable held_user, held_last : std_logic;
    variable input_accepted : boolean;
    variable source_gaps, backpressured : natural := 0;
  begin
    if G_TRACE then
      file_open(trace_bytes, "capture.u32le", write_mode);
    end if;
    s_valid <= '0';
    s_user <= '0';
    s_last <= '0';
    s_data <= (others => '0');
    m_ready <= '0';
    for i in 1 to 4 loop
      wait until rising_edge(aclk);
    end loop;
    aresetn <= '1';
    m_ready <= '1';

    loop
      wait until rising_edge(aclk);
      cycles := cycles + 1;
      assert cycles < 16*C_PIXELS + 640*G_WIDTH + 65536
        report "Watchdog expired: accepted input=" & natural'image(sent) &
               " output=" & natural'image(received) severity failure;

      input_accepted := s_valid = '1' and s_ready = '1';
      if input_accepted then
        sent := sent + 1;
      end if;

      if held then
        assert m_valid = '1' and m_data = held_data and
               m_user = held_user and m_last = held_last
          report "DUT changed its output during backpressure" severity failure;
      end if;
      held := m_valid = '1' and m_ready = '0';
      if held then
        backpressured := backpressured + 1;
        held_data := m_data;
        held_user := m_user;
        held_last := m_last;
      end if;

      if m_valid = '1' and m_ready = '1' then
        assert received < C_PIXELS report "Extra output pixel" severity failure;
        assert m_user = '1' or m_user = '0' report "Unknown TUSER" severity failure;
        assert m_last = '1' or m_last = '0' report "Unknown TLAST" severity failure;
        assert (m_user = '1') = (received = 0)
          report "Incorrect SOF at pixel " & natural'image(received) severity failure;
        assert (m_last = '1') = (received mod G_WIDTH = G_WIDTH-1)
          report "Incorrect EOL at pixel " & natural'image(received) severity failure;
        assert not is_x(m_data(29 downto 0))
          report "Unknown bits in output RGB" severity failure;
        write_rgb8(output_bytes, m_data);
        if G_TRACE then
          assert not is_x(m_data(31 downto 30)) report "Unknown upper trace bits" severity failure;
          for i in 0 to 3 loop
            write(trace_bytes, character'val(to_integer(unsigned(m_data(8*i+7 downto 8*i)))));
          end loop;
        end if;
        received := received + 1;
      end if;

      if s_valid = '0' or input_accepted then
        s_valid <= '0';
        if sent < C_PIXELS then
          if not G_STRESS or cycles mod 37 >= 3 then
            s_valid <= '1';
            s_data <= read_rgb10(input_bytes);
            if sent = 0 then s_user <= '1'; else s_user <= '0'; end if;
            if sent mod G_WIDTH = G_WIDTH-1 then s_last <= '1'; else s_last <= '0'; end if;
          else
            source_gaps := source_gaps + 1;
          end if;
        end if;
      end if;

      if G_STRESS and cycles mod 43 < 5 and received < C_PIXELS then
        m_ready <= '0';
      else
        m_ready <= '1';
      end if;

      if sent = C_PIXELS and received = C_PIXELS then
        idle_cycles := idle_cycles + 1;
        exit when idle_cycles > C_DRAIN_CYCLES;
      end if;
    end loop;

    assert endfile(input_bytes) report "Extra bytes in input RGB file" severity failure;
    file_close(input_bytes);
    file_close(output_bytes);
    if G_TRACE then file_close(trace_bytes); end if;
    report "AXI PASS: input=" & natural'image(sent) & " output=" &
           natural'image(received) & " cycles=" & natural'image(cycles) &
           " source_gap_cycles=" & natural'image(source_gaps) &
           " output_stall_cycles=" & natural'image(backpressured) severity note;
    if G_RETURN_TO_TCL then
      -- Let run -all return when the clock stops, keeping Questa's Tcl session
      -- alive long enough to validate and publish the captured frame.
      file_open(passed, "axis.passed", write_mode);
      write(passed, '1');
      file_close(passed);
      complete <= '1';
    else
      finish;
    end if;
    wait;
  end process;
end architecture;
