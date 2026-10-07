library verilog;
use verilog.vl_types.all;
entity geometry_mul_pipe is
    generic(
        A_WIDTH         : integer := 32;
        B_WIDTH         : integer := 36
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        request_valid   : in     vl_logic;
        a               : in     vl_logic_vector;
        b               : in     vl_logic_vector;
        result_valid    : out    vl_logic;
        product         : out    vl_logic_vector
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of A_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of B_WIDTH : constant is 1;
end geometry_mul_pipe;
