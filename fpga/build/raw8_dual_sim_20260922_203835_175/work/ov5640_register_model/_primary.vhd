library verilog;
use verilog.vl_types.all;
entity ov5640_register_model is
    port(
        reset_n         : in     vl_logic;
        scl             : in     vl_logic;
        sda             : inout  vl_logic;
        fault           : in     integer;
        writes          : out    integer;
        reads           : out    integer;
        starts          : out    integer;
        run_register    : out    vl_logic_vector(7 downto 0)
    );
end ov5640_register_model;
