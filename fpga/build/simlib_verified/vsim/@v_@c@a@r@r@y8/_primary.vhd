library verilog;
use verilog.vl_types.all;
entity V_CARRY8 is
    generic(
        CP_CLA4_INIT_BOT: string  := "LOW";
        CP_CLA4_INIT_TOP: string  := "LOW"
    );
    port(
        COUT            : out    vl_logic_vector(7 downto 0);
        CLA7_COUT       : out    vl_logic;
        CLA4_CIN_TOP    : out    vl_logic;
        CLA4_CIN_BOT    : out    vl_logic;
        PROP            : in     vl_logic_vector(7 downto 0);
        GEN             : in     vl_logic_vector(7 downto 0);
        CCAS_IN         : in     vl_logic;
        BYP_BOT         : in     vl_logic;
        BYP_TOP         : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CP_CLA4_INIT_BOT : constant is 1;
    attribute mti_svvh_generic_type of CP_CLA4_INIT_TOP : constant is 1;
end V_CARRY8;
