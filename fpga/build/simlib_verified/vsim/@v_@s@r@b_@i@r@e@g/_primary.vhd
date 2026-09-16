library verilog;
use verilog.vl_types.all;
entity V_SRB_IREG is
    generic(
        CP_IREGMUX      : string  := "BYX";
        CP_FF_INIT      : vl_logic := Hi1
    );
    port(
        Y               : out    vl_logic;
        RS_MODE         : in     vl_logic;
        D               : in     vl_logic;
        CLK_N           : in     vl_logic;
        RST             : in     vl_logic;
        CE              : in     vl_logic;
        RST_N           : in     vl_logic;
        GRS_N           : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CP_IREGMUX : constant is 1;
    attribute mti_svvh_generic_type of CP_FF_INIT : constant is 1;
end V_SRB_IREG;
