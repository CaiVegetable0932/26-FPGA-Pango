library verilog;
use verilog.vl_types.all;
entity INT_ICG_AND is
    port(
        CLK_IN          : in     vl_logic;
        CLK_OUT         : out    vl_logic;
        CE              : in     vl_logic
    );
end INT_ICG_AND;
