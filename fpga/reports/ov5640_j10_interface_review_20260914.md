# OV5640 DVP 模组与 100K MINI 的 40-pin 接口核对

核对日期：2026-09-14。分支：`codex/fpga-pds-project`。

## 结论与适用范围

选择底板 **J10**，按单路 RAW8 基线先接入模组 **CAM1**，即 MINI 参考例程中的 `camera_0`。本结论针对参考资料中的官方 `DOUBLE_DVP_OV5640` 双目扩展模组及其 `J17 / PH2.54_40` 连接器，不代表所有第三方 OV5640 板都可直接对插；实物型号或排针定义不同时必须重新核对。

这是资料和现有工程的静态核对，不是电气实测或采集验证。本轮未操作 JTAG、下载、上电或运行新测试，也未解除此前上板测试暂停状态。

## 为什么选择 J10

| 40-pin 接口 | 核对结果 |
| --- | --- |
| J10 | 100H/200H 共用。参考双目例程的两路相机引脚均对应此口；CAM1 的 14 根信号全部位于 Bank L5，PCLK 使用 L22 的 GSCLK 功能脚。优先选择。 |
| J25 | 100H/200H 共用，但对应另一组 FPGA 管脚，不可原封不动套用 J10 约束。手册第 38 页把 37 脚写作 V14，而模组 J17 的 37 脚接 GND，存在待核实表项；不能擅自当成笔误后批准对插。该口信号涉及 Bank L6，另须核实实际 Bank 供电。 |
| J26 | 手册明确为 PG2L200H 专用，不作为当前 PG2L100H 的相机接口。 |

J10 不是所有信号都属于 Bank L5；其部分扩展信号、包括 CAM2 的若干信号属于 Bank L6。这里只确认 CAM1 的 14 根已使用信号均在 L5。手册第 41 页说明 J20 选择 Bank L6/L7 的 3.3V 或 VADJ 供电，J24 决定 VADJ 的 2.5V/1.8V；本轮没有改动跳线，也没有以软件约束代替实际供电确认。

## CAM1 对应关系

以下 D0–D7 采用模组原理图的八位总线命名，不重新解释成裸传感器封装脚号。模组 CAM1 对应其 FPC 接口 J4；CAM2 对应模组 J5。

| 模组信号 | J10 针号 | FPGA 球位 | MINI 例程端口 |
| --- | --- | --- | --- |
| CAM1_PCLK | 18 | L22 | camera_clk_0 |
| CAM1_VSYNC | 17 | L23 | camera_vsync_0 |
| CAM1_HREF | 9 | T25 | camera_href_0 |
| CAM1_D0 | 8 | M24 | camera_data_0[0] |
| CAM1_D1 | 11 | R22 | camera_data_0[1] |
| CAM1_D2 | 13 | K26 | camera_data_0[2] |
| CAM1_D3 | 14 | K25 | camera_data_0[3] |
| CAM1_D4 | 7 | M25 | camera_data_0[4] |
| CAM1_D5 | 5 | N19 | camera_data_0[5] |
| CAM1_D6 | 10 | T24 | camera_data_0[6] |
| CAM1_D7 | 3 | R21 | camera_data_0[7] |
| CAM1_SCL | 6 | P19 | SCL_0 |
| CAM1_SDA | 4 | R20 | SDA_0 |
| CAM1_REST | 12 | T22 | cam_rst_0 |

实际为 **14 根信号**：8 根数据、3 根同步/像素时钟、2 根 SCCB、1 根复位。按 `fpga/config/board.json` 的现有时钟、HDMI、网口、LED、复位与 DDR 分配逐项比对，交集为零。以上仅是拟接入的对应关系；当前工程尚无这些相机顶层端口和正式约束。

## 电源与插接方向

- J10 的 1、37、38 脚为 GND；39、40 脚为 A3V3，与模组 J17 原理图对应。
- J10 的 2 脚为 A5V0，而该版模组 J17 的 2 脚未连接。模组由 39/40 脚的 3.3V 供电，不能把 5V 接到模组 3.3V 或 DVP/SCCB 信号上。
- 按底板 V1.0 点位图，以网口和 HDMI 在右侧为参照，J10 是上边靠近 JTAG 的横向 40-pin 排针；其 1 脚为靠 JTAG 一端的方形焊盘。以实物丝印和 1 脚标记为准，模组 J17 的 1 脚对应 J10 的 1 脚，不凭镜头朝向或插座缺口猜测方向。
- 插拔必须在断电状态进行。实物版本和供电状态未核实前，不把本记录当作再次上电批准。

模组原理图中的 U27 提供 24 MHz XCLK，不通过 40-pin 口要求 FPGA 另送 XCLK。CAM1/CAM2 的 PWDN 由板上电阻下拉，未引到 J17；仅在逻辑上不用 CAM2 不等于另一只相机已经断电。SCCB 上拉到各自的 2.8V，相机 DOVDD 也为 2.8V；后续实现须核对输入门限、输出耐压与开漏控制，不能因示例写 LVCMOS33 就把整块模组当成 3.3V/5V 任意兼容 IO。

## 后续开发边界

先完成 CAM1 的安全复位/SCCB 配置、器件身份读取、RAW8 DVP 采集与帧计数，再接入异步 FIFO 和后续视频链路。单路选择不改变既定 S0 千兆网和 FPGA 处理后 HDMI 输出架构。参考示例不直接作为本项目 RAW8 1080p30 已完成的证明。

本次没有修改 RTL、IP、PDS 工程或引脚约束，没有重新编译或上板，也没有提交/推送 Git 改动。此前报告暂存范围保持不动。

## 核对来源

1. [MINI 硬件手册 V1.3](../../reference/盘古100K200K%20MINI开发板/1_Demo_document/实验例程说明篇/教程1_盘古MINI系列开发板硬件指导手册_V1.3.pdf)：第 21–22 页球位/Bank/时钟功能，第 36–38 页 J10/J25/J26，第 41 页可调供电。
2. [DOUBLE-DVP-OV5640-1113 原理图](../../reference/OV5640双目摄像头资料/原理图/DOUBLE-DVP-OV5640-1113.pdf)：单页 J17、两路 FPC、24 MHz 时钟、供电、SCCB 上拉和 PWDN。
3. [MINI 双目示例约束](../../reference/盘古100K200K%20MINI开发板/2_Demo/5_1%20双目摄像头例程/ov5640_200k/ov5640.fdc)：只用于交叉核对相机接口，不把 200K 工程直接当成 100K 实现。
4. [底板 V1.0 点位图](../../reference/盘古100K200K%20MINI开发板/3_Hardware/点位图/MES-PG2L676-Mini%20Base-V1.0_PCB元件位置图.pdf)：J10/J25/J26 位置与方形焊盘。
5. [当前工程 board.json](../config/board.json)：已有管脚冲突检查。

补充查阅 PDS 2022.2-SP6.4 的 `Physical_Constraint_Editor_User_Guide.pdf` 第 24 页 I/O Table 定义。原始路径为 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Physical_Constraint_Editor_User_Guide.pdf`，先复制到 `fpga/build/interface_review_20260914/` 后读取，副本内容未改。参考 PDF 的必要页面已在同一检查目录的 `tmp/pdfs/` 下渲染并视觉核查；不在官方或 reference 目录写入文件。
