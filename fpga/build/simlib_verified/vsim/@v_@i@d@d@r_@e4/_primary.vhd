library verilog;
use verilog.vl_types.all;
entity V_IDDR_E4 is
    generic(
        HPIO            : string  := "FALSE";
        GRS_EN          : string  := "TRUE";
        Q_INIT          : vl_logic := Hi0;
        IDDR_MODE       : string  := "OPPOSITE_EDGE";
        RS_TYPE         : string  := "ASYNC_RESET"
    );
    port(
        Q0              : out    vl_logic;
        Q1              : out    vl_logic;
        D               : in     vl_logic;
        CLK             : in     vl_logic;
        CE              : in     vl_logic;
        RS              : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of HPIO : constant is 1;
    attribute mti_svvh_generic_type of GRS_EN : constant is 1;
    attribute mti_svvh_generic_type of Q_INIT : constant is 1;
    attribute mti_svvh_generic_type of IDDR_MODE : constant is 1;
    attribute mti_svvh_generic_type of RS_TYPE : constant is 1;
end V_IDDR_E4;
