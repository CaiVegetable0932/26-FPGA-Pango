library verilog;
use verilog.vl_types.all;
entity V_IO_IDDR is
    generic(
        CLK_INV         : string  := "FALSE";
        DDR_MODE        : string  := "SDR";
        RST_INV         : string  := "FALSE";
        INIT            : vl_logic := Hi0;
        BYPASS          : string  := "TRUE";
        SET_MODE        : string  := "ASYNC_RST"
    );
    port(
        CLK             : in     vl_logic;
        D               : in     vl_logic;
        RST             : in     vl_logic;
        CE              : in     vl_logic;
        Q0              : out    vl_logic;
        Q1              : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CLK_INV : constant is 1;
    attribute mti_svvh_generic_type of DDR_MODE : constant is 1;
    attribute mti_svvh_generic_type of RST_INV : constant is 1;
    attribute mti_svvh_generic_type of INIT : constant is 1;
    attribute mti_svvh_generic_type of BYPASS : constant is 1;
    attribute mti_svvh_generic_type of SET_MODE : constant is 1;
end V_IO_IDDR;
