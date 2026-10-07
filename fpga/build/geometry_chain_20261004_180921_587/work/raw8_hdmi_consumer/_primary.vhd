library verilog;
use verilog.vl_types.all;
entity raw8_hdmi_consumer is
    generic(
        PROCESSED       : integer := 0
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        frame_ack       : in     vl_logic;
        release_ack     : in     vl_logic;
        frame_req       : out    vl_logic;
        release_req     : out    vl_logic;
        word_data       : in     vl_logic_vector(255 downto 0);
        word_valid      : in     vl_logic;
        word_ready      : out    vl_logic;
        hs              : out    vl_logic;
        vs              : out    vl_logic;
        de              : out    vl_logic;
        rgb             : out    vl_logic_vector(23 downto 0);
        underflows      : out    vl_logic_vector(31 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of PROCESSED : constant is 1;
end raw8_hdmi_consumer;
