-- Created by IP Generator (Version 2022.2-SP6.4 build 146967)
-- Instantiation Template
--
-- Insert the following codes into your VHDL file.
--   * Change the_instance_name to your own instance name.
--   * Change the net names in the port map.


COMPONENT parameter_ram
  PORT (
    a_clk : IN STD_LOGIC;
    a_wr_en : IN STD_LOGIC;
    a_rst : IN STD_LOGIC;
    a_addr : IN STD_LOGIC_VECTOR(8 DOWNTO 0);
    a_wr_data : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    a_rd_data : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    b_clk : IN STD_LOGIC;
    b_wr_en : IN STD_LOGIC;
    b_rst : IN STD_LOGIC;
    b_addr : IN STD_LOGIC_VECTOR(8 DOWNTO 0);
    b_wr_data : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    b_rd_data : OUT STD_LOGIC_VECTOR(31 DOWNTO 0)
  );
END COMPONENT;


the_instance_name : parameter_ram
  PORT MAP (
    a_clk => a_clk,
    a_wr_en => a_wr_en,
    a_rst => a_rst,
    a_addr => a_addr,
    a_wr_data => a_wr_data,
    a_rd_data => a_rd_data,
    b_clk => b_clk,
    b_wr_en => b_wr_en,
    b_rst => b_rst,
    b_addr => b_addr,
    b_wr_data => b_wr_data,
    b_rd_data => b_rd_data
  );
