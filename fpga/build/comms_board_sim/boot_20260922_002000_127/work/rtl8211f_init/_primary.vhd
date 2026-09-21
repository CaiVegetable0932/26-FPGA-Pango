library verilog;
use verilog.vl_types.all;
entity rtl8211f_init is
    generic(
        CLK_HZ          : integer := 125000000;
        HALF_CYCLES     : integer := 63;
        RESET_MS        : integer := 10;
        SETTLE_MS       : integer := 30;
        POLL_MS         : integer := 100;
        PHY_ADDR        : vl_logic_vector(4 downto 0) := (Hi0, Hi0, Hi0, Hi0, Hi1)
    );
    port(
        clk             : in     vl_logic;
        reset_n         : in     vl_logic;
        mdio_i          : in     vl_logic;
        mdio_o          : out    vl_logic;
        mdio_oe         : out    vl_logic;
        mdc             : out    vl_logic;
        phy_reset_n     : out    vl_logic;
        configured      : out    vl_logic;
        link_ready      : out    vl_logic;
        fault           : out    vl_logic;
        fault_code      : out    vl_logic_vector(3 downto 0);
        phy_status      : out    vl_logic_vector(15 downto 0);
        phy_id          : out    vl_logic_vector(31 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CLK_HZ : constant is 2;
    attribute mti_svvh_generic_type of HALF_CYCLES : constant is 2;
    attribute mti_svvh_generic_type of RESET_MS : constant is 2;
    attribute mti_svvh_generic_type of SETTLE_MS : constant is 2;
    attribute mti_svvh_generic_type of POLL_MS : constant is 2;
    attribute mti_svvh_generic_type of PHY_ADDR : constant is 2;
end rtl8211f_init;
