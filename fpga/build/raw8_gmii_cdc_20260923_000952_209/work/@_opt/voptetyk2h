library verilog;
use verilog.vl_types.all;
entity raw8_native_queue is
    generic(
        WIDTH           : integer := 256
    );
    port(
        wr_clk          : in     vl_logic;
        wr_reset_n      : in     vl_logic;
        in_data         : in     vl_logic_vector;
        in_valid        : in     vl_logic;
        in_ready        : out    vl_logic;
        wr_used         : out    vl_logic_vector(9 downto 0);
        rd_clk          : in     vl_logic;
        rd_reset_n      : in     vl_logic;
        out_data        : out    vl_logic_vector;
        out_valid       : out    vl_logic;
        out_ready       : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of WIDTH : constant is 1;
end raw8_native_queue;
