library verilog;
use verilog.vl_types.all;
entity tb_raw8_native_queue is
    generic(
        W               : integer := 256
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of W : constant is 1;
end tb_raw8_native_queue;
