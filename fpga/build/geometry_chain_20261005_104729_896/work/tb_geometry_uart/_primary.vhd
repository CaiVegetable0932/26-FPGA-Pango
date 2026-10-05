library verilog;
use verilog.vl_types.all;
entity tb_geometry_uart is
    generic(
        CLK_HZ          : integer := 1843200;
        BAUD            : integer := 115200;
        RX_TIMEOUT_MS   : integer := 2;
        FULL            : integer := 1
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CLK_HZ : constant is 2;
    attribute mti_svvh_generic_type of BAUD : constant is 2;
    attribute mti_svvh_generic_type of RX_TIMEOUT_MS : constant is 2;
    attribute mti_svvh_generic_type of FULL : constant is 2;
end tb_geometry_uart;
