-- Created by IP Generator (Version 2022.2-SP6.4 build 146967)
-- Instantiation Template
--
-- Insert the following codes into your VHDL file.
--   * Change the_instance_name to your own instance name.
--   * Change the net names in the port map.


COMPONENT isp_line_ram
  PORT (
    wr_clk : IN STD_LOGIC;
    wr_en : IN STD_LOGIC;
    rd_clk : IN STD_LOGIC;
    rd_rst : IN STD_LOGIC;
    wr_addr : IN STD_LOGIC_VECTOR(10 DOWNTO 0);
    wr_data : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    rd_addr : IN STD_LOGIC_VECTOR(10 DOWNTO 0);
    rd_data : OUT STD_LOGIC_VECTOR(31 DOWNTO 0)
  );
END COMPONENT;


the_instance_name : isp_line_ram
  PORT MAP (
    wr_clk => wr_clk,
    wr_en => wr_en,
    rd_clk => rd_clk,
    rd_rst => rd_rst,
    wr_addr => wr_addr,
    wr_data => wr_data,
    rd_addr => rd_addr,
    rd_data => rd_data
  );
