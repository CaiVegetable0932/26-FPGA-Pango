library verilog;
use verilog.vl_types.all;
entity V_USCMCE is
    generic(
        CP_CK_INV       : vl_logic := Hi0;
        CP_EDGE         : vl_logic := Hi0;
        CP_EN_INV       : vl_logic := Hi0;
        CP_GLITCH       : vl_logic := Hi0;
        CP_HARDSYN      : vl_logic := Hi0
    );
    port(
        CLKIN           : in     vl_logic;
        EN_CLK          : in     vl_logic;
        CLKOUT          : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CP_CK_INV : constant is 1;
    attribute mti_svvh_generic_type of CP_EDGE : constant is 1;
    attribute mti_svvh_generic_type of CP_EN_INV : constant is 1;
    attribute mti_svvh_generic_type of CP_GLITCH : constant is 1;
    attribute mti_svvh_generic_type of CP_HARDSYN : constant is 1;
end V_USCMCE;
