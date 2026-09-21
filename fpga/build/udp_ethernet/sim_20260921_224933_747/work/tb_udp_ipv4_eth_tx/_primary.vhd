library verilog;
use verilog.vl_types.all;
entity tb_udp_ipv4_eth_tx is
    generic(
        RX_TIMEOUT_CYCLES: integer := 32
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of RX_TIMEOUT_CYCLES : constant is 2;
end tb_udp_ipv4_eth_tx;
