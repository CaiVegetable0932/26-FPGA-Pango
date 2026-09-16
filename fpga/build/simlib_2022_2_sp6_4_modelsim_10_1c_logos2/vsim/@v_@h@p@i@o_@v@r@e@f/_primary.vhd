library verilog;
use verilog.vl_types.all;
entity V_HPIO_VREF is
    port(
        CODE_VREF0      : in     vl_logic_vector(7 downto 0);
        CODE_VREF1      : in     vl_logic_vector(7 downto 0);
        CODE_VREF2      : in     vl_logic_vector(7 downto 0);
        CODE_VREF3      : in     vl_logic_vector(7 downto 0)
    );
end V_HPIO_VREF;
