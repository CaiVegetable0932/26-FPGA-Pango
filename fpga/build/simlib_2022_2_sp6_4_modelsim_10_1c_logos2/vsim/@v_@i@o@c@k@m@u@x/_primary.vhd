library verilog;
use verilog.vl_types.all;
entity V_IOCKMUX is
    port(
        CLKIN_P         : in     vl_logic_vector(7 downto 0);
        CLKOUT_P        : out    vl_logic_vector(3 downto 0);
        CFG_MUX         : in     vl_logic_vector(5 downto 0)
    );
end V_IOCKMUX;
