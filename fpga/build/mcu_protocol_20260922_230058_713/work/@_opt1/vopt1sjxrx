library verilog;
use verilog.vl_types.all;
entity mcu_uart_tx is
    generic(
        CLK_HZ          : integer := 27000000;
        BAUD            : integer := 115200
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        flush           : in     vl_logic;
        data            : in     vl_logic_vector(7 downto 0);
        valid           : in     vl_logic;
        ready           : out    vl_logic;
        serial_tx       : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CLK_HZ : constant is 2;
    attribute mti_svvh_generic_type of BAUD : constant is 2;
end mcu_uart_tx;
