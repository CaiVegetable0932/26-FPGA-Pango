library verilog;
use verilog.vl_types.all;
entity flow_smoke_top is
    port(
        clk             : in     vl_logic;
        key             : in     vl_logic;
        rstn            : in     vl_logic;
        led0            : out    vl_logic
    );
end flow_smoke_top;
