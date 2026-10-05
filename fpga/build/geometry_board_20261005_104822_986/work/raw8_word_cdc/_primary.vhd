library verilog;
use verilog.vl_types.all;
entity raw8_word_cdc is
    port(
        wr_clk          : in     vl_logic;
        wr_rst          : in     vl_logic;
        wr_en           : in     vl_logic;
        wr_data         : in     vl_logic_vector(255 downto 0);
        wr_full         : out    vl_logic;
        wr_water_level  : out    vl_logic_vector(9 downto 0);
        rd_clk          : in     vl_logic;
        rd_rst          : in     vl_logic;
        rd_en           : in     vl_logic;
        rd_data         : out    vl_logic_vector(255 downto 0);
        almost_full     : out    vl_logic;
        rd_empty        : out    vl_logic;
        rd_water_level  : out    vl_logic_vector(9 downto 0);
        almost_empty    : out    vl_logic
    );
end raw8_word_cdc;
