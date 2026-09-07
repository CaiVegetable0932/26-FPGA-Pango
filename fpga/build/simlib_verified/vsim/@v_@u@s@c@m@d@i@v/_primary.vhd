library verilog;
use verilog.vl_types.all;
entity V_USCMDIV is
    generic(
        CP_EN_INV       : vl_logic := Hi0;
        CP_CK_INV       : vl_logic := Hi0;
        CP_CLR_INV      : vl_logic := Hi0;
        CP_DIV          : vl_logic_vector(0 to 2) := (Hi0, Hi0, Hi0)
    );
    port(
        CLR             : in     vl_logic;
        CLKIN           : in     vl_logic;
        EN_CLK          : in     vl_logic;
        CLKOUT          : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CP_EN_INV : constant is 1;
    attribute mti_svvh_generic_type of CP_CK_INV : constant is 1;
    attribute mti_svvh_generic_type of CP_CLR_INV : constant is 1;
    attribute mti_svvh_generic_type of CP_DIV : constant is 1;
end V_USCMDIV;
