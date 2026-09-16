library verilog;
use verilog.vl_types.all;
entity data_init is
    generic(
        REG_NUM         : vl_logic_vector(0 to 7) := (Hi1, Hi1, Hi1, Hi1, Hi0, Hi1, Hi0, Hi0);
        CNT_WAIT_MAX    : integer := 27000;
        RESET_WAIT_MAX  : integer := 135000
    );
    port(
        sys_clk         : in     vl_logic;
        sys_rst_n       : in     vl_logic;
        cfg_end         : in     vl_logic;
        cfg_start       : out    vl_logic;
        cfg_data        : out    vl_logic_vector(23 downto 0);
        cfg_done        : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of REG_NUM : constant is 1;
    attribute mti_svvh_generic_type of CNT_WAIT_MAX : constant is 1;
    attribute mti_svvh_generic_type of RESET_WAIT_MAX : constant is 1;
end data_init;
