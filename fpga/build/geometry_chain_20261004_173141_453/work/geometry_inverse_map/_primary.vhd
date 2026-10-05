library verilog;
use verilog.vl_types.all;
entity geometry_inverse_map is
    generic(
        WIDTH           : integer := 1920;
        HEIGHT          : integer := 1080
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        request_valid   : in     vl_logic;
        output_x        : in     vl_logic_vector(11 downto 0);
        output_y        : in     vl_logic_vector(11 downto 0);
        a00             : in     vl_logic_vector(31 downto 0);
        a01             : in     vl_logic_vector(31 downto 0);
        a02             : in     vl_logic_vector(31 downto 0);
        a10             : in     vl_logic_vector(31 downto 0);
        a11             : in     vl_logic_vector(31 downto 0);
        a12             : in     vl_logic_vector(31 downto 0);
        k1              : in     vl_logic_vector(31 downto 0);
        k2              : in     vl_logic_vector(31 downto 0);
        p1              : in     vl_logic_vector(31 downto 0);
        p2              : in     vl_logic_vector(31 downto 0);
        fx              : in     vl_logic_vector(31 downto 0);
        fy              : in     vl_logic_vector(31 downto 0);
        cx              : in     vl_logic_vector(31 downto 0);
        cy              : in     vl_logic_vector(31 downto 0);
        result_valid    : out    vl_logic;
        source_valid    : out    vl_logic;
        x0              : out    vl_logic_vector(11 downto 0);
        x1              : out    vl_logic_vector(11 downto 0);
        y0              : out    vl_logic_vector(11 downto 0);
        y1              : out    vl_logic_vector(11 downto 0);
        frac_x          : out    vl_logic_vector(11 downto 0);
        frac_y          : out    vl_logic_vector(11 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of WIDTH : constant is 2;
    attribute mti_svvh_generic_type of HEIGHT : constant is 2;
end geometry_inverse_map;
