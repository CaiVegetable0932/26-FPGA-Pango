library verilog;
use verilog.vl_types.all;
entity mini_diag_snapshot is
    port(
        src_clk         : in     vl_logic;
        src_reset_n     : in     vl_logic;
        dst_clk         : in     vl_logic;
        dst_reset_n     : in     vl_logic;
        source          : in     vl_logic_vector(159 downto 0);
        snapshot        : out    vl_logic_vector(159 downto 0)
    );
end mini_diag_snapshot;
