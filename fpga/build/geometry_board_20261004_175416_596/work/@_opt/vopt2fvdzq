library verilog;
use verilog.vl_types.all;
entity raw8_dvp_monitor is
    generic(
        POLL_BITS       : integer := 20
    );
    port(
        cam_clk         : in     vl_logic;
        cam_reset_n     : in     vl_logic;
        mem_clk         : in     vl_logic;
        mem_reset_n     : in     vl_logic;
        vsync           : in     vl_logic;
        href            : in     vl_logic;
        capture_state   : in     vl_logic_vector(7 downto 0);
        rejected        : in     vl_logic_vector(31 downto 0);
        overflows       : in     vl_logic_vector(31 downto 0);
        geometry        : out    vl_logic_vector(95 downto 0);
        progress        : out    vl_logic_vector(95 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of POLL_BITS : constant is 1;
end raw8_dvp_monitor;
