library verilog;
use verilog.vl_types.all;
entity GTP_MCLKBUFG_HT is
    generic(
        CLKOUT_CE       : string  := "DISABLE";
        FD_EN           : string  := "FALSE"
    );
    port(
        CLKOUT0         : out    vl_logic;
        CLKOUT1         : out    vl_logic;
        CLKOUT2         : out    vl_logic;
        CLKOUT3         : out    vl_logic;
        CLKIN           : in     vl_logic;
        CE              : in     vl_logic;
        CLR_N           : in     vl_logic;
        CLR_NODE_N      : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CLKOUT_CE : constant is 1;
    attribute mti_svvh_generic_type of FD_EN : constant is 1;
end GTP_MCLKBUFG_HT;
