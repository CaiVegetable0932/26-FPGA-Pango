library verilog;
use verilog.vl_types.all;
entity mdio_clause22 is
    generic(
        HALF_CYCLES     : integer := 63
    );
    port(
        clk             : in     vl_logic;
        reset_n         : in     vl_logic;
        start           : in     vl_logic;
        read_not_write  : in     vl_logic;
        phy_addr        : in     vl_logic_vector(4 downto 0);
        reg_addr        : in     vl_logic_vector(4 downto 0);
        write_data      : in     vl_logic_vector(15 downto 0);
        mdio_i          : in     vl_logic;
        mdio_o          : out    vl_logic;
        mdio_oe         : out    vl_logic;
        mdc             : out    vl_logic;
        busy            : out    vl_logic;
        done            : out    vl_logic;
        ack_error       : out    vl_logic;
        read_data       : out    vl_logic_vector(15 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of HALF_CYCLES : constant is 2;
end mdio_clause22;
