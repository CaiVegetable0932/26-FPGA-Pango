# 02 摄像头输入分区优化与验证

日期：2026-10-12。依据[02方案](../../output/FPGA分区优化交接/02_摄像头输入优化方案.md)、[总览](../../output/FPGA分区优化交接/README.md)及[150 Hz专项](../../output/OV5640_150Hz_PWM照明防条纹专项优化交接.md)。优先级性能 > 时序 > 资源；这里只报告实际执行的局部验证。

本轮新增明确RAW8采样/整帧判定、并行分流、独立停钟看门狗、运行期SCCB服务及RAW8寄存器实体提交。1920×1080合成RAW8逐字节通过、行内II=1；PG2L100H内部输入基准100MHz完成PnR并通过所声明内部约束。**未接入板级Top、正式异步FIFO、03/04帧池DMA或06 ISP；没有真实1080p30、光学PWM或来源身份验收结果。**

## 基线审计与落点

方案中“只写不可回读”是规划检查时快照，已被上一轮SCCB读取/固定PWM模式更新。本轮复用这些实现，保留原244项720p RGB565写表和诊断代码。其他分区正在修改共享Top/DDR/IP/工程，本轮遵守分区所有权，不改这些共享文件。

| 文件 | 新增能力 |
| --- | --- |
| `rtl/input/dvp_frame_receiver.v` | 同拍源同步采样后计数/打包；静态RAW8或RGB565格式，x/y/边界/phase/tag同进退；短/长行、缺/多行、坏边界、超时、溢出、就绪掉线/无令牌作废；实际VSYNC结束后seal资格 |
| `rtl/input/dvp_raw8_fanout.v` | RAW导出和ISP写侧队列独立admit/ready、整帧作废与计数；源不能背压；RAW过载不自动阻断ISP |
| `rtl/input/dvp_clock_watchdog.v` | 控制域通过分频toggle检测PCLK停钟，停钟后仍能发loss事件 |
| `rtl/input/ov5640_register_service.v` | 初始化独占、运行期查询与掩码写/回读；cookie锁存、忙拒绝、只读保护、排空检查及单事务期限 |
| `rtl/input/ov5640_raw8_mode.v` | 芯片ID和PLL旁路核验；43项明确实体写入/逐项核对，最后整组再读；不继承720p时钟常量；版本/实体仅在全组成功后生效 |
| `model/camera_input_budget.py` | 按峰值PCLK、最坏服务停顿、CDC/流水余量与打包位宽计算队列容量 |
| `model/ov5640_pwm_exposure.py` | 修正HTS高字节debug位不参与行时间换算；新增对应回归，其余PWM计算保留 |
| `config/ov5640_raw8_1080p.template.json` | 实测输入模板；XCLK/PCLK、PLL、裁剪、Bayer/有效位、服务停顿等保持null，避免把预算当实测 |
| `sim/tb_dvp_*.sv`、`tb_ov5640_*service*.sv`、`tb_ov5640_raw8_mode.sv` | 逐字节、异常、有限队列和控制组回归 |
| `project/camera_input_bench/`、`sim/camera_*bench.v` | 专用输入PnR基准与控制综合基准；没有JTAG/位流命令 |
| `scripts/sim_camera_input.ps1`、`build_camera_input_bench.ps1`、`audit_camera_input_bench.py` | 可复现测试、原生构建和多corner内部摘要审计 |

接口详见[输入实现README](../rtl/input/README.md)。TAG是03提供的不可变身份/实体引用，模块不独自生成权威epoch/frame_id。Bayer外部代码保持1/2/3/4枚举；FORMAT=2仅是内部RGB565诊断，不能冒充网络RGB888。没有改变76MiB布局、网络头、MCU V2或外部UART编号。

## 实际测试与原始证据

证据根目录：`fpga/build/camera_input_20261012/`；完整交付映射与哈希见`delivery.json`、`source_hashes.json`。

| 测试 | 实际结果 | 证据 |
| --- | --- | --- |
| 接收器异常/身份 | PASS，760检查、21源帧（11合法/10错误）；4个Bayer相位、短长行、缺多行、溢出、令牌/就绪、配置拒绝、边界同拍首字节、超时及恢复 | `sim_20261012_155432_857/dvp_frame_receiver.log` |
| 新RGB565完整性路径 | PASS，字节序/完整帧/奇字节短行/下一帧重对齐 | 同目录`dvp_rgb565_receiver.log` |
| 完整帧预热 | PASS，坏预热帧重新累计，运行期坏帧后直接下帧恢复，就绪掉线再预热 | 同目录`dvp_frame_warmup.log` |
| 不可暂停分流 | PASS，11检查；两路相同数据、RAW/ISP分别满、无RAW槽、共同输入错误和恢复 | 同目录`dvp_raw8_fanout.log` |
| 有限队列/混合服务 | PASS，6检查；8entry模型、4拍停顿完整交付，16拍停顿RAW作废而ISP完整，旧数据排空后新帧恢复；RAW峰值8，ISP峰值1 | 同目录`dvp_raw8_queues.log` |
| PCLK停止/恢复 | PASS；独立ctrl域检测一次事件、恢复与禁用无误报 | 同目录`dvp_clock_watchdog.log` |
| 运行期SCCB | PASS，20检查；初始化所有权、cookie/地址锁存、忙拒绝、掩码保留、ID保护、零mask、NACK/超时/回读不符、quiesce丢失 | 同目录`ov5640_register_service.log` |
| 独立服务期限 | PASS；SCCB事务deadline释放线并恢复ready；无消费者响应的组级deadline拒绝mode_ready | `sim_20261012_160041_647/ov5640_service_deadline.log` |
| RAW8寄存器实体 | PASS，11检查；43写、132读，1080尺寸/RAW色序、debug位保留、固定曝光/无扩行、忙拒绝/未排空/ID错误、最终复核漂移、提交中途输入不改变锁存实体 | 同目录`ov5640_raw8_mode.log` |
| 全尺寸RAW8 | PASS，2,073,600字节逐字节/x-y/tag比较，行内II=1，真实结束边界之前无legal | `sim_20261012_154344_582/dvp_raw8_full.log` |
| 既有诊断/PWM | 8组PASS，含1,238检查与244项黄金写、旧DVP27检查、读回17检查、固定组19检查及实际camera自动/固定路径 | `fpga/build/ov5640_pwm_20261012/sim_20261012_155207_939/result.json` |
| FIFO预算模型 | 5测试PASS | `fifo_budget_tests.log/.json` |
| 曝光模型 | 8测试PASS，新增HTS debug位回归 | `exposure_tests.log/.json` |

使用上一轮构建区便携Icarus 12.0 devel/g2693dd32b，未运行安装器。合成寄存器/队列模型不模拟光学响应、模拟初始化适用性、跨域亚稳态或DDR完成。测试未连接真实相机、灯光或下载器。

## 性能、时序、资源对照

| 口径 | 原诊断/规划基线 | 本候选 | 层级/限制 |
| --- | --- | --- | --- |
| RAW8整帧路径 | 无正式RAW8完整性接收实现 | 全1920×1080逐字节通过，2,073,600 B | 合成源，不能写成实物1080p30 |
| 行内吞吐 | RGB565每两字节拼一个像素；不是RAW吞吐基线 | RAW8 II=1 | PCLK周期级仿真，保持8有效位 |
| 100MHz测试输入吞吐 | 无同功能数值基线 | 2,082,243有效采集周期，约99.585MB/s | 含测试每行8拍间隔；与真实sensor HTS/消隐不同，不算改善百分比 |
| 目标完整30fps | 62.208MB/s计算目标，未实测 | 接收算法在上述合成条件覆盖目标预算 | 实物时钟/模式、双路服务期限和完整帧率仍未知 |
| 输入内部时序 | 旧720p板级报告不能作为同功能基线 | 100MHz PnR：slow setup WNS +2.085ns/TNS0；slow hold +0.168ns，fast hold +0.114ns | 独立片内发生源/接收/分流，外部IO与真实CDC未签核 |
| 其余内部摘要 | 无同功能基线 | slow recovery +6.543ns、removal +0.953ns；fast setup +5.253ns、recovery +7.788ns、removal +0.635ns，全部失败端点0 | `timing_resource_audit.json`；estimated126.3424MHz是工具估计，不承诺此频率运行 |
| 输入基准资源 | 无同功能资源基线 | 780 LUT、913寄存器、0 latch、0 DRM、0 APM | 实际综合，包含发生源/观察器和常量优化，非纯模块/整机资源；FIFO未计入 |
| 控制基准资源 | 新能力，无同功能基线 | 359 LUT、388寄存器、0 latch、0 DRM、0 APM | 实际控制基准综合，未PnR/外部SCCB电气签核 |

原生工具为PDS 2022.2-SP6.4 build146967、PG2L100H/FBG676/-6。输入基准执行Compile→Synthesize→Device Map→PnR→Report Timing，退出0，摘要`All Constraints Met.`；实际报告来自PnR DB，含slow/fast setup/hold/recovery/removal与脉宽摘要。原生报告标题实际命令是`report_timing -max_path 10`，不把Tcl请求参数当作工具已保留的选项。控制基准执行Compile→Synthesize退出0。

- 输入原始报告：`pds/report_timing/camera_input_bench.rtr`、`pds/synthesize/camera_input_bench.snr`、`pds/place_route/camera_input_bench.prr`。
- 控制原始报告：`control_pds/synthesize/camera_control_bench.snr`。
- 原生控制台及状态：`pds/report_timing.console.log/.result.json`、`control_pds/synthesize.console.log/.result.json`。
- 基准100MHz为内部预算，板级DVP setup/hold、线缆、PCLK实际沿及Gray指针约束没有据此豁免。复位例外仅来自真实异步外部reset输入，内部释放仍计时。基准IO是工具自动分配，不对应真实板卡，未生成位流。
- 输入流程637条警告、控制流程警告见原生JSON：包括常量/未用节点裁剪、自动IO/未约束输入等，全部保留。不据此认定真实相机IO或整机时序通过。

预算示例：在**假定**96MHz峰值、20µs最长服务停顿下，2048entry、4entry CDC+2entry流水余量需要1926entry，可用停顿约21.271µs；30µs停顿超容量。8bit×2048资源不能同时按“208bit×2048带tag”使用，后者单按位数至少12块36K RAM，实际原生深度/端口/打包仍待01/集成核验。没有无限服务停顿承诺。

## 已冻结与需要集成的差异

本轮保留共享文件所有权，仅新增专用实现/项目/测试/报告，另修正本相机模型的HTS掩码。集成负责人需要按README落实：

1. 在板级工程加5个输入模块，保留RGB565诊断实例；RAW和RGB不得隐式混合。新模块的sensor配置源来自可读实体，经已核验传感器模拟初始化后提交，不把测试向量当作板级PLL常量。
2. 将03预分配tag/配置实体原子送到PCLK，数据和行帧标记跨域通过01签核原生FIFO；事件通路必须独立保留结束/错误，满数据队列不能丢事件。合并前不改公共IP清单或全局CDC约束。
3. 用输入legal+04真实写completion/drain同时满足03 READY栅栏。abort后的迟到end不得作用于复用后的槽，所有操作仍带原slot/generation/身份。
4. RAW导出/ISP主视频队列独立资源与错误计数。当前`raw8_isp.frame_abort`只标错，尚未证明部分输入停止后会退出到frame_ready；06需提供真正取消/复位/排空，不能在旧帧未终止时admit新帧。
5. 07停止capture，03/04取消并排空，01保证FIFO双端清理，quiesced后执行RAW实体，成功后原子提交接收配置、切epoch、预分配tag，再恢复并预热。SCCB服务本身不承担整机事务排空。

没有修改外部报文、帧池布局或源身份规则，所以本轮没有新增跨端协议编号。硬件结果仍是 `source_identity=null/pairing_status=unverified`。

## 来源、真实性与未通过范围

只读阅读了本地OV5640数据手册§7.7/7.15/7.21、DVP指南有效位/极性和MINI模组原理图，安装版Timing Analyzer §4.1/§4.5、Simulation与ADS语言资料。原件未改，提取文本、来源绝对路径和SHA-256保存在`build/camera_input_20261012/reference/`。寄存器的有效位掩码、PLL预分频/倍率合法范围均按这些资料核对，未从其他平台移植固定时钟值。

未通过/未执行：实物RAW8/1080p30模式与完整源帧率、实际XCLK/PCLK/采样窗口、Bayer/裁剪/镜像及DVP有效位、原生双队列/配置事件CDC、真实DDR/ISP混合负载、运行期整机切换、板级约束PnR、光强150Hz/漂移/占空比矩阵、R_band/R_temporal、同源HDMI配对和功耗/热测量。以上指标保持null/unverified，配置模板中的测量项保持null。

现有over_temp记录及硬件放行条件继续有效；本轮无下载、光学采集或压力测试。硬件获准后先读回实体、测PCLK/HREF/VSYNC、确认光强/内部行关系，再补原始.raw/.rgb与帧元数据；PWM固定档位按新模式行时间重新计算。受约束AEC/banding仍独立待开发，不能用50/60Hz自动检测证明150Hz适配。本轮未提交或推送。
