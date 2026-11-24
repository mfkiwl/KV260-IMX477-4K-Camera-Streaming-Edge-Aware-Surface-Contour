library ieee;
use ieee.std_logic_1164.all;

-- One synchronous read port and one synchronous write port on the same clock.
-- The controller qualifies reads and makes all data valid before first use.
entity portrait_sdp_ram is
  generic (WORD_BITS : positive; DEPTH : positive; MEMORY_STYLE : string := "auto");
  port (clk, wr_en, rd_en : in std_logic;
        wr_addr, rd_addr : in natural range 0 to DEPTH-1;
        wr_data : in std_logic_vector(WORD_BITS-1 downto 0);
        rd_data : out std_logic_vector(WORD_BITS-1 downto 0));
end entity;
architecture rtl of portrait_sdp_ram is
  type words_t is array (0 to DEPTH-1) of std_logic_vector(WORD_BITS-1 downto 0);
  signal memory : words_t;
  attribute ram_style : string;
  attribute ram_style of memory : signal is MEMORY_STYLE;
begin
  process(clk)
  begin
    if rising_edge(clk) then
      if wr_en='1' then memory(wr_addr) <= wr_data; end if;
      if rd_en='1' then rd_data <= memory(rd_addr); end if;
    end if;
  end process;
end architecture;
