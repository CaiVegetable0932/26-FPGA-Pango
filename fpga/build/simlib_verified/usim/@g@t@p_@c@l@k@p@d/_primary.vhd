library verilog;
use verilog.vl_types.all;
entity GTP_CLKPD is
    generic(
        CPD_EDGE        : string  := "POSEDGE";
        HPIO            : string  := "FALSE"
    );
    port(
        FLAG_PD         : out    vl_logic;
        LOCK            : out    vl_logic;
        RST             : in     vl_logic;
        CLK_SAMPLE      : in     vl_logic;
        CLK_CTRL        : in     vl_logic;
        CLK_PHY         : in     vl_logic;
        DONE            : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CPD_EDGE : constant is 1;
    attribute mti_svvh_generic_type of HPIO : constant is 1;
end GTP_CLKPD;
