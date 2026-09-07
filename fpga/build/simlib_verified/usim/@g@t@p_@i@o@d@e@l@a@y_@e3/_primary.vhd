library verilog;
use verilog.vl_types.all;
entity GTP_IODELAY_E3 is
    generic(
        DELAY_STEP_VALUE: vl_logic_vector(0 to 6) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0);
        DELAY_STEP_SEL  : string  := "PARAMETER"
    );
    port(
        DO              : out    vl_logic;
        DI              : in     vl_logic;
        CLK             : in     vl_logic;
        RST_N           : in     vl_logic;
        INCR            : in     vl_logic;
        DECR            : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of DELAY_STEP_VALUE : constant is 1;
    attribute mti_svvh_generic_type of DELAY_STEP_SEL : constant is 1;
end GTP_IODELAY_E3;
