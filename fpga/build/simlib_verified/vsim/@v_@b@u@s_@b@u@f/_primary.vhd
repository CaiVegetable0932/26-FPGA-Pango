library verilog;
use verilog.vl_types.all;
entity V_BUS_BUF is
    port(
        \OUT\           : out    vl_logic_vector(99 downto 0);
        \IN\            : in     vl_logic_vector(99 downto 0)
    );
end V_BUS_BUF;
