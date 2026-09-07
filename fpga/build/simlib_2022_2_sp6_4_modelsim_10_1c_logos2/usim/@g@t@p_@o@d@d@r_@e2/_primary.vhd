library verilog;
use verilog.vl_types.all;
entity GTP_ODDR_E2 is
    generic(
        GRS_EN          : string  := "TRUE"
    );
    port(
        Q               : out    vl_logic;
        TQ              : out    vl_logic;
        D0              : in     vl_logic;
        D1              : in     vl_logic;
        T               : in     vl_logic;
        CLK             : in     vl_logic;
        RS              : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of GRS_EN : constant is 1;
end GTP_ODDR_E2;
