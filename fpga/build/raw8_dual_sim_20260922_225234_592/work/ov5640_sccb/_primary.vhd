library verilog;
use verilog.vl_types.all;
entity ov5640_sccb is
    generic(
        DEV_ADDR        : vl_logic_vector(0 to 7) := (Hi0, Hi1, Hi1, Hi1, Hi1, Hi0, Hi0, Hi0);
        SYS_CLK         : integer := 27000000;
        SCCB_CLK        : integer := 100000;
        STRETCH_TIMEOUT : integer := 270000
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        sccb_start      : in     vl_logic;
        data_in         : in     vl_logic_vector(23 downto 0);
        read_enable     : in     vl_logic;
        read_data       : out    vl_logic_vector(7 downto 0);
        SCL             : inout  vl_logic;
        SDA             : inout  vl_logic;
        sccb_done       : out    vl_logic;
        sccb_error      : out    vl_logic;
        busy            : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of DEV_ADDR : constant is 1;
    attribute mti_svvh_generic_type of SYS_CLK : constant is 1;
    attribute mti_svvh_generic_type of SCCB_CLK : constant is 1;
    attribute mti_svvh_generic_type of STRETCH_TIMEOUT : constant is 1;
end ov5640_sccb;
