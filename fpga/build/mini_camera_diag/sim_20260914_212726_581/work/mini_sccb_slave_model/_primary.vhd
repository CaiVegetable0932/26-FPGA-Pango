library verilog;
use verilog.vl_types.all;
entity mini_sccb_slave_model is
    port(
        reset_n         : in     vl_logic;
        scl             : in     vl_logic;
        sda             : inout  vl_logic;
        ack_mask        : in     vl_logic_vector(3 downto 0);
        starts          : out    integer;
        stops           : out    integer;
        bytes           : out    integer;
        packet          : out    vl_logic_vector(31 downto 0)
    );
end mini_sccb_slave_model;
