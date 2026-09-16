library verilog;
use verilog.vl_types.all;
entity GTP_ODDR_E3 is
    generic(
        CLK_INV         : vl_logic := Hi0;
        RS_INV          : vl_logic := Hi0;
        Q_INIT          : vl_logic := Hi0;
        RS_TYPE         : string  := "ASYNC_RESET"
    );
    port(
        Q               : out    vl_logic;
        D0              : in     vl_logic;
        D1              : in     vl_logic;
        CLK             : in     vl_logic;
        CE              : in     vl_logic;
        RS              : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CLK_INV : constant is 1;
    attribute mti_svvh_generic_type of RS_INV : constant is 1;
    attribute mti_svvh_generic_type of Q_INIT : constant is 1;
    attribute mti_svvh_generic_type of RS_TYPE : constant is 1;
end GTP_ODDR_E3;
