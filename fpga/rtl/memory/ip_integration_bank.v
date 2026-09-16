`timescale 1ns/1ps
// 模块用途：ip_integration_bank 为 12 个候选 FIFO、RAM、ROM 和 APM 运算 IP 提供构建集成连接，
// 将输出接到本域观察寄存器或 DDR 写数据口，使 PDS 能展开并综合相关依赖；未用逻辑仍可被优化。
// 接口与时钟：rx_data/rx_valid 属于 rx_clk，ddr_data/ddr_valid 属于 ddr_clk；FIFO 连接
// rx→proc、ddr↔proc、proc→tx/pixel 各域，每个域使用自身低有效复位。
// 当前边界：只接受候选 RX 字节与 DDR 读数据，没有合成帧、内存测试或网络流量发生器；
// 顶层目前关闭 PHY 和 DDR 地址请求，因此这些连接不代表真实视频处理或数据收发已实现。
// FIFO 多按非空直接读取，尚未实现端到端背压、流水延迟对齐及帧/包边界；不能当作无损业务通路。
// write_data 仅为数据，不产生 DDR 写请求；observe 为归约观察位，不是帧完整性或验收结果。
module ip_integration_bank(
    input wire proc_clk, input wire ddr_clk, input wire pixel_clk, input wire tx_clk,
    input wire rx_clk, input wire proc_reset_n, input wire ddr_reset_n,
    input wire pixel_reset_n, input wire tx_reset_n, input wire rx_reset_n,
    input wire [7:0] rx_data, input wire rx_valid,
    input wire [255:0] ddr_data, input wire ddr_valid,
    output wire [255:0] write_data,
    output reg proc_observe, output reg ddr_observe,
    output reg pixel_observe, output reg tx_observe
);
    wire [7:0] raw_data, packet_data;
    wire raw_full, raw_empty, packet_full, packet_empty;
    // raw_async_fifo：8-bit × 2048 异步队列，规划用于 RAW8 DVP 输入跨域。
    // 当前仅把 RX 候选字节从 rx_clk 送到 proc_clk，尚未接入摄像头 DVP 或帧标记。
    raw_async_fifo u_raw_fifo(.wr_clk(rx_clk), .wr_rst(!rx_reset_n),
        .wr_en(rx_valid && !raw_full), .wr_data(rx_data), .wr_full(raw_full),
        .rd_clk(proc_clk), .rd_rst(!proc_reset_n), .rd_en(!raw_empty),
        .rd_data(raw_data), .rd_empty(raw_empty), .wr_water_level(),
        .rd_water_level(), .almost_full(), .almost_empty());
    // net_tx_fifo：8-bit × 4096 队列，将候选字节从处理域送到网口发送域。
    // 目前读出只进入 tx_observe，未连接 MAC/UDP 或 RGMII 发送口，也未加入报文边界。
    net_tx_fifo u_packet_fifo(.wr_clk(proc_clk), .wr_rst(!proc_reset_n),
        .wr_en(!raw_empty && !packet_full), .wr_data(raw_data), .wr_full(packet_full),
        .rd_clk(tx_clk), .rd_rst(!tx_reset_n), .rd_en(!packet_empty),
        .rd_data(packet_data), .rd_empty(packet_empty), .almost_full(), .almost_empty());
    wire [31:0] read_data, line_data, cache_data, param_a, param_b, display_data;
    wire read_full, read_empty, write_full, write_empty, display_full, display_empty;
    // ddr_read_fifo：将 DDR 域 256-bit 读返回跨域并拆成处理域 32-bit 字；本模块不发起读事务。
    ddr_read_fifo u_read_fifo(.wr_clk(ddr_clk), .wr_rst(!ddr_reset_n),
        .wr_en(ddr_valid && !read_full), .wr_data(ddr_data), .wr_full(read_full),
        .rd_clk(proc_clk), .rd_rst(!proc_reset_n), .rd_en(!read_empty),
        .rd_data(read_data), .rd_empty(read_empty), .almost_full(), .almost_empty());
    // ddr_write_fifo：将处理域 32-bit 字合并为 DDR 域 256-bit 数据，接回顶层控制器的数据口。
    // 当前按非空直接读出，尚无 AXI 写地址、写就绪或突发调度配合，不构成 DDR 写入验证。
    ddr_write_fifo u_write_fifo(.wr_clk(proc_clk), .wr_rst(!proc_reset_n),
        .wr_en(!read_empty && !write_full), .wr_data(read_data), .wr_full(write_full),
        .rd_clk(ddr_clk), .rd_rst(!ddr_reset_n), .rd_en(!write_empty),
        .rd_data(write_data), .rd_empty(write_empty), .almost_full(), .almost_empty());
    // 观察用样本地址：读 FIFO 非空时递增并自然回绕，不表示像素坐标、行号或帧号。
    reg [14:0] sample_addr;
    always @(posedge proc_clk or negedge proc_reset_n)
        if (!proc_reset_n) sample_addr <= 15'b0;
        else if (!read_empty) sample_addr <= sample_addr + 1'b1;
    // isp_line_ram：2048 × 32-bit 简单双口 RAM，作为后续 ISP 行存储的候选资源。
    // 当前读写同一截断地址，仅保留存储连接；尚未实现多行窗口、边缘处理或有效数据对齐。
    isp_line_ram u_line_ram(.wr_clk(proc_clk), .wr_rst(!proc_reset_n),
        .wr_en(!read_empty), .wr_addr(sample_addr[10:0]), .wr_data(read_data),
        .rd_clk(proc_clk), .rd_rst(!proc_reset_n),
        .rd_addr(sample_addr[10:0]), .rd_data(line_data));
    // tile_cache_ram：32768 × 32-bit（128 KiB）候选 Tile 数据存储。
    // 当前按 sample_addr 读写，没有缓存标签、命中判断、分 bank 仲裁或替换策略。
    tile_cache_ram u_cache_ram(.wr_clk(proc_clk), .wr_rst(!proc_reset_n),
        .wr_en(!read_empty), .wr_addr(sample_addr), .wr_data(read_data),
        .rd_clk(proc_clk), .rd_rst(!proc_reset_n), .rd_addr(sample_addr), .rd_data(cache_data));
    // parameter_ram：1024 × 32-bit 真双口存储，预留系数、查表和控制参数访问能力。
    // 当前 A 口由 RAW 队列非空使能写入 read_data，B 口只读，均为集成占位连接；
    // 尚无参数下载或按帧生效协议，不能把这里的写入当作有效标定参数更新。
    parameter_ram u_parameter_ram(.a_clk(proc_clk), .a_rst(!proc_reset_n),
        .a_wr_en(!raw_empty), .a_addr(sample_addr[9:0]), .a_wr_data(read_data), .a_rd_data(param_a),
        .b_clk(proc_clk), .b_rst(!proc_reset_n), .b_wr_en(1'b0),
        .b_addr(read_data[9:0]), .b_wr_data(32'b0), .b_rd_data(param_b));
    wire [7:0] gamma_data;
    // gamma_rom：512 × 8-bit ROM，sample_addr[0] 选择两页之一，raw_data 为页内地址。
    // 两页均为 identity 初始化，只用于 LUT 资源集成，不代表 Gamma 标定或完整 ISP。
    gamma_rom u_gamma_rom(.clk(proc_clk), .rst(!proc_reset_n),
        .addr({sample_addr[0],raw_data}), .rd_data(gamma_data));
    wire [42:0] geometry_product;
    wire [27:0] interpolation_sum;
    wire [47:0] accumulated_product;
    // geometry_mult：带流水寄存的有符号 25 × 18 乘法器，输出 43-bit 候选坐标乘积。
    // 此处以 RAM 数据切片作输入，尚未实现坐标公式、定点缩放或畸变映射。
    geometry_mult u_geometry_mult(.clk(proc_clk), .rst(!proc_reset_n), .ce(1'b1),
        .a(line_data[24:0]), .b(param_a[17:0]), .p(geometry_product));
    // bilinear_multadd：两路 18 × 9 乘积相加，输出 28-bit，预留插值运算基本单元。
    // 当前输入是观察用数据切片，尚非完整四邻域双线性插值，也未做权重归一化或像素裁剪。
    bilinear_multadd u_bilinear_multadd(.clk(proc_clk), .rst(!proc_reset_n), .ce(1'b1),
        .a0(cache_data[17:0]), .a1(param_b[17:0]), .b0(read_data[8:0]),
        .b1(read_data[17:9]), .p(interpolation_sum));
    // statistics_mac：16 × 16 乘法及 48-bit 累加，读队列非空时推进，复位初始化为零。
    // 当前没有帧边界清零、统计区域或结果锁存协议，输出不代表已完成图像质量测评。
    statistics_mac u_statistics_mac(.clk(proc_clk), .rst(!proc_reset_n), .ce(!read_empty),
        .a(read_data[15:0]), .b(read_data[31:16]), .acc_init(48'b0),
        .reload(!proc_reset_n), .p(accumulated_product));
    // display_fifo：32-bit × 2048 异步队列，将处理域候选显示字送到像素域。
    // 当前承接 cache_data 且仅供观察，尚未连接 RGB 解包、视频时序或 TMDS 编码器。
    display_fifo u_display_fifo(.wr_clk(proc_clk), .wr_rst(!proc_reset_n),
        .wr_en(!read_empty && !display_full), .wr_data(cache_data), .wr_full(display_full),
        .rd_clk(pixel_clk), .rd_rst(!pixel_reset_n), .rd_en(!display_empty),
        .rd_data(display_data), .rd_empty(display_empty), .almost_full(), .almost_empty());
    // 各观察值先在来源域寄存，再由顶层做单比特同步，避免直接跨域传输组合归约结果。
    // 异或可能掩盖同时变化，观察位不是计数器、校验和或帧完整性测量；不能作为通过/失败依据。
    // 处理域汇总存储与运算 IP 的输出，用于保留可观察的集成连接。
    always @(posedge proc_clk or negedge proc_reset_n)
        if (!proc_reset_n) proc_observe <= 1'b0;
        else proc_observe <= ^{geometry_product,interpolation_sum,accumulated_product,gamma_data,param_a,param_b,line_data,cache_data};
    // DDR 域观察打包后数据与队列空标志，不表示控制器已接受写入或读回内容正确。
    always @(posedge ddr_clk or negedge ddr_reset_n)
        if (!ddr_reset_n) ddr_observe <= 1'b0;
        else ddr_observe <= ^write_data ^ write_empty;
    // 像素域观察显示队列读出；与顶层固定 HDMI 符号输出之间没有业务数据连接。
    always @(posedge pixel_clk or negedge pixel_reset_n)
        if (!pixel_reset_n) pixel_observe <= 1'b0;
        else pixel_observe <= ^display_data ^ display_empty;
    // 发送域观察候选字节队列，不代表 PHY 链路建立、报文送达或吞吐达标。
    always @(posedge tx_clk or negedge tx_reset_n)
        if (!tx_reset_n) tx_observe <= 1'b0;
        else tx_observe <= ^packet_data ^ packet_empty;
endmodule
