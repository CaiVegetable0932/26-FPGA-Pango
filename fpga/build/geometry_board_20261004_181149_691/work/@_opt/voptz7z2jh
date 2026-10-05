library verilog;
use verilog.vl_types.all;
entity geometry_gray_processor is
    generic(
        WIDTH           : integer := 1920;
        HEIGHT          : integer := 1080;
        STRIDE          : integer := 2048
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        start           : in     vl_logic;
        source_base     : in     vl_logic_vector(27 downto 0);
        result_base     : in     vl_logic_vector(27 downto 0);
        source_id       : in     vl_logic_vector(63 downto 0);
        epoch           : in     vl_logic_vector(63 downto 0);
        context_valid   : in     vl_logic;
        session_id      : in     vl_logic_vector(31 downto 0);
        cmd_valid       : in     vl_logic;
        cmd             : in     vl_logic_vector(7 downto 0);
        payload         : in     vl_logic_vector(255 downto 0);
        code            : out    vl_logic_vector(7 downto 0);
        reply           : out    vl_logic_vector(95 downto 0);
        busy            : out    vl_logic;
        done            : out    vl_logic;
        good            : out    vl_logic;
        fault           : out    vl_logic;
        awaddr          : out    vl_logic_vector(27 downto 0);
        awlen           : out    vl_logic_vector(3 downto 0);
        awvalid         : out    vl_logic;
        awready         : in     vl_logic;
        wready          : in     vl_logic;
        wlast           : in     vl_logic;
        wid             : in     vl_logic_vector(3 downto 0);
        wdata           : out    vl_logic_vector(255 downto 0);
        wstrb           : out    vl_logic_vector(31 downto 0);
        read_req        : out    vl_logic;
        read_addr       : out    vl_logic_vector(27 downto 0);
        read_len        : out    vl_logic_vector(4 downto 0);
        read_ready      : in     vl_logic;
        read_valid      : in     vl_logic;
        read_done       : in     vl_logic;
        read_data       : in     vl_logic_vector(255 downto 0);
        active_version  : out    vl_logic_vector(31 downto 0);
        frame_version   : out    vl_logic_vector(31 downto 0);
        frame_cycles    : out    vl_logic_vector(31 downto 0);
        cache_hits      : out    vl_logic_vector(31 downto 0);
        cache_misses    : out    vl_logic_vector(31 downto 0);
        applied_frame_id: out    vl_logic_vector(63 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of WIDTH : constant is 1;
    attribute mti_svvh_generic_type of HEIGHT : constant is 1;
    attribute mti_svvh_generic_type of STRIDE : constant is 1;
end geometry_gray_processor;
