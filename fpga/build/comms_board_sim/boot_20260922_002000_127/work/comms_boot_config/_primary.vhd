library verilog;
use verilog.vl_types.all;
entity comms_boot_config is
    generic(
        CLK_HZ          : integer := 125000000;
        BAUD            : integer := 115200
    );
    port(
        clk             : in     vl_logic;
        reset_n         : in     vl_logic;
        uart_rx         : in     vl_logic;
        mcu_tx          : in     vl_logic;
        uart_tx         : out    vl_logic;
        configured      : out    vl_logic;
        epoch           : out    vl_logic_vector(63 downto 0);
        src_mac         : out    vl_logic_vector(47 downto 0);
        dst_mac         : out    vl_logic_vector(47 downto 0);
        src_ip          : out    vl_logic_vector(31 downto 0);
        dst_ip          : out    vl_logic_vector(31 downto 0);
        src_port        : out    vl_logic_vector(15 downto 0);
        dst_port        : out    vl_logic_vector(15 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CLK_HZ : constant is 1;
    attribute mti_svvh_generic_type of BAUD : constant is 1;
end comms_boot_config;
