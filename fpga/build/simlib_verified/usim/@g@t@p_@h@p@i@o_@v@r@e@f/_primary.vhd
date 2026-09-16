library verilog;
use verilog.vl_types.all;
entity GTP_HPIO_VREF is
    generic(
        BANK_LOC        : string  := "BANKR5"
    );
    port(
        CODE_VREF0      : in     vl_logic_vector(7 downto 0);
        CODE_VREF1      : in     vl_logic_vector(7 downto 0);
        CODE_VREF2      : in     vl_logic_vector(7 downto 0);
        CODE_VREF3      : in     vl_logic_vector(7 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of BANK_LOC : constant is 1;
end GTP_HPIO_VREF;
