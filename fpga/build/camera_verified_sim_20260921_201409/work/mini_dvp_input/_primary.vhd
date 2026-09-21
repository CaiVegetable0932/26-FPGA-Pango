library verilog;
use verilog.vl_types.all;
entity mini_dvp_input is
    port(
        clk             : in     vl_logic;
        reset_n         : in     vl_logic;
        vsync           : in     vl_logic;
        href            : in     vl_logic;
        data            : in     vl_logic_vector(7 downto 0);
        sampled_vsync   : out    vl_logic;
        sampled_href    : out    vl_logic;
        sampled_data    : out    vl_logic_vector(7 downto 0)
    );
end mini_dvp_input;
