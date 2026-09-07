library verilog;
use verilog.vl_types.all;
entity GTP_OUTBUFTCO_E1 is
    generic(
        IOSTANDARD      : string  := "DEFAULT"
    );
    port(
        O               : out    vl_logic;
        OB              : out    vl_logic;
        I               : in     vl_logic;
        IB              : in     vl_logic;
        T               : in     vl_logic;
        TB              : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of IOSTANDARD : constant is 1;
end GTP_OUTBUFTCO_E1;
