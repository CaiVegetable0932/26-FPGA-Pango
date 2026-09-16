library verilog;
use verilog.vl_types.all;
entity V_POSTGMUXLR is
    port(
        CLKOUT          : out    vl_logic_vector(13 downto 0);
        CFG_MUX         : in     vl_logic_vector(7 downto 0);
        CLK_HSST        : in     vl_logic_vector(9 downto 0);
        CLK_MUXLR       : in     vl_logic_vector(13 downto 0)
    );
end V_POSTGMUXLR;
