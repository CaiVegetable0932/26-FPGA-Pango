library verilog;
use verilog.vl_types.all;
entity geometry_write_arbiter is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        c_addr          : in     vl_logic_vector(27 downto 0);
        g_addr          : in     vl_logic_vector(27 downto 0);
        c_data          : in     vl_logic_vector(255 downto 0);
        g_data          : in     vl_logic_vector(255 downto 0);
        c_valid         : in     vl_logic;
        g_valid         : in     vl_logic;
        c_ready         : out    vl_logic;
        g_ready         : out    vl_logic;
        c_wready        : out    vl_logic;
        g_wready        : out    vl_logic;
        awaddr          : out    vl_logic_vector(27 downto 0);
        awvalid         : out    vl_logic;
        wdata           : out    vl_logic_vector(255 downto 0);
        awready         : in     vl_logic;
        wready          : in     vl_logic;
        wlast           : in     vl_logic;
        fault           : out    vl_logic
    );
end geometry_write_arbiter;
