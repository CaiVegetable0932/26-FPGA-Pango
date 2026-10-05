library verilog;
use verilog.vl_types.all;
entity geometry_lens_lut is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        start           : in     vl_logic;
        build_bank      : in     vl_logic;
        model           : in     vl_logic_vector(1 downto 0);
        k1              : in     vl_logic_vector(31 downto 0);
        k2              : in     vl_logic_vector(31 downto 0);
        k3              : in     vl_logic_vector(31 downto 0);
        k4              : in     vl_logic_vector(31 downto 0);
        busy            : out    vl_logic;
        done            : out    vl_logic;
        failed          : out    vl_logic;
        read_bank       : in     vl_logic;
        read_index      : in     vl_logic_vector(10 downto 0);
        scale0          : out    vl_logic_vector(31 downto 0);
        scale1          : out    vl_logic_vector(31 downto 0)
    );
end geometry_lens_lut;
