library verilog;
use verilog.vl_types.all;
entity V_LUT6AE is
    generic(
        CP_INIT         : vl_logic_vector(63 downto 0) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0);
        CP_O5O6MUX2     : string  := "I5";
        CP_CASMUX4_0    : string  := "I4";
        CP_CASMUX4_1    : string  := "I4"
    );
    port(
        O5_0            : out    vl_logic;
        O5_1            : out    vl_logic;
        L6              : out    vl_logic;
        PROP            : out    vl_logic;
        GEN             : out    vl_logic;
        LCASOUT         : out    vl_logic;
        CCAS_IN         : in     vl_logic;
        LCASIN          : in     vl_logic;
        A0              : in     vl_logic;
        A1              : in     vl_logic;
        A2              : in     vl_logic;
        A3              : in     vl_logic;
        A4              : in     vl_logic;
        A5              : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CP_INIT : constant is 2;
    attribute mti_svvh_generic_type of CP_O5O6MUX2 : constant is 1;
    attribute mti_svvh_generic_type of CP_CASMUX4_0 : constant is 1;
    attribute mti_svvh_generic_type of CP_CASMUX4_1 : constant is 1;
end V_LUT6AE;
