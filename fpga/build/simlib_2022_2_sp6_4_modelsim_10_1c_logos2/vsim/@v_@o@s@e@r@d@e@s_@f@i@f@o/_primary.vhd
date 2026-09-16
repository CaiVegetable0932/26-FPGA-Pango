library verilog;
use verilog.vl_types.all;
entity V_OSERDES_FIFO is
    generic(
        FIFO_BYPASS     : string  := "FASLE";
        WCLK_INV        : string  := "FALSE";
        RCLK_INV        : string  := "FALSE"
    );
    port(
        DOUT            : out    vl_logic_vector(7 downto 0);
        TOUT            : out    vl_logic_vector(7 downto 0);
        DIN             : in     vl_logic_vector(7 downto 0);
        TIN             : in     vl_logic_vector(7 downto 0);
        RST             : in     vl_logic;
        EN              : in     vl_logic;
        WCLK            : in     vl_logic;
        RCLK            : in     vl_logic;
        EMPTY           : out    vl_logic;
        FULL            : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of FIFO_BYPASS : constant is 1;
    attribute mti_svvh_generic_type of WCLK_INV : constant is 1;
    attribute mti_svvh_generic_type of RCLK_INV : constant is 1;
end V_OSERDES_FIFO;
