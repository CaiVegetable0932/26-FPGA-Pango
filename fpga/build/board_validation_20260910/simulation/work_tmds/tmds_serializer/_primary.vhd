library verilog;
use verilog.vl_types.all;
entity tmds_serializer is
    port(
        pixel_clk       : in     vl_logic;
        serial_clk      : in     vl_logic;
        reset           : in     vl_logic;
        symbol          : in     vl_logic_vector(9 downto 0);
        data_p          : out    vl_logic;
        data_n          : out    vl_logic
    );
end tmds_serializer;
