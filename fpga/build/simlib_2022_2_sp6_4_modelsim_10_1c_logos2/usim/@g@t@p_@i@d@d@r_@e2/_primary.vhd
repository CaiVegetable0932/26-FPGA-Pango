library verilog;
use verilog.vl_types.all;
entity GTP_IDDR_E2 is
    generic(
        GRS_EN          : string  := "TRUE"
    );
    port(
        Q0              : out    vl_logic;
        Q1              : out    vl_logic;
        D               : in     vl_logic;
        RS              : in     vl_logic;
        CLK             : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of GRS_EN : constant is 1;
end GTP_IDDR_E2;
