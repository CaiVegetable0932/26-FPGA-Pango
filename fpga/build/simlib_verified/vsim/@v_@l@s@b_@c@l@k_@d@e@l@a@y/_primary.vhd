library verilog;
use verilog.vl_types.all;
entity V_LSB_CLK_DELAY is
    generic(
        CP_TW           : integer := 100;
        CP_EN           : vl_logic := Hi0;
        CP_SEL1         : vl_logic := Hi0;
        CP_SEL0         : vl_logic := Hi0
    );
    port(
        \IN\            : in     vl_logic;
        \OUT\           : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CP_TW : constant is 1;
    attribute mti_svvh_generic_type of CP_EN : constant is 1;
    attribute mti_svvh_generic_type of CP_SEL1 : constant is 1;
    attribute mti_svvh_generic_type of CP_SEL0 : constant is 1;
end V_LSB_CLK_DELAY;
