library verilog;
use verilog.vl_types.all;
entity mini_frame_pool is
    port(
        clk             : in     vl_logic;
        reset_n         : in     vl_logic;
        camera_req      : in     vl_logic;
        display_req     : in     vl_logic;
        dma_write_ack   : in     vl_logic;
        dma_read_ack    : in     vl_logic;
        dma_write_finish: in     vl_logic;
        camera_ack      : out    vl_logic;
        display_ack     : out    vl_logic;
        dma_write_req   : out    vl_logic;
        dma_read_req    : out    vl_logic;
        write_index     : out    vl_logic_vector(1 downto 0);
        read_index      : out    vl_logic_vector(1 downto 0);
        display_valid   : out    vl_logic;
        completed_frames: out    vl_logic_vector(31 downto 0);
        abandoned_frames: out    vl_logic_vector(31 downto 0)
    );
end mini_frame_pool;
