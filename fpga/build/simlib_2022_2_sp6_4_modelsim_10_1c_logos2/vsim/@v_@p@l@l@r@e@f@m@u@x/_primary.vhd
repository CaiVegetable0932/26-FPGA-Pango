library verilog;
use verilog.vl_types.all;
entity V_PLLREFMUX is
    port(
        CLK_P           : in     vl_logic_vector(3 downto 0);
        CLK_SRB         : in     vl_logic_vector(3 downto 0);
        CLKOUT_P        : out    vl_logic_vector(3 downto 0);
        CFG_MUX0        : in     vl_logic_vector(3 downto 0);
        CFG_MUX1        : in     vl_logic_vector(3 downto 0);
        CFG_MUX2        : in     vl_logic_vector(3 downto 0);
        CFG_MUX3        : in     vl_logic_vector(3 downto 0);
        CFG_ENABLE      : in     vl_logic_vector(3 downto 0);
        SEL_U           : in     vl_logic_vector(3 downto 0);
        SEL_D           : in     vl_logic_vector(3 downto 0)
    );
end V_PLLREFMUX;
