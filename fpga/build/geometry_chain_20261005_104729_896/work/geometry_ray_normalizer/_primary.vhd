library verilog;
use verilog.vl_types.all;
entity geometry_ray_normalizer is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        start           : in     vl_logic;
        ready           : out    vl_logic;
        numerator_x     : in     vl_logic_vector(47 downto 0);
        numerator_y     : in     vl_logic_vector(47 downto 0);
        denominator     : in     vl_logic_vector(47 downto 0);
        valid           : out    vl_logic;
        consume         : in     vl_logic;
        domain_valid    : out    vl_logic;
        xq              : out    vl_logic_vector(31 downto 0);
        yq              : out    vl_logic_vector(31 downto 0)
    );
end geometry_ray_normalizer;
