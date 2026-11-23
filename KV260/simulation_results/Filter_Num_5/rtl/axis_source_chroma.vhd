library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pic2_types.all;

-- Aligned rasters have one output beat per accepted input pixel. Store only
-- the two signed source channel differences until the filtered beat arrives.
entity axis_source_chroma is
  generic (G_DEPTH : positive);
  port (
    aclk, aresetn : in std_logic;
    raw_rgb : in std_logic_vector(23 downto 0);
    raw_push : in std_logic;
    raw_room : out std_logic;
    s_axis_tdata : in std_logic_vector(23 downto 0);
    s_axis_tvalid, s_axis_tuser, s_axis_tlast, s_use_designer : in std_logic;
    s_axis_tready : out std_logic;
    m_axis_tdata : out std_logic_vector(23 downto 0);
    m_axis_tvalid, m_axis_tuser, m_axis_tlast : out std_logic;
    m_axis_tready : in std_logic
  );
end entity;

architecture rtl of axis_source_chroma is
  subtype delta_t is integer range -255 to 255;
  type memory_t is array (0 to G_DEPTH-1) of std_logic_vector(17 downto 0);
  signal memory : memory_t;
  attribute ram_style : string;
  attribute ram_style of memory : signal is "block";
  signal wr, rd : natural range 0 to G_DEPTH-1 := 0;
  signal used : natural range 0 to G_DEPTH := 0;
  signal available, pop, advance : std_logic;
  signal deltas_q : std_logic_vector(17 downto 0);
  signal red1, blue1, red2, blue2 : delta_t;
  signal target_y, green_lo, green_hi, green2 : byte_t;
  signal target_g : integer range -112 to 367;
  type data_pipe_t is array (0 to 2) of std_logic_vector(23 downto 0);
  signal original : data_pipe_t;
  signal designer : std_logic_vector(0 to 2);
  signal valid, sof, eol : std_logic_vector(0 to 3) := (others=>'0');
  function next_address(addr : natural) return natural is
  begin
    if addr=G_DEPTH-1 then return 0; else return addr+1; end if;
  end;
begin
  raw_room <= '1' when used<G_DEPTH else '0';
  available <= '1' when used>0 else '0';
  advance <= not valid(3) or m_axis_tready;
  s_axis_tready <= aresetn and available and advance;
  pop <= s_axis_tvalid and s_axis_tready;
  m_axis_tvalid <= valid(3); m_axis_tuser <= sof(3); m_axis_tlast <= eol(3);

  storage : process(aclk)
    variable r, g, b : byte_t;
  begin
    if rising_edge(aclk) then
      if raw_push='1' then
        r := to_integer(unsigned(raw_rgb(23 downto 16)));
        g := to_integer(unsigned(raw_rgb(15 downto 8)));
        b := to_integer(unsigned(raw_rgb(7 downto 0)));
        memory(wr) <= std_logic_vector(to_signed(r-g,9)) & std_logic_vector(to_signed(b-g,9));
      end if;
      if pop='1' then deltas_q <= memory(rd); end if;
    end if;
  end process;

  occupancy : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn='0' then
        wr <= 0; rd <= 0; used <= 0;
      else
        if raw_push='1' then wr <= next_address(wr); end if;
        if pop='1' then rd <= next_address(rd); end if;
        if raw_push='1' and pop='0' then used <= used+1;
        elsif raw_push='0' and pop='1' then used <= used-1;
        end if;
      end if;
    end if;
  end process;

  restore : process(aclk)
    variable dr, db : delta_t;
    variable rgb : rgb_t;
  begin
    if rising_edge(aclk) then
      if aresetn='0' then
        valid <= (others=>'0'); sof <= (others=>'0'); eol <= (others=>'0');
        m_axis_tdata <= (others=>'0');
      elsif advance='1' then
        valid <= pop & valid(0 to 2);
        sof <= (pop and s_axis_tuser) & sof(0 to 2);
        eol <= (pop and s_axis_tlast) & eol(0 to 2);
        if pop='1' then
          original(0) <= s_axis_tdata; designer(0) <= s_use_designer;
          target_y <= luma(unpack(to_integer(unsigned(s_axis_tdata))));
        end if;
        if valid(0)='1' then
          dr := to_integer(signed(deltas_q(17 downto 9)));
          db := to_integer(signed(deltas_q(8 downto 0)));
          red1 <= dr; blue1 <= db;
          -- Luma(G+dr,G,G+db) = G + floor((5*dr+2*db+8)/16).
          -- The bias keeps the VHDL division numerator nonnegative.
          target_g <= target_y - ((2048+5*dr+2*db+8)/16-128);
          green_lo <= largest(0,largest(-dr,-db));
          green_hi <= 255-largest(0,largest(dr,db));
          original(1) <= original(0); designer(1) <= designer(0);
        end if;
        if valid(1)='1' then
          green2 <= clamp(target_g,green_lo,green_hi);
          red2 <= red1; blue2 <= blue1;
          original(2) <= original(1); designer(2) <= designer(1);
        end if;
        if valid(2)='1' then
          if designer(2)='1' then
            m_axis_tdata <= original(2);
          else
            rgb := (green2+red2,green2,green2+blue2);
            m_axis_tdata <= std_logic_vector(to_unsigned(pack(rgb),24));
          end if;
        end if;
      end if;
    end if;
  end process;
end architecture;
