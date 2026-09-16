library verilog;
use verilog.vl_types.all;
entity reset_sync is
    generic(
        STAGES          : integer := 3
    );
    port(
        clk             : in     vl_logic;
        async_reset_n   : in     vl_logic;
        reset_n         : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of STAGES : constant is 1;
end reset_sync;
