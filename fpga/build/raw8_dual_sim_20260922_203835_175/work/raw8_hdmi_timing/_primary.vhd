library verilog;
use verilog.vl_types.all;
entity raw8_hdmi_timing is
    port(
        clk             : in     vl_logic;
        reset_n         : in     vl_logic;
        enable          : in     vl_logic;
        sample          : in     vl_logic_vector(7 downto 0);
        sample_valid    : in     vl_logic;
        sample_ready    : out    vl_logic;
        hsync           : out    vl_logic;
        vsync           : out    vl_logic;
        de              : out    vl_logic;
        frame_boundary  : out    vl_logic;
        rgb             : out    vl_logic_vector(23 downto 0);
        underflows      : out    vl_logic_vector(31 downto 0)
    );
end raw8_hdmi_timing;
