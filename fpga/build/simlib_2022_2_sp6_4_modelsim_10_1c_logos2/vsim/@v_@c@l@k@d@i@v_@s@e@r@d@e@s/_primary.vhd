library verilog;
use verilog.vl_types.all;
entity V_CLKDIV_SERDES is
    generic(
        DIV_FACTOR      : string  := "2";
        OSERDES_EN      : string  := "FALSE";
        LANE_RX_SEL     : vl_logic := Hi0
    );
    port(
        CLKDIVOUT       : out    vl_logic;
        UPDATE          : out    vl_logic;
        CLKIN           : in     vl_logic;
        BITSLIP         : in     vl_logic;
        RST_N           : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of DIV_FACTOR : constant is 1;
    attribute mti_svvh_generic_type of OSERDES_EN : constant is 1;
    attribute mti_svvh_generic_type of LANE_RX_SEL : constant is 1;
end V_CLKDIV_SERDES;
