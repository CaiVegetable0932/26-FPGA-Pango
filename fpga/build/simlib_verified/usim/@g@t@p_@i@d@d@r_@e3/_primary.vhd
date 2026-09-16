library verilog;
use verilog.vl_types.all;
entity GTP_IDDR_E3 is
    generic(
        IDDR_MODE       : string  := "OPPOSITE_EDGE";
        CLK_INV         : vl_logic := Hi0;
        RS_INV          : vl_logic := Hi0;
        Q_INIT          : vl_logic := Hi0;
        RS_TYPE         : string  := "ASYNC_RESET"
    );
    port(
        Q0              : out    vl_logic;
        Q1              : out    vl_logic;
        D               : in     vl_logic;
        CLK             : in     vl_logic;
        RS              : in     vl_logic;
        CE              : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of IDDR_MODE : constant is 1;
    attribute mti_svvh_generic_type of CLK_INV : constant is 1;
    attribute mti_svvh_generic_type of RS_INV : constant is 1;
    attribute mti_svvh_generic_type of Q_INIT : constant is 1;
    attribute mti_svvh_generic_type of RS_TYPE : constant is 1;
end GTP_IDDR_E3;
