library verilog;
use verilog.vl_types.all;
entity raw8_read_arbiter is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        h_req           : in     vl_logic;
        h_addr          : in     vl_logic_vector(27 downto 0);
        h_len           : in     vl_logic_vector(4 downto 0);
        h_space         : in     vl_logic;
        h_ready         : out    vl_logic;
        h_valid         : out    vl_logic;
        h_done          : out    vl_logic;
        n_req           : in     vl_logic;
        n_addr          : in     vl_logic_vector(27 downto 0);
        n_len           : in     vl_logic_vector(4 downto 0);
        n_space         : in     vl_logic;
        n_ready         : out    vl_logic;
        n_valid         : out    vl_logic;
        n_done          : out    vl_logic;
        f_req           : in     vl_logic;
        f_addr          : in     vl_logic_vector(27 downto 0);
        f_ready         : out    vl_logic;
        f_valid         : out    vl_logic;
        f_done          : out    vl_logic;
        araddr          : out    vl_logic_vector(27 downto 0);
        arlen           : out    vl_logic_vector(3 downto 0);
        arid            : out    vl_logic_vector(3 downto 0);
        arvalid         : out    vl_logic;
        arready         : in     vl_logic;
        rvalid          : in     vl_logic;
        rlast           : in     vl_logic;
        rid             : in     vl_logic_vector(3 downto 0);
        fault           : out    vl_logic
    );
end raw8_read_arbiter;
