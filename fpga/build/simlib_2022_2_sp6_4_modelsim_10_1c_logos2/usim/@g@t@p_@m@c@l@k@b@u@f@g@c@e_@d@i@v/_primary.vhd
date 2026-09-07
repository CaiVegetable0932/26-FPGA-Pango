library verilog;
use verilog.vl_types.all;
entity GTP_MCLKBUFGCE_DIV is
    generic(
        FD_EN           : string  := "FALSE";
        CE_INV          : vl_logic := Hi0;
        CLR_N_INV       : vl_logic := Hi0;
        CLK_INV         : vl_logic := Hi0;
        DIV_FACTOR      : string  := "1"
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
    attribute mti_svvh_generic_type of FD_EN : constant is 1;
    attribute mti_svvh_generic_type of CE_INV : constant is 1;
    attribute mti_svvh_generic_type of CLR_N_INV : constant is 1;
    attribute mti_svvh_generic_type of CLK_INV : constant is 1;
    attribute mti_svvh_generic_type of DIV_FACTOR : constant is 1;
end GTP_MCLKBUFGCE_DIV;
