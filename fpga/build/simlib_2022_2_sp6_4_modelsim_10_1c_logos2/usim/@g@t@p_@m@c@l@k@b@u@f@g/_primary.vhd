library verilog;
use verilog.vl_types.all;
entity GTP_MCLKBUFG is
    generic(
        FD_EN           : string  := "FALSE"
    );
    port(
        CLKIN           : in     vl_logic;
        CLR_NODE_N      : in     vl_logic;
        CLKOUT0         : out    vl_logic;
        CLKOUT1         : out    vl_logic;
        CLKOUT2         : out    vl_logic;
        CLKOUT3         : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of FD_EN : constant is 1;
end GTP_MCLKBUFG;
