library verilog;
use verilog.vl_types.all;
entity geometry_map_engine is
    generic(
        WIDTH           : integer := 1920;
        HEIGHT          : integer := 1080
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        model           : in     vl_logic_vector(1 downto 0);
        words           : in     vl_logic_vector(447 downto 0);
        request_valid   : in     vl_logic;
        request_ready   : out    vl_logic;
        ox              : in     vl_logic_vector(11 downto 0);
        oy              : in     vl_logic_vector(11 downto 0);
        result_valid    : out    vl_logic;
        result_ready    : in     vl_logic;
        source_valid    : out    vl_logic;
        x0              : out    vl_logic_vector(11 downto 0);
        x1              : out    vl_logic_vector(11 downto 0);
        y0              : out    vl_logic_vector(11 downto 0);
        y1              : out    vl_logic_vector(11 downto 0);
        frac_x          : out    vl_logic_vector(11 downto 0);
        frac_y          : out    vl_logic_vector(11 downto 0);
        lut_index       : out    vl_logic_vector(10 downto 0);
        scale0          : in     vl_logic_vector(31 downto 0);
        scale1          : in     vl_logic_vector(31 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of WIDTH : constant is 1;
    attribute mti_svvh_generic_type of HEIGHT : constant is 1;
end geometry_map_engine;
