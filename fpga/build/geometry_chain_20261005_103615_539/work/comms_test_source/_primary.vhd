library verilog;
use verilog.vl_types.all;
entity comms_test_source is
    generic(
        WIDTH           : integer := 1920;
        HEIGHT          : integer := 1080;
        PERIOD          : integer := 4166667
    );
    port(
        clk             : in     vl_logic;
        reset_n         : in     vl_logic;
        enable          : in     vl_logic;
        frame_ready     : in     vl_logic;
        pixel_ready     : in     vl_logic;
        frame_done      : in     vl_logic;
        frame_error     : in     vl_logic;
        frame_start     : out    vl_logic;
        pixel_valid     : out    vl_logic;
        pixel_last      : out    vl_logic;
        pixel_data      : out    vl_logic_vector(7 downto 0);
        frame_id        : out    vl_logic_vector(63 downto 0);
        fault           : out    vl_logic;
        frames_done     : out    vl_logic_vector(31 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of WIDTH : constant is 1;
    attribute mti_svvh_generic_type of HEIGHT : constant is 1;
    attribute mti_svvh_generic_type of PERIOD : constant is 1;
end comms_test_source;
