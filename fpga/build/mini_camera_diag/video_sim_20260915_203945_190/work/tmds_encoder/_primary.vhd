library verilog;
use verilog.vl_types.all;
entity tmds_encoder is
    generic(
        CTRLTOKEN0      : vl_logic_vector(0 to 9) := (Hi1, Hi1, Hi0, Hi1, Hi0, Hi1, Hi0, Hi1, Hi0, Hi0);
        CTRLTOKEN1      : vl_logic_vector(0 to 9) := (Hi0, Hi0, Hi1, Hi0, Hi1, Hi0, Hi1, Hi0, Hi1, Hi1);
        CTRLTOKEN2      : vl_logic_vector(0 to 9) := (Hi0, Hi1, Hi0, Hi1, Hi0, Hi1, Hi0, Hi1, Hi0, Hi0);
        CTRLTOKEN3      : vl_logic_vector(0 to 9) := (Hi1, Hi0, Hi1, Hi0, Hi1, Hi0, Hi1, Hi0, Hi1, Hi1)
    );
    port(
        pix_clk         : in     vl_logic;
        rstn            : in     vl_logic;
        din             : in     vl_logic_vector(7 downto 0);
        c0              : in     vl_logic;
        c1              : in     vl_logic;
        de              : in     vl_logic;
        dout            : out    vl_logic_vector(9 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of CTRLTOKEN0 : constant is 1;
    attribute mti_svvh_generic_type of CTRLTOKEN1 : constant is 1;
    attribute mti_svvh_generic_type of CTRLTOKEN2 : constant is 1;
    attribute mti_svvh_generic_type of CTRLTOKEN3 : constant is 1;
end tmds_encoder;
