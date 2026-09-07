library verilog;
use verilog.vl_types.all;
entity INT_ecc_check_64_to_8_ncst is
    port(
        bypass          : in     vl_logic;
        data_in         : in     vl_logic_vector(63 downto 0);
        check_in        : in     vl_logic_vector(7 downto 0);
        one_bit_err     : out    vl_logic;
        two_bit_err     : out    vl_logic;
        correct_data    : out    vl_logic_vector(63 downto 0);
        correct_ecc     : out    vl_logic_vector(7 downto 0)
    );
end INT_ecc_check_64_to_8_ncst;
