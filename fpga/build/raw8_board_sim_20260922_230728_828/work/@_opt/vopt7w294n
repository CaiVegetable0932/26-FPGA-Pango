library verilog;
use verilog.vl_types.all;
entity raw8_frame_pool is
    port(
        clk             : in     vl_logic;
        reset_n         : in     vl_logic;
        capture_request : in     vl_logic;
        capture_grant   : out    vl_logic;
        capture_slot    : out    vl_logic_vector(1 downto 0);
        capture_base    : out    vl_logic_vector(27 downto 0);
        capture_commit  : in     vl_logic;
        capture_good    : in     vl_logic;
        capture_drained : in     vl_logic;
        captured_id     : in     vl_logic_vector(63 downto 0);
        captured_epoch  : in     vl_logic_vector(63 downto 0);
        hdmi_request    : in     vl_logic;
        hdmi_release    : in     vl_logic;
        hdmi_grant      : out    vl_logic;
        hdmi_locked     : out    vl_logic;
        hdmi_slot       : out    vl_logic_vector(1 downto 0);
        hdmi_id         : out    vl_logic_vector(63 downto 0);
        hdmi_epoch      : out    vl_logic_vector(63 downto 0);
        net_request     : in     vl_logic;
        net_release     : in     vl_logic;
        net_grant       : out    vl_logic;
        net_locked      : out    vl_logic;
        net_slot        : out    vl_logic_vector(1 downto 0);
        net_id          : out    vl_logic_vector(63 downto 0);
        net_epoch       : out    vl_logic_vector(63 downto 0);
        published       : out    vl_logic_vector(31 downto 0);
        dropped         : out    vl_logic_vector(31 downto 0);
        protocol_error  : out    vl_logic
    );
end raw8_frame_pool;
