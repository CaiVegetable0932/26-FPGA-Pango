library verilog;
use verilog.vl_types.all;
entity V_CLKBUFGMUX_E3 is
    generic(
        SEL_INV         : string  := "FALSE"
    );
    port(
        CLKOUT          : out    vl_logic;
        CLKIN0          : in     vl_logic;
        CLKIN1          : in     vl_logic;
        SEL             : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of SEL_INV : constant is 1;
end V_CLKBUFGMUX_E3;
