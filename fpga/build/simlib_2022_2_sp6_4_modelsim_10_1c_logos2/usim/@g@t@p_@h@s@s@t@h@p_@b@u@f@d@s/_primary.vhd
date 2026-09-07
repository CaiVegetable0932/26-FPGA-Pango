library verilog;
use verilog.vl_types.all;
entity GTP_HSSTHP_BUFDS is
    generic(
        PMA_CFG_COMMPOWERUP: string  := "ON";
        PMA_REG_COM_PD  : string  := "FALSE";
        PMA_REG_COM_PD_OW: string  := "FALSE";
        PMA_REG_HPLL_REFCLK_PD: string  := "ON";
        PMA_REG_REFCLK_FAB: string  := "REFCLK"
    );
    port(
        COM_POWERDOWN   : in     vl_logic;
        PAD_REFCLKP     : in     vl_logic;
        PAD_REFCLKN     : in     vl_logic;
        REFCLK_OUTP     : out    vl_logic;
        PMA_REFCLK_TO_FABRIC: out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of PMA_CFG_COMMPOWERUP : constant is 1;
    attribute mti_svvh_generic_type of PMA_REG_COM_PD : constant is 1;
    attribute mti_svvh_generic_type of PMA_REG_COM_PD_OW : constant is 1;
    attribute mti_svvh_generic_type of PMA_REG_HPLL_REFCLK_PD : constant is 1;
    attribute mti_svvh_generic_type of PMA_REG_REFCLK_FAB : constant is 1;
end GTP_HSSTHP_BUFDS;
