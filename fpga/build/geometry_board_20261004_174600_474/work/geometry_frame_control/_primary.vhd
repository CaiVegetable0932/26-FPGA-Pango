library verilog;
use verilog.vl_types.all;
entity geometry_frame_control is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        frame_start     : in     vl_logic;
        config_valid    : in     vl_logic;
        config_words    : in     vl_logic_vector(447 downto 0);
        config_version  : in     vl_logic_vector(31 downto 0);
        config_accepted : out    vl_logic;
        config_rejected : out    vl_logic;
        active_config_valid: out    vl_logic;
        active_words    : out    vl_logic_vector(447 downto 0);
        active_version  : out    vl_logic_vector(31 downto 0);
        env_valid       : in     vl_logic;
        env_measurement_valid: in     vl_logic_vector(1 downto 0);
        env_angle_mdeg  : in     vl_logic_vector(31 downto 0);
        env_epoch       : in     vl_logic_vector(63 downto 0);
        env_board_time_us: in     vl_logic_vector(63 downto 0);
        env_session_id  : in     vl_logic_vector(31 downto 0);
        env_event_seq   : in     vl_logic_vector(31 downto 0);
        mcu_context_valid: in     vl_logic;
        mcu_epoch       : in     vl_logic_vector(63 downto 0);
        mcu_session_id  : in     vl_logic_vector(31 downto 0);
        active_angle_valid: out    vl_logic;
        active_angle_mdeg: out    vl_logic_vector(31 downto 0);
        active_angle_epoch: out    vl_logic_vector(63 downto 0);
        active_angle_board_time_us: out    vl_logic_vector(63 downto 0);
        active_angle_session_id: out    vl_logic_vector(31 downto 0);
        active_angle_event_seq: out    vl_logic_vector(31 downto 0)
    );
end geometry_frame_control;
