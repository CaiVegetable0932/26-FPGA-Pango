library verilog;
use verilog.vl_types.all;
entity GTP_BUFGS is
    port(
        Z               : out    vl_logic;
        I               : in     vl_logic
    );
end GTP_BUFGS;
