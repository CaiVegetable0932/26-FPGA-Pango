library verilog;
use verilog.vl_types.all;
entity raw8_write_engine is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        slot_base       : in     vl_logic_vector(27 downto 0);
        epoch           : in     vl_logic_vector(63 downto 0);
        record_data     : in     vl_logic_vector(287 downto 0);
        record_valid    : in     vl_logic;
        record_ready    : out    vl_logic;
        commit          : out    vl_logic;
        good            : out    vl_logic;
        captured_id     : out    vl_logic_vector(63 downto 0);
        captured_epoch  : out    vl_logic_vector(63 downto 0);
        awaddr          : out    vl_logic_vector(27 downto 0);
        awlen           : out    vl_logic_vector(3 downto 0);
        awvalid         : out    vl_logic;
        awready         : in     vl_logic;
        wready          : in     vl_logic;
        wlast           : in     vl_logic;
        wid             : in     vl_logic_vector(3 downto 0);
        wdata           : out    vl_logic_vector(255 downto 0);
        wstrb           : out    vl_logic_vector(31 downto 0);
        fence_req       : out    vl_logic;
        fence_addr      : out    vl_logic_vector(27 downto 0);
        fence_ready     : in     vl_logic;
        fence_valid     : in     vl_logic;
        fence_done      : in     vl_logic;
        rdata           : in     vl_logic_vector(255 downto 0);
        fault           : out    vl_logic;
        fault_code      : out    vl_logic_vector(2 downto 0);
        fault_snapshot  : out    vl_logic_vector(95 downto 0);
        debug_state     : out    vl_logic_vector(7 downto 0)
    );
end raw8_write_engine;
