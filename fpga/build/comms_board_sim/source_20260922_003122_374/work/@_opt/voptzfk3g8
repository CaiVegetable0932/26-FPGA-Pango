library verilog;
use verilog.vl_types.all;
entity video_network_tx is
    generic(
        MAX_FRAME_BYTES : integer := 8388608;
        INPUT_TIMEOUT   : integer := 1250000
    );
    port(
        clk             : in     vl_logic;
        reset_n         : in     vl_logic;
        enable          : in     vl_logic;
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
        src_mac         : in     vl_logic_vector(47 downto 0);
        dst_mac         : in     vl_logic_vector(47 downto 0);
        src_ip          : in     vl_logic_vector(31 downto 0);
        dst_ip          : in     vl_logic_vector(31 downto 0);
        src_port        : in     vl_logic_vector(15 downto 0);
        dst_port        : in     vl_logic_vector(15 downto 0);
        gmii_txd        : out    vl_logic_vector(7 downto 0);
        gmii_tx_en      : out    vl_logic;
        gmii_tx_er      : out    vl_logic;
        frame_done      : out    vl_logic;
        frame_error     : out    vl_logic;
        error_code      : out    vl_logic_vector(3 downto 0);
        mac_busy        : out    vl_logic;
        mac_done        : out    vl_logic;
        mac_error       : out    vl_logic;
        packets_queued  : out    vl_logic_vector(31 downto 0);
        packets_sent    : out    vl_logic_vector(31 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of MAX_FRAME_BYTES : constant is 1;
    attribute mti_svvh_generic_type of INPUT_TIMEOUT : constant is 1;
end video_network_tx;
