library verilog;
use verilog.vl_types.all;
entity geometry_config_bank is
    generic(
        WIDTH           : integer := 1920;
        HEIGHT          : integer := 1080
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        context_valid   : in     vl_logic;
        epoch           : in     vl_logic_vector(63 downto 0);
        session_id      : in     vl_logic_vector(31 downto 0);
        cmd_valid       : in     vl_logic;
        cmd             : in     vl_logic_vector(7 downto 0);
        payload         : in     vl_logic_vector(255 downto 0);
        code            : out    vl_logic_vector(7 downto 0);
        reply           : out    vl_logic_vector(95 downto 0);
        frame_start     : in     vl_logic;
        source_frame_id : in     vl_logic_vector(63 downto 0);
        active_words    : out    vl_logic_vector(447 downto 0);
        active_model    : out    vl_logic_vector(1 downto 0);
        active_enhance  : out    vl_logic;
        active_bank     : out    vl_logic;
        active_version  : out    vl_logic_vector(31 downto 0);
        applied_frame_id: out    vl_logic_vector(63 downto 0);
        build_busy      : out    vl_logic;
        build_failed    : out    vl_logic;
        pending         : out    vl_logic;
        build_start     : out    vl_logic;
        build_bank      : out    vl_logic;
        build_model     : out    vl_logic_vector(1 downto 0);
        k1              : out    vl_logic_vector(31 downto 0);
        k2              : out    vl_logic_vector(31 downto 0);
        k3              : out    vl_logic_vector(31 downto 0);
        k4              : out    vl_logic_vector(31 downto 0);
        build_done      : in     vl_logic;
        lut_failed      : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of WIDTH : constant is 1;
    attribute mti_svvh_generic_type of HEIGHT : constant is 1;
end geometry_config_bank;
