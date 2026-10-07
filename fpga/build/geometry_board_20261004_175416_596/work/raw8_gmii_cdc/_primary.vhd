library verilog;
use verilog.vl_types.all;
entity raw8_gmii_cdc is
    port(
        wr_clk          : in     vl_logic;
        wr_reset_n      : in     vl_logic;
        in_data         : in     vl_logic_vector(7 downto 0);
        in_en           : in     vl_logic;
        in_error        : in     vl_logic;
        rd_clk          : in     vl_logic;
        rd_reset_n      : in     vl_logic;
        out_data        : out    vl_logic_vector(7 downto 0);
        out_en          : out    vl_logic;
        out_error       : out    vl_logic;
        wr_fault        : out    vl_logic;
        rd_fault        : out    vl_logic
    );
end raw8_gmii_cdc;
