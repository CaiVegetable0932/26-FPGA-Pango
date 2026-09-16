library verilog;
use verilog.vl_types.all;
entity V_OSERDES_E3 is
    generic(
        OSERDES_MODE    : string  := "DDR4TO1";
        LVDS_EN         : string  := "FALSE";
        LRS_TYPE        : string  := "ASYNC_RESET";
        DI_REG          : vl_logic := Hi1
    );
    port(
        RST_N           : in     vl_logic;
        OCLK            : in     vl_logic;
        OCLKDIV         : in     vl_logic;
        UPDATE          : in     vl_logic;
        DI              : in     vl_logic_vector(15 downto 0);
        TI              : in     vl_logic;
        DO              : out    vl_logic;
        TQ              : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of OSERDES_MODE : constant is 1;
    attribute mti_svvh_generic_type of LVDS_EN : constant is 1;
    attribute mti_svvh_generic_type of LRS_TYPE : constant is 1;
    attribute mti_svvh_generic_type of DI_REG : constant is 1;
end V_OSERDES_E3;
