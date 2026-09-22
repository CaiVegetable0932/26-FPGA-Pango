library verilog;
use verilog.vl_types.all;
entity mcu_protocol is
    generic(
        CLK_HZ          : integer := 27000000;
        BAUD            : integer := 115200;
        RX_TIMEOUT_MS   : integer := 20
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        uart_rx         : in     vl_logic;
        uart_tx         : out    vl_logic;
        link_epoch      : in     vl_logic_vector(63 downto 0);
        link_epoch_valid: in     vl_logic;
        board_time_us   : in     vl_logic_vector(63 downto 0);
        status_flags    : in     vl_logic_vector(31 downto 0);
        session_active  : out    vl_logic;
        env_valid       : out    vl_logic;
        env_session_id  : out    vl_logic_vector(31 downto 0);
        env_event_seq   : out    vl_logic_vector(31 downto 0);
        env_mcu_time_us : out    vl_logic_vector(31 downto 0);
        env_board_time_us: out    vl_logic_vector(63 downto 0);
        env_lux_milli   : out    vl_logic_vector(31 downto 0);
        env_angle_mdeg  : out    vl_logic_vector(31 downto 0);
        env_measurement_valid: out    vl_logic_vector(1 downto 0);
        rx_good_count   : out    vl_logic_vector(31 downto 0);
        rx_error_count  : out    vl_logic_vector(31 downto 0);
        tx_overflow_count: out    vl_logic_vector(31 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CLK_HZ : constant is 2;
    attribute mti_svvh_generic_type of BAUD : constant is 2;
    attribute mti_svvh_generic_type of RX_TIMEOUT_MS : constant is 2;
end mcu_protocol;
