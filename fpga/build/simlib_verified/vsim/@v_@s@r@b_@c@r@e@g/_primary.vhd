library verilog;
use verilog.vl_types.all;
entity V_SRB_CREG is
    generic(
        CP_IREGMUX      : string  := "BYX"
    );
    port(
        Y               : out    vl_logic;
        D               : in     vl_logic;
        CLK_N           : in     vl_logic;
        SET_N           : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CP_IREGMUX : constant is 1;
end V_SRB_CREG;
