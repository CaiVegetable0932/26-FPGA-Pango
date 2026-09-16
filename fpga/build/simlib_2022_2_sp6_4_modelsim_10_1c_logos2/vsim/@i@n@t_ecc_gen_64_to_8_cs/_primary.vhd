library verilog;
use verilog.vl_types.all;
entity INT_ecc_gen_64_to_8_cs is
    port(
        data_in         : in     vl_logic_vector(63 downto 0);
        data_out        : out    vl_logic_vector(63 downto 0);
        check_out       : out    vl_logic_vector(7 downto 0)
    );
end INT_ecc_gen_64_to_8_cs;
