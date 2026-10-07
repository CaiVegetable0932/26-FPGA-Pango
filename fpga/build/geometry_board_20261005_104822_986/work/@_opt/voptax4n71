library verilog;
use verilog.vl_types.all;
entity udp_ipv4_eth_tx is
    generic(
        RX_TIMEOUT_CYCLES: integer := 125000
    );
    port(
        clk             : in     vl_logic;
        reset_n         : in     vl_logic;
        datagram_start  : in     vl_logic;
        datagram_ready  : out    vl_logic;
        udp_payload_length: in     vl_logic_vector(15 downto 0);
        src_mac         : in     vl_logic_vector(47 downto 0);
        dst_mac         : in     vl_logic_vector(47 downto 0);
        src_ip          : in     vl_logic_vector(31 downto 0);
        dst_ip          : in     vl_logic_vector(31 downto 0);
        src_port        : in     vl_logic_vector(15 downto 0);
        dst_port        : in     vl_logic_vector(15 downto 0);
        payload_valid   : in     vl_logic;
        payload_ready   : out    vl_logic;
        payload_data    : in     vl_logic_vector(7 downto 0);
        gmii_txd        : out    vl_logic_vector(7 downto 0);
        gmii_tx_en      : out    vl_logic;
        gmii_tx_er      : out    vl_logic;
        busy            : out    vl_logic;
        done            : out    vl_logic;
        error           : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of RX_TIMEOUT_CYCLES : constant is 2;
end udp_ipv4_eth_tx;
