library verilog;
use verilog.vl_types.all;
entity raw8_hdmi_gray_antialias is
    port(
        clk             : in     vl_logic;
        reset_n         : in     vl_logic;
        line_preload    : in     vl_logic;
        pixel_accept    : in     vl_logic;
        first_row       : in     vl_logic;
        first_col       : in     vl_logic;
        column          : in     vl_logic_vector(10 downto 0);
        luma            : in     vl_logic_vector(7 downto 0);
        gray            : out    vl_logic_vector(7 downto 0)
    );
end raw8_hdmi_gray_antialias;
