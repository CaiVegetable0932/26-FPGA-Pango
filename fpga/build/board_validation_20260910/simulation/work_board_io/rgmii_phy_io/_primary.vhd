library verilog;
use verilog.vl_types.all;
entity rgmii_phy_io is
    port(
        tx_clk          : in     vl_logic;
        reset           : in     vl_logic;
        tx_data         : in     vl_logic_vector(7 downto 0);
        tx_valid        : in     vl_logic;
        rgmii_rxc       : in     vl_logic;
        rgmii_rxd       : in     vl_logic_vector(3 downto 0);
        rgmii_rx_ctl    : in     vl_logic;
        rx_clk          : out    vl_logic;
        rx_data         : out    vl_logic_vector(7 downto 0);
        rx_valid        : out    vl_logic;
        rx_error        : out    vl_logic;
        rgmii_txc       : out    vl_logic;
        rgmii_txd       : out    vl_logic_vector(3 downto 0);
        rgmii_tx_ctl    : out    vl_logic
    );
end rgmii_phy_io;
