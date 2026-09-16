library verilog;
use verilog.vl_types.all;
entity V_PREGMUXLR is
    port(
        CLKIN           : in     vl_logic_vector(49 downto 0);
        CLKOUT          : out    vl_logic_vector(13 downto 0);
        CFG_MUX         : in     vl_logic_vector(9 downto 0)
    );
end V_PREGMUXLR;
