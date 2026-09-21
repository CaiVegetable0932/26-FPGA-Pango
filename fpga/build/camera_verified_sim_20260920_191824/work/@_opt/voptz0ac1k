library verilog;
use verilog.vl_types.all;
entity camera_data is
    generic(
        FRAME_WIDTH     : integer := 1280;
        FRAME_HEIGHT    : integer := 720;
        WARMUP_FRAMES   : integer := 10
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        vsync           : in     vl_logic;
        href            : in     vl_logic;
        din             : in     vl_logic_vector(7 downto 0);
        cfg_done        : in     vl_logic;
        ddr_init        : in     vl_logic;
        pixel_data      : out    vl_logic_vector(15 downto 0);
        wf_wr_en        : out    vl_logic;
        sop             : out    vl_logic;
        eop             : out    vl_logic;
        vs              : out    vl_logic;
        hs              : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of FRAME_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of FRAME_HEIGHT : constant is 1;
    attribute mti_svvh_generic_type of WARMUP_FRAMES : constant is 1;
end camera_data;
