library verilog;
use verilog.vl_types.all;
entity V_MFG_DFT is
    generic(
        OUTEN_N         : vl_logic := Hi1;
        ATEST_EN        : string  := "FALSE";
        TEST_PATH_SEL   : vl_logic := Hi0
    );
    port(
        CLK_USER_O      : out    vl_logic;
        ATP_O           : out    vl_logic;
        MFG_TEST_SEL_I  : in     vl_logic_vector(3 downto 0);
        PLL_LDO_I       : in     vl_logic_vector(7 downto 0);
        CLK_USER_I      : in     vl_logic;
        CLK_ADC_I       : in     vl_logic;
        CLK_MSPI_I      : in     vl_logic;
        CLK_BLSHFT_I    : in     vl_logic;
        ADC_VREF_I      : in     vl_logic;
        DDR_VREF_I      : in     vl_logic;
        CMFB_VREF_I     : in     vl_logic;
        POR_N_I         : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of OUTEN_N : constant is 1;
    attribute mti_svvh_generic_type of ATEST_EN : constant is 1;
    attribute mti_svvh_generic_type of TEST_PATH_SEL : constant is 1;
end V_MFG_DFT;
