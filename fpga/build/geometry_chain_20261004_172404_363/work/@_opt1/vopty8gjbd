library verilog;
use verilog.vl_types.all;
entity geometry_bilinear_rgb is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        sample_valid    : in     vl_logic;
        source_valid    : in     vl_logic;
        frac_x          : in     vl_logic_vector(11 downto 0);
        frac_y          : in     vl_logic_vector(11 downto 0);
        p00             : in     vl_logic_vector(23 downto 0);
        p10             : in     vl_logic_vector(23 downto 0);
        p01             : in     vl_logic_vector(23 downto 0);
        p11             : in     vl_logic_vector(23 downto 0);
        pixel_valid     : out    vl_logic;
        pixel           : out    vl_logic_vector(23 downto 0);
        pixel_source_valid: out    vl_logic
    );
end geometry_bilinear_rgb;
