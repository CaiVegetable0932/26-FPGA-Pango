library verilog;
use verilog.vl_types.all;
entity mcu_frame_rx is
    generic(
        CLK_HZ          : integer := 27000000;
        RX_TIMEOUT_MS   : integer := 20
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        flush           : in     vl_logic;
        byte_data       : in     vl_logic_vector(7 downto 0);
        byte_valid      : in     vl_logic;
        framing_error   : in     vl_logic;
        done            : out    vl_logic;
        reply_allowed   : out    vl_logic;
        error_code      : out    vl_logic_vector(7 downto 0);
        command         : out    vl_logic_vector(7 downto 0);
        sequence_id     : out    vl_logic_vector(15 downto 0);
        length          : out    vl_logic_vector(15 downto 0);
        payload         : out    vl_logic_vector(255 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CLK_HZ : constant is 2;
    attribute mti_svvh_generic_type of RX_TIMEOUT_MS : constant is 2;
end mcu_frame_rx;
