library verilog;
use verilog.vl_types.all;
entity GTP_ISERDES_E3 is
    generic(
        ISERDES_MODE    : string  := "DDR1TO4";
        LRS_TYPE        : string  := "ASYNC_RESET";
        DO_REG          : vl_logic := Hi1;
        LVDS_EN         : string  := "FALSE"
    );
    port(
        RST_N           : in     vl_logic;
        ICLK            : in     vl_logic;
        ICLKDIV         : in     vl_logic;
        DI              : in     vl_logic;
        DO              : out    vl_logic_vector(15 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of ISERDES_MODE : constant is 1;
    attribute mti_svvh_generic_type of LRS_TYPE : constant is 1;
    attribute mti_svvh_generic_type of DO_REG : constant is 1;
    attribute mti_svvh_generic_type of LVDS_EN : constant is 1;
end GTP_ISERDES_E3;
