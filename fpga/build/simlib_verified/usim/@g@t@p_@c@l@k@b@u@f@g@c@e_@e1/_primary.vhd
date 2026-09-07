library verilog;
use verilog.vl_types.all;
entity GTP_CLKBUFGCE_E1 is
    port(
        CLKOUT          : out    vl_logic;
        CLKIN           : in     vl_logic;
        CE              : in     vl_logic
    );
end GTP_CLKBUFGCE_E1;
