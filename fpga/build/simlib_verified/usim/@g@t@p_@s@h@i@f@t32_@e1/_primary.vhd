library verilog;
use verilog.vl_types.all;
entity GTP_SHIFT32_E1 is
    generic(
        INIT            : vl_logic_vector(31 downto 0) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0)
    );
    port(
        Z               : out    vl_logic;
        ADDR            : in     vl_logic_vector(4 downto 0);
        SI              : in     vl_logic;
        WCLK            : in     vl_logic;
        CE              : in     vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of INIT : constant is 2;
end GTP_SHIFT32_E1;
