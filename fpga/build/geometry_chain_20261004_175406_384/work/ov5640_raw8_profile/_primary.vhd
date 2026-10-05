library verilog;
use verilog.vl_types.all;
entity ov5640_raw8_profile is
    port(
        index           : in     vl_logic_vector(6 downto 0);
        value           : out    vl_logic_vector(23 downto 0);
        last            : out    vl_logic
    );
end ov5640_raw8_profile;
