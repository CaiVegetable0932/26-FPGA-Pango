library verilog;
use verilog.vl_types.all;
entity comms_pll is
    port(
        clkout0         : out    vl_logic;
        clkout1         : out    vl_logic;
        clkin1          : in     vl_logic;
        rst             : in     vl_logic;
        lock            : out    vl_logic
    );
end comms_pll;
