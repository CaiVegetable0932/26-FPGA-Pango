library verilog;
use verilog.vl_types.all;
entity raw8_capture is
    generic(
        WIDTH           : integer := 1920;
        HEIGHT          : integer := 1080;
        STRIDE          : integer := 2048;
        WARMUP_FRAMES   : integer := 10
    );
    port(
        clk             : in     vl_logic;
        reset_n         : in     vl_logic;
        configured      : in     vl_logic;
        arm             : in     vl_logic;
        vsync           : in     vl_logic;
        href            : in     vl_logic;
        data            : in     vl_logic_vector(7 downto 0);
        frame_start     : out    vl_logic;
        frame_id        : out    vl_logic_vector(63 downto 0);
        word_valid      : out    vl_logic;
        word_ready      : in     vl_logic;
        word_data       : out    vl_logic_vector(255 downto 0);
        word_offset     : out    vl_logic_vector(16 downto 0);
        result_valid    : out    vl_logic;
        result_ready    : in     vl_logic;
        result_good     : out    vl_logic;
        rejected_frames : out    vl_logic_vector(31 downto 0);
        overflow_frames : out    vl_logic_vector(31 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of WIDTH : constant is 1;
    attribute mti_svvh_generic_type of HEIGHT : constant is 1;
    attribute mti_svvh_generic_type of STRIDE : constant is 1;
    attribute mti_svvh_generic_type of WARMUP_FRAMES : constant is 1;
end raw8_capture;
