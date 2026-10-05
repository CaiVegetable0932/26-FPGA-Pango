library verilog;
use verilog.vl_types.all;
entity geometry_result_writer is
    generic(
        WIDTH           : integer := 1920;
        HEIGHT          : integer := 1080;
        STRIDE          : integer := 2048
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        start           : in     vl_logic;
        base            : in     vl_logic_vector(27 downto 0);
        pixel_valid     : in     vl_logic;
        pixel_mask      : in     vl_logic;
        pixel           : in     vl_logic_vector(7 downto 0);
        pixel_ready     : out    vl_logic;
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
        fence_req       : out    vl_logic;
        fence_addr      : out    vl_logic_vector(27 downto 0);
        fence_ready     : in     vl_logic;
        fence_valid     : in     vl_logic;
        fence_done      : in     vl_logic;
        fence_data      : in     vl_logic_vector(255 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of WIDTH : constant is 1;
    attribute mti_svvh_generic_type of HEIGHT : constant is 1;
    attribute mti_svvh_generic_type of STRIDE : constant is 1;
end geometry_result_writer;
