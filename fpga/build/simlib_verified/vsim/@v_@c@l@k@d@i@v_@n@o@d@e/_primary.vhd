library verilog;
use verilog.vl_types.all;
entity V_CLKDIV_NODE is
    generic(
        DIV_FACTOR      : string  := "1"
    );
    port(
        CLKOUT          : out    vl_logic;
        CLKIN           : in     vl_logic;
        CLR_N           : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of DIV_FACTOR : constant is 1;
end V_CLKDIV_NODE;
