library verilog;
use verilog.vl_types.all;
entity geometry_gray_sampler is
    generic(
        STRIDE          : integer := 2048
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        start           : in     vl_logic;
        source_valid    : in     vl_logic;
        enhance         : in     vl_logic;
        base            : in     vl_logic_vector(27 downto 0);
        x0              : in     vl_logic_vector(11 downto 0);
        x1              : in     vl_logic_vector(11 downto 0);
        y0              : in     vl_logic_vector(11 downto 0);
        y1              : in     vl_logic_vector(11 downto 0);
        frac_x          : in     vl_logic_vector(11 downto 0);
        frac_y          : in     vl_logic_vector(11 downto 0);
        ready           : out    vl_logic;
        valid           : out    vl_logic;
        pixel_ready     : in     vl_logic;
        pixel           : out    vl_logic_vector(7 downto 0);
        mask_valid      : out    vl_logic;
        cache_req       : out    vl_logic;
        cache_ready     : in     vl_logic;
        cache_addr      : out    vl_logic_vector(27 downto 0);
        cache_valid     : in     vl_logic;
        cache_response_ready: out    vl_logic;
        cache_value     : in     vl_logic_vector(7 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of STRIDE : constant is 1;
end geometry_gray_sampler;
