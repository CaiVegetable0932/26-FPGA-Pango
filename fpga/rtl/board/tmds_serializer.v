`timescale 1ns/1ps
// 模块用途：tmds_serializer 将一个已编码的 10-bit TMDS 符号串行化，并通过差分引脚输出。
// 接口约定：symbol 在 pixel_clk 域提供；serial_clk 必须与 pixel_clk 同源且为其 5 倍频，
// 通过双沿串行输出传输每像素的 10 位；reset 为高有效，局部复位在像素域同步释放。
// 来源：主从级联接法依据 MINI 2_10_hdmi_loop/source/outputserdes.v，只修改本项目封装。
// 当前边界：本模块不生成 RGB 到 TMDS 的编码、消隐符号或行场时序；符号内容由调用方负责。
module tmds_serializer(input wire pixel_clk, input wire serial_clk,
    input wire reset, input wire [9:0] symbol,
    output wire data_p, output wire data_n);
    wire serial_data, cascade0, cascade1;
    // 每通道设置一个靠近主从 I/O 逻辑单元的复位释放寄存器。上游只在原生
    // IOCLKDIV 完成启动序列后解除 reset；这里在 OCLKDIV/pixel_clk 上升沿同步
    // 解除。四条低扇出复位网由项目 RCF 优先布线，以满足相邻串行边沿恢复时间。
    // 该做法沿用 MINI HDMI 参考设计的 ASYNC_RESET 原语模式且不屏蔽时序检查。
    (* syn_preserve = 1, syn_keep = 1 *) reg local_reset;
    always @(posedge pixel_clk or posedge reset)
        if (reset) local_reset <= 1'b1;
        else local_reset <= 1'b0;
    // 主串行器输出经 TMDS 差分缓冲送往一对引脚，实际电气适配仍需板级确认。
    GTP_OUTBUFDS #(.IOSTANDARD("TMDS")) output_buffer
        (.O(data_p), .OB(data_n), .I(serial_data));
    // 主 OSERDES 接收 symbol[7:0]，并从专用级联端口取得余下两位，产生完整 10:1 串行流。
    GTP_OSERDES_E2 #(.GRS_EN("TRUE"), .OSERDES_MODE("DDR10TO1"),
        .TSERDES_EN("FALSE"), .UPD0_SHIFT_EN("FALSE"), .UPD1_SHIFT_EN("FALSE"),
        .INIT_SET(2'b00), .GRS_TYPE_DQ("RESET"), .GRS_TYPE_TQ("RESET"),
        .LRS_TYPE_DQ0("ASYNC_RESET"), .LRS_TYPE_DQ1("ASYNC_RESET"),
        .LRS_TYPE_DQ2("ASYNC_RESET"), .LRS_TYPE_DQ3("ASYNC_RESET"),
        .LRS_TYPE_TQ0("ASYNC_RESET"), .LRS_TYPE_TQ1("ASYNC_RESET"),
        .LRS_TYPE_TQ2("ASYNC_RESET"), .LRS_TYPE_TQ3("ASYNC_RESET"),
        .TRI_EN("FALSE"), .TBYTE_EN("FALSE"), .MIPI_EN("FALSE"), .OCASCADE_EN("FALSE"))
    master(.RST(local_reset), .OCE(1'b1), .TCE(1'b0), .OCLKDIV(pixel_clk),
        .SERCLK(serial_clk), .OCLK(serial_clk), .MIPI_CTRL(1'b0),
        .UPD0_SHIFT(1'b0), .UPD1_SHIFT(1'b0), .OSHIFTIN0(cascade0),
        .OSHIFTIN1(cascade1), .DI(symbol[7:0]), .TI(8'b0), .TBYTE_IN(1'b0),
        .OSHIFTOUT0(), .OSHIFTOUT1(), .DO(serial_data), .TQ());
    // 从 OSERDES 将 symbol[9:8] 放入原生级联要求的 DI 位置，经 OSHIFTOUT0/1 送给主单元；
    // 从单元不直接连接差分输出，其余数据位和三态控制端按原生模板固定。
    GTP_OSERDES_E2 #(.GRS_EN("TRUE"), .OSERDES_MODE("DDR10TO1"),
        .TSERDES_EN("FALSE"), .UPD0_SHIFT_EN("FALSE"), .UPD1_SHIFT_EN("FALSE"),
        .INIT_SET(2'b00), .GRS_TYPE_DQ("RESET"), .GRS_TYPE_TQ("RESET"),
        .LRS_TYPE_DQ0("ASYNC_RESET"), .LRS_TYPE_DQ1("ASYNC_RESET"),
        .LRS_TYPE_DQ2("ASYNC_RESET"), .LRS_TYPE_DQ3("ASYNC_RESET"),
        .LRS_TYPE_TQ0("ASYNC_RESET"), .LRS_TYPE_TQ1("ASYNC_RESET"),
        .LRS_TYPE_TQ2("ASYNC_RESET"), .LRS_TYPE_TQ3("ASYNC_RESET"),
        .TRI_EN("FALSE"), .TBYTE_EN("FALSE"), .MIPI_EN("FALSE"), .OCASCADE_EN("TRUE"))
    slave(.RST(local_reset), .OCE(1'b1), .TCE(1'b0), .OCLKDIV(pixel_clk),
        .SERCLK(serial_clk), .OCLK(serial_clk), .MIPI_CTRL(1'b0),
        // 从单元未使用的级联输入必须按 MINI 原参考留空；这些专用引脚不能布线到普通逻辑地，
        // 不能为消除空端口而改接 1'b0，否则会破坏原生级联的可布线性。
        .UPD0_SHIFT(1'b0), .UPD1_SHIFT(1'b0), .OSHIFTIN0(), .OSHIFTIN1(),
        .DI({4'b0,symbol[9:8],2'b0}), .TI(8'b0), .TBYTE_IN(1'b0),
        .OSHIFTOUT0(cascade0), .OSHIFTOUT1(cascade1), .DO(), .TQ());
endmodule
