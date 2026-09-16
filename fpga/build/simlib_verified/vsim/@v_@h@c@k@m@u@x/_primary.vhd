library verilog;
use verilog.vl_types.all;
entity V_HCKMUX is
    port(
        CLKIN           : in     vl_logic_vector(61 downto 0);
        CLKOUT          : out    vl_logic_vector(11 downto 0);
        CFG_MUX0        : in     vl_logic_vector(5 downto 0);
        CFG_MUX1        : in     vl_logic_vector(5 downto 0);
        CFG_MUX2        : in     vl_logic_vector(5 downto 0);
        CFG_MUX3        : in     vl_logic_vector(5 downto 0);
        CFG_MUX4        : in     vl_logic_vector(5 downto 0);
        CFG_MUX5        : in     vl_logic_vector(5 downto 0);
        CFG_MUX6        : in     vl_logic_vector(5 downto 0);
        CFG_MUX7        : in     vl_logic_vector(5 downto 0);
        CFG_MUX8        : in     vl_logic_vector(5 downto 0);
        CFG_MUX9        : in     vl_logic_vector(5 downto 0);
        CFG_MUX10       : in     vl_logic_vector(5 downto 0);
        CFG_MUX11       : in     vl_logic_vector(5 downto 0)
    );
end V_HCKMUX;
