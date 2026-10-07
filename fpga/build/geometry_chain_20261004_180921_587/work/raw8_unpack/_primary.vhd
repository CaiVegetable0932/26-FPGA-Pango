library verilog;
use verilog.vl_types.all;
entity raw8_unpack is
    generic(
        WIDTH           : integer := 1920;
        HEIGHT          : integer := 1080
    );
    port(
        clk             : in     vl_logic;
        reset_n         : in     vl_logic;
        start           : in     vl_logic;
        idle            : out    vl_logic;
        word_data       : in     vl_logic_vector(255 downto 0);
        word_valid      : in     vl_logic;
        word_ready      : out    vl_logic;
        pixel_data      : out    vl_logic_vector(7 downto 0);
        pixel_valid     : out    vl_logic;
        pixel_last      : out    vl_logic;
        pixel_ready     : in     vl_logic;
        done            : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of WIDTH : constant is 1;
    attribute mti_svvh_generic_type of HEIGHT : constant is 1;
end raw8_unpack;
