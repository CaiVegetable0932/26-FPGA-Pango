library verilog;
use verilog.vl_types.all;
entity V_CLKBUFG_HT is
    generic(
        CLKOUT_CE       : string  := "ENABLE"
    );
    port(
        CLKOUT          : out    vl_logic;
        CLKOUT_DIV      : out    vl_logic;
        CLKIN           : in     vl_logic;
        CE              : in     vl_logic;
        CLR_N           : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CLKOUT_CE : constant is 1;
end V_CLKBUFG_HT;
