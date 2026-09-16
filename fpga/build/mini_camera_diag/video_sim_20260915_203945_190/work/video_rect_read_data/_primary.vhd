library verilog;
use verilog.vl_types.all;
entity video_rect_read_data is
    generic(
        DATA_WIDTH      : integer := 16
    );
    port(
        video_clk       : in     vl_logic;
        rst             : in     vl_logic;
        video_left_offset: in     vl_logic_vector(11 downto 0);
        video_top_offset: in     vl_logic_vector(11 downto 0);
        video_width     : in     vl_logic_vector(11 downto 0);
        video_height    : in     vl_logic_vector(11 downto 0);
        read_req        : out    vl_logic;
        read_req_ack    : in     vl_logic;
        read_en         : out    vl_logic;
        read_data       : in     vl_logic_vector;
        timing_hs       : in     vl_logic;
        timing_vs       : in     vl_logic;
        x_cnt           : out    vl_logic_vector(11 downto 0);
        y_cnt           : out    vl_logic_vector(11 downto 0);
        timing_de       : in     vl_logic;
        timing_data     : in     vl_logic_vector;
        hs              : out    vl_logic;
        vs              : out    vl_logic;
        de              : out    vl_logic;
        vout_data       : out    vl_logic_vector
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of DATA_WIDTH : constant is 1;
end video_rect_read_data;
