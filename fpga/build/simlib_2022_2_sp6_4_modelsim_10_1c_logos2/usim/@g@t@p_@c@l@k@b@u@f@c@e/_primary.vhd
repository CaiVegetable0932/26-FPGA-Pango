library verilog;
use verilog.vl_types.all;
entity GTP_CLKBUFCE is
    port(
        CLKIN           : in     vl_logic;
        CLKOUT          : out    vl_logic;
        CE              : in     vl_logic
    );
end GTP_CLKBUFCE;
