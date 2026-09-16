library verilog;
use verilog.vl_types.all;
entity V_ZEROHOLDDELAY_E1 is
    generic(
        DELAY_STEP_VALUE: vl_logic_vector(0 to 6) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0)
    );
    port(
        DO              : out    vl_logic;
        DI              : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of DELAY_STEP_VALUE : constant is 1;
end V_ZEROHOLDDELAY_E1;
