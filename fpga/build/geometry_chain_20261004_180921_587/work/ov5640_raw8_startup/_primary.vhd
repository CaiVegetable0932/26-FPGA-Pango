library verilog;
use verilog.vl_types.all;
entity ov5640_raw8_startup is
    generic(
        SYS_CLK         : integer := 27000000;
        SCCB_CLK        : integer := 100000;
        RESET_CYCLES    : integer := 270000;
        BOOT_CYCLES     : integer := 1080000;
        WRITE_WAIT      : integer := 27000;
        SOFT_RESET_WAIT : integer := 135000;
        SETTLE_CYCLES   : integer := 1350000
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        scl             : inout  vl_logic;
        sda             : inout  vl_logic;
        reset_n         : out    vl_logic;
        ready           : out    vl_logic;
        failed          : out    vl_logic;
        error_code      : out    vl_logic_vector(3 downto 0);
        verify_index    : out    vl_logic_vector(6 downto 0);
        last_read       : out    vl_logic_vector(7 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of SYS_CLK : constant is 1;
    attribute mti_svvh_generic_type of SCCB_CLK : constant is 1;
    attribute mti_svvh_generic_type of RESET_CYCLES : constant is 1;
    attribute mti_svvh_generic_type of BOOT_CYCLES : constant is 1;
    attribute mti_svvh_generic_type of WRITE_WAIT : constant is 1;
    attribute mti_svvh_generic_type of SOFT_RESET_WAIT : constant is 1;
    attribute mti_svvh_generic_type of SETTLE_CYCLES : constant is 1;
end ov5640_raw8_startup;
