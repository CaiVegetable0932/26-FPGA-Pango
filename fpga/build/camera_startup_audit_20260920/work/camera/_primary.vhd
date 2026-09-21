library verilog;
use verilog.vl_types.all;
entity camera is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        SCL             : inout  vl_logic;
        SDA             : inout  vl_logic;
        camera_clk      : in     vl_logic;
        camera_data     : in     vl_logic_vector(7 downto 0);
        camera_herf     : in     vl_logic;
        camera_vsync    : in     vl_logic;
        ddr_init        : in     vl_logic;
        camera_rstn     : out    vl_logic;
        camera_pwnd     : out    vl_logic;
        init_done       : out    vl_logic;
        wf_wr_data      : out    vl_logic_vector(15 downto 0);
        wf_wr_en        : out    vl_logic;
        vs              : out    vl_logic;
        hs              : out    vl_logic;
        sop             : out    vl_logic;
        eop             : out    vl_logic
    );
end camera;
