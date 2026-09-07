library verilog;
use verilog.vl_types.all;
entity V_PGL35ESOCIF is
    generic(
        DEVICE_SOC      : string  := "SOC1"
    );
    port(
        VIRTUAL_HCLK_FPGA: in     vl_logic;
        HCLK_FPGA       : out    vl_logic;
        HRESET_FPGA     : out    vl_logic;
        SRB30_CTL_OUT   : in     vl_logic_vector(5 downto 0);
        SRB30_DATA_OUT  : in     vl_logic_vector(47 downto 0);
        SRB31_CTL_OUT   : in     vl_logic_vector(5 downto 0);
        SRB31_DATA_OUT  : in     vl_logic_vector(47 downto 0);
        SRB32_CTL_OUT   : in     vl_logic_vector(5 downto 0);
        SRB32_DATA_OUT  : in     vl_logic_vector(47 downto 0);
        SRB33_CTL_OUT   : in     vl_logic_vector(5 downto 0);
        SRB33_DATA_OUT  : in     vl_logic_vector(47 downto 0);
        SRB34_CTL_OUT   : in     vl_logic_vector(5 downto 0);
        SRB34_DATA_OUT  : in     vl_logic_vector(47 downto 0);
        SRB35_DATA_OUT  : in     vl_logic_vector(47 downto 0);
        SRB36_DATA_OUT  : in     vl_logic_vector(47 downto 0);
        SRB37_DATA_OUT  : in     vl_logic_vector(47 downto 0);
        SRB38_DATA_OUT  : in     vl_logic_vector(47 downto 0);
        ADC0_FPGA_ADCRDY: out    vl_logic;
        ADC0_FPGA_B     : out    vl_logic_vector(11 downto 0);
        ADC0_FPGA_CLKOUT: out    vl_logic;
        ADC0_FPGA_RFLAG : out    vl_logic_vector(2 downto 0);
        ADC1_FPGA_ADCRDY: out    vl_logic;
        ADC1_FPGA_B     : out    vl_logic_vector(11 downto 0);
        ADC1_FPGA_CLKOUT: out    vl_logic;
        ADC1_FPGA_RFLAG : out    vl_logic_vector(2 downto 0);
        ADC2_FPGA_ADCRDY: out    vl_logic;
        ADC2_FPGA_B     : out    vl_logic_vector(11 downto 0);
        ADC2_FPGA_CLKOUT: out    vl_logic;
        ADC2_FPGA_RFLAG : out    vl_logic_vector(2 downto 0);
        ADC3_FPGA_ADCRDY: out    vl_logic;
        ADC3_FPGA_B     : out    vl_logic_vector(11 downto 0);
        ADC3_FPGA_CLKOUT: out    vl_logic;
        ADC3_FPGA_RFLAG : out    vl_logic_vector(2 downto 0);
        DMA_RX_ACK_FPGA : out    vl_logic;
        DMA_TX_ACK_FPGA : out    vl_logic;
        FPGA_M_HRDATA   : out    vl_logic_vector(31 downto 0);
        FPGA_M_HREADYIN : out    vl_logic;
        FPGA_M_HRESP    : out    vl_logic_vector(1 downto 0);
        FPGA_S_HADDR    : out    vl_logic_vector(31 downto 0);
        FPGA_S_HBURST   : out    vl_logic_vector(2 downto 0);
        FPGA_S_HREADYIN : out    vl_logic;
        FPGA_S_HSEL     : out    vl_logic;
        FPGA_S_HSIZE    : out    vl_logic_vector(2 downto 0);
        FPGA_S_HTRANS   : out    vl_logic_vector(1 downto 0);
        FPGA_S_HWDATA   : out    vl_logic_vector(31 downto 0);
        FPGA_S_HWRITE   : out    vl_logic;
        SCTL_SERDES_TO_FPGA: out    vl_logic_vector(141 downto 0);
        SRIO_SERDES_TO_FPGA: out    vl_logic_vector(136 downto 0)
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of DEVICE_SOC : constant is 1;
end V_PGL35ESOCIF;
