library verilog;
use verilog.vl_types.all;
entity V_POWERCTL is
    port(
        CLK             : in     vl_logic;
        STDBY_EN_N      : in     vl_logic;
        TIMER_EN_N      : in     vl_logic;
        CLR_N           : in     vl_logic;
        STOP            : out    vl_logic;
        STDBY           : out    vl_logic;
        STDBY_FLG       : out    vl_logic
    );
end V_POWERCTL;
