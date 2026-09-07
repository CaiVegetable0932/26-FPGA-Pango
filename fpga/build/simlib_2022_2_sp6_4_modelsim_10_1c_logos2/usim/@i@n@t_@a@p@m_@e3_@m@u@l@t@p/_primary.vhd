library verilog;
use verilog.vl_types.all;
entity INT_APM_E3_MULTP is
    generic(
        a_width         : integer := 8;
        b_width         : integer := 8;
        out_width       : integer := 18;
        verif_en        : integer := 1
    );
    port(
        a               : in     vl_logic_vector;
        b               : in     vl_logic_vector;
        tc              : in     vl_logic;
        out0            : out    vl_logic_vector;
        out1            : out    vl_logic_vector
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of a_width : constant is 2;
    attribute mti_svvh_generic_type of b_width : constant is 2;
    attribute mti_svvh_generic_type of out_width : constant is 2;
    attribute mti_svvh_generic_type of verif_en : constant is 2;
end INT_APM_E3_MULTP;
