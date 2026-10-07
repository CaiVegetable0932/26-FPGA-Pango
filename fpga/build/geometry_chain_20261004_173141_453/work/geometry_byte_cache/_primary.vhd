library verilog;
use verilog.vl_types.all;
entity geometry_byte_cache is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        invalidate      : in     vl_logic;
        request_valid   : in     vl_logic;
        request_ready   : out    vl_logic;
        address         : in     vl_logic_vector(27 downto 0);
        response_valid  : out    vl_logic;
        response_ready  : in     vl_logic;
        value           : out    vl_logic_vector(7 downto 0);
        read_req        : out    vl_logic;
        read_addr       : out    vl_logic_vector(27 downto 0);
        read_ready      : in     vl_logic;
        read_valid      : in     vl_logic;
        read_done       : in     vl_logic;
        read_data       : in     vl_logic_vector(255 downto 0);
        fault           : out    vl_logic;
        hits            : out    vl_logic_vector(31 downto 0);
        misses          : out    vl_logic_vector(31 downto 0)
    );
end geometry_byte_cache;
