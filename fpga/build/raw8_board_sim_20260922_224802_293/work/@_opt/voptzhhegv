library verilog;
use verilog.vl_types.all;
entity raw8_dual_core is
    generic(
        WARMUP_FRAMES   : integer := 10
    );
    port(
        mem_clk         : in     vl_logic;
        mem_reset_n     : in     vl_logic;
        cam_clk         : in     vl_logic;
        cam_reset_n     : in     vl_logic;
        pixel_clk       : in     vl_logic;
        pixel_reset_n   : in     vl_logic;
        configured      : in     vl_logic;
        vsync           : in     vl_logic;
        href            : in     vl_logic;
        camera_data     : in     vl_logic_vector(7 downto 0);
        commissioned    : in     vl_logic;
        network_enable  : in     vl_logic;
        epoch           : in     vl_logic_vector(63 downto 0);
        src_mac         : in     vl_logic_vector(47 downto 0);
        dst_mac         : in     vl_logic_vector(47 downto 0);
        src_ip          : in     vl_logic_vector(31 downto 0);
        dst_ip          : in     vl_logic_vector(31 downto 0);
        src_port        : in     vl_logic_vector(15 downto 0);
        dst_port        : in     vl_logic_vector(15 downto 0);
        awaddr          : out    vl_logic_vector(27 downto 0);
        araddr          : out    vl_logic_vector(27 downto 0);
        awlen           : out    vl_logic_vector(3 downto 0);
        arlen           : out    vl_logic_vector(3 downto 0);
        arid            : out    vl_logic_vector(3 downto 0);
        awvalid         : out    vl_logic;
        arvalid         : out    vl_logic;
        awready         : in     vl_logic;
        arready         : in     vl_logic;
        wready          : in     vl_logic;
        wlast           : in     vl_logic;
        wid             : in     vl_logic_vector(3 downto 0);
        rid             : in     vl_logic_vector(3 downto 0);
        rvalid          : in     vl_logic;
        rlast           : in     vl_logic;
        rdata           : in     vl_logic_vector(255 downto 0);
        wdata           : out    vl_logic_vector(255 downto 0);
        wstrb           : out    vl_logic_vector(31 downto 0);
        rgb             : out    vl_logic_vector(23 downto 0);
        hs              : out    vl_logic;
        vs              : out    vl_logic;
        de              : out    vl_logic;
        gmii_data       : out    vl_logic_vector(7 downto 0);
        gmii_en         : out    vl_logic;
        gmii_error      : out    vl_logic;
        fault           : out    vl_logic;
        published       : out    vl_logic_vector(31 downto 0);
        underflows      : out    vl_logic_vector(31 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of WARMUP_FRAMES : constant is 1;
end raw8_dual_core;
