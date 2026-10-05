library verilog;
use verilog.vl_types.all;
entity raw8_read_scheduler is
    generic(
        WIDTH           : integer := 1920;
        HEIGHT          : integer := 1080;
        STRIDE          : integer := 2048
    );
    port(
        clk             : in     vl_logic;
        reset_n         : in     vl_logic;
        start           : in     vl_logic;
        base            : in     vl_logic_vector(27 downto 0);
        idle            : out    vl_logic;
        request         : out    vl_logic;
        burst_ready     : in     vl_logic;
        burst_done      : in     vl_logic;
        address         : out    vl_logic_vector(27 downto 0);
        length          : out    vl_logic_vector(4 downto 0);
        done            : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of WIDTH : constant is 1;
    attribute mti_svvh_generic_type of HEIGHT : constant is 1;
    attribute mti_svvh_generic_type of STRIDE : constant is 1;
end raw8_read_scheduler;
