library verilog;
use verilog.vl_types.all;
entity V_USCMMUX is
    port(
        CLKIN           : in     vl_logic_vector(5 downto 0);
        CLKOUT          : out    vl_logic_vector(1 downto 0);
        CFG_MUX0        : in     vl_logic_vector(2 downto 0);
        CFG_MUX1        : in     vl_logic_vector(2 downto 0)
    );
end V_USCMMUX;
