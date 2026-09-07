library verilog;
use verilog.vl_types.all;
entity V_RCKMUX is
    port(
        CLKIN           : in     vl_logic_vector(11 downto 0);
        CLKOUT          : out    vl_logic_vector(3 downto 0);
        CFG_MUX         : in     vl_logic_vector(5 downto 0)
    );
end V_RCKMUX;
