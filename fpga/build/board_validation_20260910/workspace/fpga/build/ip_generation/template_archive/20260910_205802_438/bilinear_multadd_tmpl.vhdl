-- Created by IP Generator (Version 2022.2-SP6.4 build 146967)
-- Instantiation Template
--
-- Insert the following codes into your VHDL file.
--   * Change the_instance_name to your own instance name.
--   * Change the net names in the port map.


COMPONENT bilinear_multadd
  PORT (
    clk : IN STD_LOGIC;
    rst : IN STD_LOGIC;
    ce : IN STD_LOGIC;
    a0 : IN STD_LOGIC_VECTOR(17 DOWNTO 0);
    b0 : IN STD_LOGIC_VECTOR(8 DOWNTO 0);
    a1 : IN STD_LOGIC_VECTOR(17 DOWNTO 0);
    b1 : IN STD_LOGIC_VECTOR(8 DOWNTO 0);
    p : OUT STD_LOGIC_VECTOR(27 DOWNTO 0)
  );
END COMPONENT;


the_instance_name : bilinear_multadd
  PORT MAP (
    clk => clk,
    rst => rst,
    ce => ce,
    a0 => a0,
    b0 => b0,
    a1 => a1,
    b1 => b1,
    p => p
  );
