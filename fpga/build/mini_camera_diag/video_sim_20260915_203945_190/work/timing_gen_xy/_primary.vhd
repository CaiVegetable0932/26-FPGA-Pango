library verilog;
use verilog.vl_types.all;
entity timing_gen_xy is
    generic(
        DATA_WIDTH      : integer := 24
    );
    port(
        rst_n           : in     vl_logic;
        clk             : in     vl_logic;
        i_hs            : in     vl_logic;
        i_vs            : in     vl_logic;
        i_de            : in     vl_logic;
        i_data          : in     vl_logic_vector;
        o_hs            : out    vl_logic;
        o_vs            : out    vl_logic;
        o_de            : out    vl_logic;
        o_data          : out    vl_logic_vector;
        x               : out    vl_logic_vector(11 downto 0);
        y               : out    vl_logic_vector(11 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of DATA_WIDTH : constant is 1;
end timing_gen_xy;
