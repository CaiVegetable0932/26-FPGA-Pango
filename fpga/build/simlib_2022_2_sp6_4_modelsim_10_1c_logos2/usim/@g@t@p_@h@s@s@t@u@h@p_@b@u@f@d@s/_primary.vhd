library verilog;
use verilog.vl_types.all;
entity GTP_HSSTUHP_BUFDS is
    port(
        PAD_REFCLKP     : in     vl_logic;
        PAD_REFCLKN     : in     vl_logic;
        P_REF_LS_ENA    : in     vl_logic;
        OCK_COMMON_REF  : out    vl_logic;
        P_REFCLK2CORE   : out    vl_logic
    );
end GTP_HSSTUHP_BUFDS;
