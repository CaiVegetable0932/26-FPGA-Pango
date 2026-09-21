library verilog;
use verilog.vl_types.all;
entity mini_dvp_observe is
    generic(
        WIDTH_BYTES     : integer := 2560;
        HEIGHT          : integer := 720
    );
    port(
        clk             : in     vl_logic;
        reset_n         : in     vl_logic;
        vsync           : in     vl_logic;
        href            : in     vl_logic;
        seen            : out    vl_logic_vector(3 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of WIDTH_BYTES : constant is 1;
    attribute mti_svvh_generic_type of HEIGHT : constant is 1;
end mini_dvp_observe;
