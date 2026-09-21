library verilog;
use verilog.vl_types.all;
entity mini_dvp_measure is
    generic(
        WIDTH_BYTES     : integer := 2560;
        HEIGHT          : integer := 720
    );
    port(
        clk             : in     vl_logic;
        reset_n         : in     vl_logic;
        cfg_ready       : in     vl_logic;
        vsync           : in     vl_logic;
        href            : in     vl_logic;
        capture_status  : in     vl_logic_vector(7 downto 0);
        packet          : out    vl_logic_vector(159 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of WIDTH_BYTES : constant is 1;
    attribute mti_svvh_generic_type of HEIGHT : constant is 1;
end mini_dvp_measure;
