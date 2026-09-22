# 1080p RAW8 整板候选构建记录

分支：`codex/fpga-raw8-dual-output`；基线 main=`331f6078156aba7adabdf8422752d9847ee3a3e8`，本次不合并 main。器件 PG2L100H-6FBG676，PDS 2022.2-SP6.4 build 146967。

## 发布状态

2026-09-23 已生成**可用于首次上板验证的候选**，不是实机验收版本。整板原生综合、映射、布局布线、快慢角 STA 和同一 PNR 数据库的位流生成通过；离线 XT25F128 格式转换通过。本轮没有操作 JTAG、串口、网卡或 Flash，没有改变原先板卡固化内容。

- [Flash 文件 mini_raw8_dual.sfc](../release/raw8_dual_20260923_2197404297e4/mini_raw8_dual.sfc)；[SBIT](../release/raw8_dual_20260923_2197404297e4/mini_raw8_dual.sbit)。二者均 3,791,112 字节；原生转换在起始地址0下得到相同内容，SHA256 均为 `2197404297E45D3B3386D02FE69464460E6EE849D32E0FF190C1BF39AAFB0131`。
- [发布清单](../release/raw8_dual_20260923_2197404297e4/manifest.json)、[最终审计](../release/raw8_dual_20260923_2197404297e4/audit.json)、[最终 STA](../release/raw8_dual_20260923_2197404297e4/timing.rtr)。审计核对270项构建输入、图像哈希、两类完整帧仿真、转发时钟回归和整包跨域回归。
- [原生构建记录](../build/mini_raw8_dual/native_20260923_001028_899/result.json)。失败尝试均保留为诊断历史，不能用于烧录。

## 整板实现

入口：[mini_raw8_dual.pds](../project/mini_raw8_dual/mini_raw8_dual.pds)，由 [原生 Tcl](../project/mini_raw8_dual/mini_raw8_dual.tcl) 经 `tcl2prj` 生成，实施目录固定在 `fpga/build/mini_raw8_dual/implementation`。不手写 .pds 语法。

- `mini_raw8_dual`：J10 传感器、原生 DDR、HDMI 发送、RTL8211F/MDIO、RGMII、CP2102/MCU 状态顶层；无合成视频源。
- `raw8_capture_records`：摄像头域 START/WORD/END 有序记录，经 512×288 原生 FIFO 进入存储域；元数据不绕过像素字。
- `raw8_write_engine`：单笔写前锁存完整 256 bit，验证 WREADY/WLAST/WID；几何坏帧在先前写排空后丢弃，好帧最后一个字读回一致后发布。原生接口没有 BVALID，不能伪造写响应。
- `raw8_dual_core`：三个 RAW 帧槽、写 lease/epoch、两个独立读锁和读 DMA。无空槽持续申请；HDMI/网络故障排空前不释放槽。epoch 在帧开始前的槽分配处锁定，不能把配置前帧改成配置后身份。
- `raw8_read_arbiter`：非抢占式 HMIC 读，HDMI/网络轮转、末字栅栏优先；每 burst 预留 FIFO 空间，原生没有 RREADY。异常 RID/LAST 停止接受新事务，不用超时强行把旧返回数据给新读者。
- `raw8_hdmi_consumer`：垂直边界启帧、四相读锁交接；欠载黑掉本帧余下部分并排空，下一次重新取得完整帧，不重置单边 FIFO 指针。
- `raw8_network_output`：真实 RAW8 word 拆包，复用 PRAW/IP/UDP/MAC；接受帧后完成发送/故障排空，拒绝重复身份。RAW8 启动使用 0x71，ACK RAW8，描述符 0x38574152、param_version=1。
- `raw8_gmii_cdc`：把 MAC 数据每 32 字节打包进原生 512×288 FIFO，尾记录实际入队后才用 Gray 计数发布整包；独立 ETH125 域整包连续发送，保证包内无空隙、至少 12 个字节时钟 IFG。溢出或输入错误停止发布，双侧 FIFO 同时复位后恢复。
- `mcu_protocol`：新增 epoch 比较预解码和有容量预留的应答寄存级，拆开 125 MHz 的长应答/队列路径；线格式、会话与事件语义不变，实际 MCU 接线仍未确认。

逻辑 DDR 槽 0x03000000/0x03400000/0x03800000，每槽 4 MiB，stride=2048。只写/读每行 1920 字节，padding 未定义、不输出。HMIC 物理列地址=字节地址>>2，每 256-bit beat 前进 8 列；每行 16+16+16+12 beat，不能跨 1024 列边界。

## 已执行验证

- [六帧完整核心仿真](../build/raw8_board_sim_20260923_001217_827/result.json)：6 帧发布、6 帧网络、8892 包、5 帧 HDMI 逐像素通过、欠载为 0；388800 次写、6 次末字栅栏。PDS 原生 FIFO 模型，延迟/停顿 HMIC 行为内存模型，摄像头/存储/HDMI/以太网四个独立时钟，模拟临时无槽后恢复。host 校验的是整包 GMII 跨域桥之后的数据。
- [配置晚到边界仿真](../build/raw8_board_sim_20260923_001217_827/late_epoch_result.json)：配置在首帧已开始但 START 记录仍跨域时到达；首帧仍属于 epoch=0，被网络拒绝。随后 5 帧、7410 包全部经 GMII 跨域桥后由真实 host 重组器逐像素核对；HDMI 5 帧通过，不把配置前帧改名重发。
- [模块与故障回归](../build/raw8_dual_sim_20260922_225234_592/result.json)：完整1080p、摄像头配置正常/ID错误/NACK/回读错误，短长行/多余行/背压拒帧、池/读地址检查；新增 native_contracts 检查坏帧写排空后释放、错误 WLAST 停止、无信用不读、burst 不抢占、错误 RID 停止。
- [MCU 新流水回归](../build/mcu_protocol_20260922_230058_713/result.json)：完整滥用测试及 125 MHz/115200 UART 回归通过，后者 2235 项断言、23 应答、3 环境事件。
- [RAW8 Boot](../build/comms_board_sim/boot_20260922_222921_430/result.json) / [TEST Boot](../build/comms_board_sim/boot_20260922_222924_973/result.json)：各334项断言、7次应答；互拒另一种启动命令、CRC/长度/地址/不可变配置/ACK标记和最终停止位通过。
- [连续 TXC 原生模型回归](../build/raw8_rgmii_clock_20260922_234233_435/result.json)：6266 项检查、1024 组数据、4 次局部复位通过；局部复位只清零 RGMII 数据/控制，转发时钟保持 8 ns 周期，不在 FPGA 再加相移。该测试未模拟 PLL 或外部电气。
- [整包跨时钟原生 FIFO 回归](../build/raw8_gmii_cdc_20260923_000952_209/result.json)：读时钟半周期 3.9/4.1 ns 两种场景，各 81 包逐字节、包间隔、包内连续性、输入错误停发及双侧复位恢复通过；覆盖 1/31/32/33/60/64/1460/1526 字节包。上述整板测试已在跨域桥之后重新核对完整 PRAW 图像。
- [host Python](../../host/reports/raw8_candidate_host_tests_20260922.log)：74 项通过。[前端测试](../../host/reports/raw8_candidate_browser_tests_20260922.log)：像素、记录、视频设备选择三个测试脚本通过，包含1080p逐采样灰阶。

以上 RAW 内容均为**仿真激励**，不是实测视频。本次不上传实测视频。原生 FIFO 模型保留零次重复及未选分支越界警告；未修改官方模型或生成 HDL。HMIC 行为模型并非 DDR3 PHY、电气或时序仿真。

## 时序与参考依据

只读核对官方 `doc/Pango_Design_Suite_User_Guide.pdf` 的时钟/输入延迟/max-delay/false-path说明，UCE IO 属性说明和本机 `pnr -help`。HMIC 原生依据 `ip/system_ip/ips2l_hmic_s/ips2l_hmic_eval/ips2l_hmic_s/UG042003_Logos2_HMIC_S_IP.pdf` 第31–37、58页。板卡引脚沿用已核对的 MINI J10/DDR/GE/UART 约束；传感器只读依据 reference 的 OV5640 datasheet v2.01（8-5表不提供 DVP pad 数据偏斜的完整签核值）。

HMIC core_clk=125 MHz 管 DDR、UART、MDIO 和 MAC；独立原生 comms_pll 提供 ETH125，整包 FIFO 跨到 RGMII 域。两个 FIFO 复位在时钟失锁时一起断言，各域同步释放。27 MHz 管 SCCB；HDMI 74.25/371.25 MHz 复用原生 PLL+IOCLKDIV，HDMI 本地复位恢复/移除检查保留。PCLK 按保守 100 MHz 内部预算分析，传感器候选名义84 MHz。

跨时钟只约束实际一级状态同步器/原生 Gray 指针，6 ns 数据路径上限；不把摄像头/HDMI/存储域整体 false-path。DDR 就绪只到异步复位链的路径例外，链内同步释放和后续 fanout 保持检查。

RGMII PHY TXID=2 ns，双边沿±1.45 ns外部预算、时钟不确定度保持；板上偏斜尚未实测。旧失败报告保留：首轮约束层级/大小写修正，第二轮 MCU 应答负裕量及 RGMII hold 失败；`OUT_DELAY=0` 在当前原生映射中并非旁路，已撤销，不能把数字0猜成无延时。

整板 TXC 使用连续转发：原生 GRS 初始化常量 1/0 ODDR，不再增加 fabric 局部复位输入；PHY 自身复位与 RGMII 数据/控制复位仍保留。原生路由后网表/SDF 在独立诊断目录导出；诊断探针结果不能充当发布时序签核。

直接使用 DDR 反馈时钟驱动 RGMII 的多轮试验未通过外部 hold，改换时钟源点、去除 TXC 局部复位或分段建模均未解决，因此最终实现改用独立网络 PLL，不以这些试验约束发布。原有±1.45 ns外部预算未放宽。位流导出使用本机 `gen_bit_stream -input_db_file`，只从通过 STA 的同一 PNR 数据库生成，避免再次布线改变签核对象。

最终报告为 **All Constraints Met**，建立/保持/恢复/移除/最小脉宽均覆盖快、慢角；RGMII 每项检查均含5根数据/控制线，无遗漏端点。关键裕量（ns）：

| 检查 | Slow | Fast |
| --- | ---: | ---: |
| RGMII setup | 0.144 | 0.148 |
| RGMII hold | 0.142 | 0.138 |
| 全设计最小 setup | 0.144 | 0.148 |
| 全设计最小 hold | 0.135 | 0.100 |
| 全设计最小 recovery | 0.027 | 0.495 |
| 全设计最小 removal | 0.193 | 0.126 |

恢复时间最小裕量只有0.027 ns（pixel→serial），未将该路径设为例外；它是需关注的窄裕量，不是宽裕的实机电气保证。布线占用 CLMA 2835/11675、CLMS 1253/4975、DRM 17/155、GPLL 4/6、APM 1/240。PDS 全局布局利用率约19%，不能把它与各类资源百分比混为一项。

本轮完整功能测试采用独立理想时钟、原生 FIFO/ODDR 模型和 HMIC 行为模型；未执行覆盖所有原生 PLL、DDR PHY 和外部器件的电气启动仿真。独立网络 PLL 配置复用已有网口工程，新整板仍必须首次上板核对。

## 尚待上板验收

真实 RAW 格式/1920×1080/30fps、DVP pad 时序裕量、DDR 混合读写实测、RGMII 时钟数据偏斜、HDMI 电气与采集卡协商、遮挡来源证明、完整网络帧率、长时间稳定性/功耗均未验收。临时 HDMI 是 RAW 采样复制到 RGB，不是 Y8/ISP S1/矫正 S2/S3；Bayer 相位未实测，HDMI source_frame_id=null/unverified，严格同帧测评关闭。

启动/接收/LED及证据保存见 [host 操作说明](../../host/docs/RAW8双路候选启动与预览.md)。已知恢复镜像仍保留：`build/camera_div2_flash_20260921/Top.sfc`，SHA256 `317733DFC9A6D083971E2E09B203E403B8939E6163B33BD7EAB32667048CFAAC`。Flash 写入、回读校验和断电冷启动是三个后续独立步骤，本轮均未执行。
