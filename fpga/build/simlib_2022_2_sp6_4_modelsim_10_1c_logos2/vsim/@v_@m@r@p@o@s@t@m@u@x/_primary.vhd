library verilog;
use verilog.vl_types.all;
entity V_MRPOSTMUX is
    port(
        CLKIN_P         : in     vl_logic_vector(13 downto 0);
        CLK_SRB_MRPOSTMUX: in     vl_logic_vector(1 downto 0);
        CLKOUT_P        : out    vl_logic_vector(3 downto 0);
        CFG_MUX         : in     vl_logic_vector(6 downto 0)
    );
end V_MRPOSTMUX;
