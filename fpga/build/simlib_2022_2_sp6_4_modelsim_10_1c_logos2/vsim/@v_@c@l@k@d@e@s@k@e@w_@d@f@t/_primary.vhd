library verilog;
use verilog.vl_types.all;
entity V_CLKDESKEW_DFT is
    port(
        CLK             : in     vl_logic;
        TEST_CLK        : in     vl_logic;
        TEST_MODE_N     : in     vl_logic;
        TEST_SE_N       : in     vl_logic;
        TEST_RST_N      : in     vl_logic;
        TEST_SI_0       : in     vl_logic;
        TEST_SO_0       : out    vl_logic;
        TEST_SI_1       : in     vl_logic;
        TEST_SO_1       : out    vl_logic;
        PLL_BYPASS      : in     vl_logic;
        OCC_RST_N       : in     vl_logic;
        OCC_SI          : in     vl_logic;
        OCC_SO          : out    vl_logic
    );
end V_CLKDESKEW_DFT;
