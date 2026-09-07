library verilog;
use verilog.vl_types.all;
entity GTP_MCLKBUFGMUX is
    generic(
        TRIGGER_MODE    : string  := "NORMAL";
        FD_EN           : string  := "FALSE"
    );
    port(
        CLKOUT0         : out    vl_logic;
        CLKOUT1         : out    vl_logic;
        CLKOUT2         : out    vl_logic;
        CLKOUT3         : out    vl_logic;
        CLKIN0          : in     vl_logic;
        CLKIN1          : in     vl_logic;
        SEL             : in     vl_logic;
        CLR_NODE_N      : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of TRIGGER_MODE : constant is 1;
    attribute mti_svvh_generic_type of FD_EN : constant is 1;
end GTP_MCLKBUFGMUX;
