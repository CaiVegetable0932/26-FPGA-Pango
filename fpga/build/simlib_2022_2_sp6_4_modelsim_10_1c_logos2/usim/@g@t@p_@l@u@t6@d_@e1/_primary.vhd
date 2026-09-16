library verilog;
use verilog.vl_types.all;
entity GTP_LUT6D_E1 is
    generic(
        INIT            : vl_logic_vector(63 downto 0) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0);
        MUX2LUT50_SEL   : string  := "I4";
        MUX2LUT51_SEL   : string  := "I4";
        MUX2LUT6_SEL    : string  := "I5"
    );
    port(
        Z               : out    vl_logic;
        Z5              : out    vl_logic;
        I0              : in     vl_logic;
        I1              : in     vl_logic;
        I2              : in     vl_logic;
        I3              : in     vl_logic;
        I4              : in     vl_logic;
        I5              : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of INIT : constant is 2;
    attribute mti_svvh_generic_type of MUX2LUT50_SEL : constant is 1;
    attribute mti_svvh_generic_type of MUX2LUT51_SEL : constant is 1;
    attribute mti_svvh_generic_type of MUX2LUT6_SEL : constant is 1;
end GTP_LUT6D_E1;
