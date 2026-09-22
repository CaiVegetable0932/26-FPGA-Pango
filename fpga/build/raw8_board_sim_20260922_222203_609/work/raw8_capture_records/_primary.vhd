library verilog;
use verilog.vl_types.all;
entity raw8_capture_records is
    generic(
        WARMUP_FRAMES   : integer := 10
    );
    port(
        cam_clk         : in     vl_logic;
        cam_reset_n     : in     vl_logic;
        configured      : in     vl_logic;
        lease_valid     : in     vl_logic;
        vsync           : in     vl_logic;
        href            : in     vl_logic;
        data            : in     vl_logic_vector(7 downto 0);
        lease_ack       : out    vl_logic;
        record_data     : out    vl_logic_vector(287 downto 0);
        record_valid    : out    vl_logic;
        record_ready    : in     vl_logic;
        rejected        : out    vl_logic_vector(31 downto 0);
        overflows       : out    vl_logic_vector(31 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of WARMUP_FRAMES : constant is 1;
end raw8_capture_records;
