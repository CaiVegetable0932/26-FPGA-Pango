library verilog;
use verilog.vl_types.all;
entity V_IO_ODDR is
    generic(
        CP_CLK_INV      : string  := "FALSE";
        CP_DDR_MODE     : string  := "SDR";
        CP_RST_INV      : string  := "FALSE";
        CP_INIT         : vl_logic := Hi0;
        CP_BYPASS       : string  := "TRUE";
        SET_MODE        : string  := "ASYNC_RST"
    );
    port(
        CLK             : in     vl_logic;
        D0              : in     vl_logic;
        D1              : in     vl_logic;
        RST             : in     vl_logic;
        CE              : in     vl_logic;
        Q               : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CP_CLK_INV : constant is 1;
    attribute mti_svvh_generic_type of CP_DDR_MODE : constant is 1;
    attribute mti_svvh_generic_type of CP_RST_INV : constant is 1;
    attribute mti_svvh_generic_type of CP_INIT : constant is 1;
    attribute mti_svvh_generic_type of CP_BYPASS : constant is 1;
    attribute mti_svvh_generic_type of SET_MODE : constant is 1;
end V_IO_ODDR;
