library verilog;
use verilog.vl_types.all;
entity GTP_SYNC is
    generic(
        INIT            : vl_logic := Hi0;
        SYNC_REG        : integer := 2;
        CLK_INV         : vl_logic := Hi0
    );
    port(
        Q               : out    vl_logic;
        CLK             : in     vl_logic;
        D               : in     vl_logic;
        RST_N           : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of INIT : constant is 1;
    attribute mti_svvh_generic_type of SYNC_REG : constant is 1;
    attribute mti_svvh_generic_type of CLK_INV : constant is 1;
end GTP_SYNC;
