library verilog;
use verilog.vl_types.all;
entity V_SCKMUX is
    port(
        CLKIN           : in     vl_logic_vector(11 downto 0);
        CLKOUT_P        : out    vl_logic_vector(5 downto 0);
        CFG_MUX         : in     vl_logic_vector(6 downto 0)
    );
end V_SCKMUX;
