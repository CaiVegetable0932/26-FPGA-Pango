library verilog;
use verilog.vl_types.all;
entity sync_vg is
    generic(
        X_BITS          : integer := 12;
        Y_BITS          : integer := 12;
        V_TOTAL         : vl_logic_vector(0 to 11) := (Hi0, Hi0, Hi1, Hi0, Hi1, Hi1, Hi1, Hi0, Hi1, Hi1, Hi1, Hi0);
        V_FP            : vl_logic_vector(0 to 11) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi1, Hi0, Hi1);
        V_BP            : vl_logic_vector(0 to 11) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi1, Hi0, Hi1, Hi0, Hi0);
        V_SYNC          : vl_logic_vector(0 to 11) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi1, Hi0, Hi1);
        V_ACT           : vl_logic_vector(0 to 11) := (Hi0, Hi0, Hi1, Hi0, Hi1, Hi1, Hi0, Hi1, Hi0, Hi0, Hi0, Hi0);
        H_TOTAL         : vl_logic_vector(0 to 11) := (Hi0, Hi1, Hi1, Hi0, Hi0, Hi1, Hi1, Hi1, Hi0, Hi0, Hi1, Hi0);
        H_FP            : vl_logic_vector(0 to 11) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi1, Hi1, Hi0, Hi1, Hi1, Hi1, Hi0);
        H_BP            : vl_logic_vector(0 to 11) := (Hi0, Hi0, Hi0, Hi0, Hi1, Hi1, Hi0, Hi1, Hi1, Hi1, Hi0, Hi0);
        H_SYNC          : vl_logic_vector(0 to 11) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi1, Hi0, Hi1, Hi0, Hi0, Hi0);
        H_ACT           : vl_logic_vector(0 to 11) := (Hi0, Hi1, Hi0, Hi1, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0);
        HV_OFFSET       : vl_logic_vector(0 to 11) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0)
    );
    port(
        clk             : in     vl_logic;
        rstn            : in     vl_logic;
        vs_out          : out    vl_logic;
        hs_out          : out    vl_logic;
        de_out          : out    vl_logic;
        de_re           : out    vl_logic;
        x_act           : out    vl_logic_vector;
        y_act           : out    vl_logic_vector
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of X_BITS : constant is 1;
    attribute mti_svvh_generic_type of Y_BITS : constant is 1;
    attribute mti_svvh_generic_type of V_TOTAL : constant is 1;
    attribute mti_svvh_generic_type of V_FP : constant is 1;
    attribute mti_svvh_generic_type of V_BP : constant is 1;
    attribute mti_svvh_generic_type of V_SYNC : constant is 1;
    attribute mti_svvh_generic_type of V_ACT : constant is 1;
    attribute mti_svvh_generic_type of H_TOTAL : constant is 1;
    attribute mti_svvh_generic_type of H_FP : constant is 1;
    attribute mti_svvh_generic_type of H_BP : constant is 1;
    attribute mti_svvh_generic_type of H_SYNC : constant is 1;
    attribute mti_svvh_generic_type of H_ACT : constant is 1;
    attribute mti_svvh_generic_type of HV_OFFSET : constant is 1;
end sync_vg;
