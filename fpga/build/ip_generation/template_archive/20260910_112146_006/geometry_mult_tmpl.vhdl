-- Created by IP Generator (Version 2022.2-SP6.4 build 146967)
-- Instantiation Template
--
-- Insert the following codes into your VHDL file.
--   * Change the_instance_name to your own instance name.
--   * Change the net names in the port map.


COMPONENT geometry_mult
  PORT (
    clk : IN STD_LOGIC;
    rst : IN STD_LOGIC;
    ce : IN STD_LOGIC;
    a : IN STD_LOGIC_VECTOR(24 DOWNTO 0);
    b : IN STD_LOGIC_VECTOR(17 DOWNTO 0);
    p : OUT STD_LOGIC_VECTOR(42 DOWNTO 0)
  );
END COMPONENT;


the_instance_name : geometry_mult
  PORT MAP (
    clk => clk,
    rst => rst,
    ce => ce,
    a => a,
    b => b,
    p => p
  );
