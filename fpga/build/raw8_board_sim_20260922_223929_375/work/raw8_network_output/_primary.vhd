library verilog;
use verilog.vl_types.all;
entity raw8_network_output is
    port(
        clk             : in     vl_logic;
        reset_n         : in     vl_logic;
        enable          : in     vl_logic;
        frame_start     : in     vl_logic;
        discard         : in     vl_logic;
        frame_ready     : out    vl_logic;
        source_idle     : out    vl_logic;
        stream_epoch    : in     vl_logic_vector(63 downto 0);
        frame_id        : in     vl_logic_vector(63 downto 0);
        descriptor_id   : in     vl_logic_vector(31 downto 0);
        param_version   : in     vl_logic_vector(31 downto 0);
        word_data       : in     vl_logic_vector(255 downto 0);
        word_valid      : in     vl_logic;
        word_ready      : out    vl_logic;
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
        mac_busy        : out    vl_logic;
        error_code      : out    vl_logic_vector(3 downto 0)
    );
end raw8_network_output;
