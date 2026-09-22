library verilog;
use verilog.vl_types.all;
entity praw_packetizer is
    generic(
        MAX_FRAME_BYTES : integer := 8388608;
        INPUT_TIMEOUT   : integer := 1250000
    );
    port(
        clk             : in     vl_logic;
        reset_n         : in     vl_logic;
        frame_start     : in     vl_logic;
        frame_ready     : out    vl_logic;
        stream_epoch    : in     vl_logic_vector(63 downto 0);
        frame_id        : in     vl_logic_vector(63 downto 0);
        param_version   : in     vl_logic_vector(31 downto 0);
        descriptor_id   : in     vl_logic_vector(31 downto 0);
        width           : in     vl_logic_vector(15 downto 0);
        height          : in     vl_logic_vector(15 downto 0);
        packet_type     : in     vl_logic_vector(7 downto 0);
        bayer_code      : in     vl_logic_vector(7 downto 0);
        pixel_valid     : in     vl_logic;
        pixel_last      : in     vl_logic;
        pixel_data      : in     vl_logic_vector(7 downto 0);
        pixel_ready     : out    vl_logic;
        datagram_start  : out    vl_logic;
        datagram_ready  : in     vl_logic;
        datagram_length : out    vl_logic_vector(15 downto 0);
        payload_valid   : out    vl_logic;
        payload_ready   : in     vl_logic;
        payload_data    : out    vl_logic_vector(7 downto 0);
        frame_done      : out    vl_logic;
        frame_error     : out    vl_logic;
        error_code      : out    vl_logic_vector(3 downto 0);
        packets_emitted : out    vl_logic_vector(31 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of MAX_FRAME_BYTES : constant is 1;
    attribute mti_svvh_generic_type of INPUT_TIMEOUT : constant is 1;
end praw_packetizer;
