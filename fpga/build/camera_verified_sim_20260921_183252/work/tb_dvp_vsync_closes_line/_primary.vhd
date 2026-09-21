library verilog;
use verilog.vl_types.all;
entity tb_dvp_vsync_closes_line is
    generic(
        WIDTH           : integer := 4;
        HEIGHT          : integer := 2;
        HREF_BLANK_CYCLES: integer := 1
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of WIDTH : constant is 1;
    attribute mti_svvh_generic_type of HEIGHT : constant is 1;
    attribute mti_svvh_generic_type of HREF_BLANK_CYCLES : constant is 1;
end tb_dvp_vsync_closes_line;
