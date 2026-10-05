library verilog;
use verilog.vl_types.all;
entity pango_rgmii_tx is
    generic(
        SEPARATE_TXC_RESET: integer := 0;
        PHY_TXID        : integer := 0
    );
    port(
        clk125          : in     vl_logic;
        clk125_90       : in     vl_logic;
        reset_n         : in     vl_logic;
        txc_reset_n     : in     vl_logic;
        gmii_data       : in     vl_logic_vector(7 downto 0);
        gmii_en         : in     vl_logic;
        gmii_error      : in     vl_logic;
        rgmii_txc       : out    vl_logic;
        rgmii_ctl       : out    vl_logic;
        rgmii_data      : out    vl_logic_vector(3 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of SEPARATE_TXC_RESET : constant is 1;
    attribute mti_svvh_generic_type of PHY_TXID : constant is 1;
end pango_rgmii_tx;
