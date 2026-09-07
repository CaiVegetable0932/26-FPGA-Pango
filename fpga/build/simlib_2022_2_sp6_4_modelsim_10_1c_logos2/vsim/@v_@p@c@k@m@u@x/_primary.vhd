library verilog;
use verilog.vl_types.all;
entity V_PCKMUX is
    port(
        CLKIN           : in     vl_logic_vector(29 downto 0);
        CLKOUT          : out    vl_logic_vector(2 downto 0);
        CFG_MUX         : in     vl_logic_vector(6 downto 0)
    );
end V_PCKMUX;
