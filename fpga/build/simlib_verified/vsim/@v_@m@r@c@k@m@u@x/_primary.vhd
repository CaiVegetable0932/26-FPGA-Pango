library verilog;
use verilog.vl_types.all;
entity V_MRCKMUX is
    port(
        CLKIN           : in     vl_logic_vector(11 downto 0);
        CLKIN_P         : in     vl_logic_vector(1 downto 0);
        CLKOUT_P        : out    vl_logic_vector(1 downto 0);
        CFG_MUX0        : in     vl_logic_vector(3 downto 0);
        CFG_MUX1        : in     vl_logic_vector(3 downto 0)
    );
end V_MRCKMUX;
