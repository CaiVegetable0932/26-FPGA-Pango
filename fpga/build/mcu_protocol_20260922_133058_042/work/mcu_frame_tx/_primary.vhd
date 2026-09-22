library verilog;
use verilog.vl_types.all;
entity mcu_frame_tx is
    generic(
        CLK_HZ          : integer := 27000000;
        BAUD            : integer := 115200
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        flush           : in     vl_logic;
        valid           : in     vl_logic;
        ready           : out    vl_logic;
        command         : in     vl_logic_vector(7 downto 0);
        sequence_id     : in     vl_logic_vector(15 downto 0);
        payload         : in     vl_logic_vector(255 downto 0);
        serial_tx       : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CLK_HZ : constant is 2;
    attribute mti_svvh_generic_type of BAUD : constant is 2;
end mcu_frame_tx;
