`timescale 1ns/1ps
// 模块用途：rgmii_phy_io 使用 Logos2 原生 IDDR/ODDR，在 RGMII 四位双沿接口与八位字节间转换。
// 时钟与复位：接收数据属于 PHY 提供的 rx_clk 域，发送数据属于 tx_clk 域（当前配置 125 MHz）；
// reset 为高有效，接收原语采用同步复位，发送原语采用异步复位，两域数据未在本模块内互跨。
// 来源：原语用法依据 MINI 2_11_ethernet_test 例程；参考源保持只读。
// 当前边界：仅物理 I/O 层，不含 MAC、帧校验、MDIO 或速率协商；未验证 PHY 延时/strap 模式，
// 顶层保持 PHY 复位，不能把本模块的存在当作千兆网收发已通过验证。
module rgmii_phy_io(
    input wire tx_clk, input wire reset,
    input wire [7:0] tx_data, input wire tx_valid,
    input wire rgmii_rxc, input wire [3:0] rgmii_rxd, input wire rgmii_rx_ctl,
    output wire rx_clk, output wire [7:0] rx_data, output wire rx_valid,
    output wire rx_error,
    output wire rgmii_txc, output wire [3:0] rgmii_txd, output wire rgmii_tx_ctl
);
    // 把 PHY 源同步接收时钟接入全局时钟网络；缓冲本身不完成到系统/处理域的 CDC。
    GTP_CLKBUFG rx_clock_buffer(.CLKIN(rgmii_rxc), .CLKOUT(rx_clk));
    wire [3:0] rising_data, falling_data;
    wire control_rising, control_falling;
    genvar i;
    // 四条数据线分别做 DDR 转换：接收上升沿为低半字节、下降沿为高半字节；发送对应拆分。
    // SAME_PIPELINED 接收模式将两沿样本对齐到 rx_clk 域，后续逻辑使用下方拼接后的字节。
    generate for (i=0; i<4; i=i+1) begin: lane
        GTP_IDDR_E1 #(.GRS_EN("TRUE"), .IDDR_MODE("SAME_PIPELINED"), .RS_TYPE("SYNC_RESET"))
            rx_ddr(.Q0(rising_data[i]), .Q1(falling_data[i]), .CE(1'b1),
                   .CLK(rx_clk), .D(rgmii_rxd[i]), .RS(reset));
        GTP_ODDR_E1 #(.GRS_EN("TRUE"), .ODDR_MODE("SAME_EDGE"), .RS_TYPE("ASYNC_RESET"))
            tx_ddr(.Q(rgmii_txd[i]), .CE(1'b1), .CLK(tx_clk),
                   .D0(tx_data[i]), .D1(tx_data[i+4]), .RS(reset));
    end endgenerate
    // RX_CTL 与数据采用相同采样模式；上升沿提供有效位，两沿异或恢复接收错误位。
    GTP_IDDR_E1 #(.GRS_EN("TRUE"), .IDDR_MODE("SAME_PIPELINED"), .RS_TYPE("SYNC_RESET"))
        rx_control(.Q0(control_rising), .Q1(control_falling), .CE(1'b1),
                   .CLK(rx_clk), .D(rgmii_rx_ctl), .RS(reset));
    assign rx_data = {falling_data, rising_data};
    assign rx_valid = control_rising;
    assign rx_error = control_rising ^ control_falling;
    // 两沿都发送 tx_valid，等效于发送错误位固定为 0；当前接口不支持显式注入 TX_ER。
    GTP_ODDR_E1 #(.GRS_EN("TRUE"), .ODDR_MODE("SAME_EDGE"), .RS_TYPE("ASYNC_RESET"))
        tx_control(.Q(rgmii_tx_ctl), .CE(1'b1), .CLK(tx_clk),
                   .D0(tx_valid), .D1(tx_valid), .RS(reset));
    // 用同一发送时钟的 ODDR 转发 TXC；此处没有增加板级偏移，接口延时须另行配置和签核。
    GTP_ODDR_E1 #(.GRS_EN("TRUE"), .ODDR_MODE("SAME_EDGE"), .RS_TYPE("ASYNC_RESET"))
        tx_clock(.Q(rgmii_txc), .CE(1'b1), .CLK(tx_clk),
                 .D0(1'b1), .D1(1'b0), .RS(reset));
endmodule
