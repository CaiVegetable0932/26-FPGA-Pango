library verilog;
use verilog.vl_types.all;
entity tb_rtl8211f_init is
    generic(
        USE_PHY_DELAY   : integer := 1;
        SETTLE_TEST_MS  : integer := 200
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of USE_PHY_DELAY : constant is 1;
    attribute mti_svvh_generic_type of SETTLE_TEST_MS : constant is 1;
end tb_rtl8211f_init;
