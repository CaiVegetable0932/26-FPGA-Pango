library verilog;
use verilog.vl_types.all;
entity mul_case is
    generic(
        A               : integer := 32;
        B               : integer := 36
    );
    port(
        done            : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of A : constant is 1;
    attribute mti_svvh_generic_type of B : constant is 1;
end mul_case;
