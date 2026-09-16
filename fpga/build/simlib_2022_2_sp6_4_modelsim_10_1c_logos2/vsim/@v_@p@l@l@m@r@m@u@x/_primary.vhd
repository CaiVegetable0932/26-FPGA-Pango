library verilog;
use verilog.vl_types.all;
entity V_PLLMRMUX is
    port(
        CLKIN_P         : in     vl_logic_vector(7 downto 0);
        CLKOUT_P        : out    vl_logic_vector(3 downto 0);
        CFG_MUX0        : in     vl_logic_vector(3 downto 0);
        CFG_MUX1        : in     vl_logic_vector(3 downto 0);
        CFG_MUX2        : in     vl_logic_vector(3 downto 0);
        CFG_MUX3        : in     vl_logic_vector(3 downto 0)
    );
end V_PLLMRMUX;
