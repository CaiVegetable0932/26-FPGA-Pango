# 02 摄像头输入实现与集成契约

2026-10-13 集成核对：`ov5640_raw8_mode.RAW_OUTPUT_SELECT` 明确选择 `501f[2:0]`，默认 4 保留本分区 SNR RAW 测试，3 对应历史 MINI 输出裁剪路径。历史 `codex/fpga-geometry-correction` 的 RAW8 profile 记录 SNR RAW 曾出现 1952 字节/1086 行，因此新整机不能无条件沿用默认 4。已在 `fpga/config/integration/historical_board_candidate.json` 保留历史 74 项寄存器与引脚依据；两种 tap 的 SCCB 模型回归通过。模式 3 还须配合历史模拟初始化和明确关闭传感器处理的寄存器组，不能把 tap 参数单独写入当作已完成相机配置。该配置档不声明当前实板、固定曝光/PWM 或 Bayer 已验收。

对应[分区方案](../../../output/FPGA分区优化交接/02_摄像头输入优化方案.md)。这是独立输入分区实现，未接入共享板级Top、正式原生FIFO、DDR/DMA或ISP。上一轮720p RGB565初始化/固定PWM模式仍可回归。[验证报告](../../reports/camera_input_20261012.md)列出局部通过范围及实物缺口。

## 模块与时钟域

| 模块 | 时钟与职责 |
| --- | --- |
| `dvp_frame_receiver.v` | PCLK源同步采样、完整性、打包、预热、标签/配置实体锁定。`FORMAT=1` RAW8；`FORMAT=2` RGB565诊断。参数固定，不能运行期隐式切换格式 |
| `dvp_raw8_fanout.v` | PCLK不可暂停并行分流到RAW与ISP的**独立写侧队列**，一支满不会自动作废另一支 |
| `dvp_clock_watchdog.v` | 独立控制时钟检测PCLK停钟，给集成侧时钟失效事件；不依赖已停的PCLK发超时 |
| `ov5640_register_service.v` | 控制时钟独占SCCB；初始化先行，后续读/掩码写/回读，有界忙拒绝和错误返回 |
| `ov5640_raw8_mode.v` | 控制时钟提交明确的1080p RAW8寄存器实体，ID/PLL旁路检查→43项掩码写及逐项校验→整组再读，成功后返回版本/实体 |

RAW8和RGB565接收器是独立配置实例。RGB565内部FORMAT=2不能写成网络`pixel_format=2`，后者按权威协议是RGB888。Bayer输入使用权威代码1=RGGB、2=GRBG、3=GBRG、4=BGGR，输出`pixel_phase`是供内部ISP使用的颜色奇偶相位；实际裁剪/镜像/有效位须实物核验。

PCLK数据/HREF/VSYNC同拍寄存，下一拍计数和打包；无逐位2FF拼图，也不背压相机。VSYNC高为消隐、HREF高为有效，PCLK采样沿需要01结合`4740[5]`及板级延迟签核。支持VSYNC下降/HREF上升同拍首字节；HREF越过VSYNC消隐、缺/多行、短/长行、计数超时、输入共享FIFO溢出及就绪掉线均报告错误。

## 输入→03/04/06冻结语义

所有以下输入已在PCLK域完成握手。`cfg_width/height/bayer/version/entity`、`next_frame_tag`不得从其他域直接逐位同步；跨域必须由01/07配置握手或原生FIFO传送稳定实体。

- `cfg_valid`为单拍，只有 `cfg_ready=!capture_enable && pipeline_drained && !open_frame` 接受，成功/拒绝分别由`cfg_accepted/rejected`返回。尺寸范围受MAX参数检查，RAW Bayer必须1～4。配置后重新预热；预热只累计连续完整合法帧，异常预热帧重新计数，稳定运行中普通坏帧不额外重进10帧预热。
- `token_valid/next_frame_tag`是03提前准备的同源身份/槽记录引用，在VSYNC下降帧起点锁存。TAG_BITS默认160，可扩展；位布局由集成方冻结，它不是新增UART/网络编码。不由本模块独立自增权威epoch/frame_id。配置版本/参数实体同样在帧起点锁定。
- `frame_start`为观察到新源帧的脉冲；`frame_admitted`为该帧允许输出暂存像素的状态。无令牌/未就绪/未预热完成的帧不能输出为正式有效帧。
- `pixel_valid`是不可暂停的1拍像素事件，RAW8一拍一个字节（pixel_data低8位），RGB565两拍一像素；x/y、SOF/EOL/last、phase/tag对齐。所有这些像素仍是**未seal的数据**，last是预期位置标记，不能证明后续没有额外行/字节。
- `frame_abort`发现首次错误时脉冲一次，立即停止本帧像素输出，后续输入继续排空到VSYNC；缺边界或粘HREF通过参数化期限结束。`frame_end/frame_legal/frame_errors`在真实VSYNC上升或异常强制结束时产生。**frame_legal仅代表输入判定，不代表DDR完成或READY。**
- 03分配实体后，把`frame_end`及对应slot/generation、legal、capture_last、errors映射到现有`frame_cmd_t.seal`。abort映射到相应阶段作废/取消语义；不能只用DMA完成替代legal。04每个写issue token/ticket必须等真实completion/drain再退休；03在输入legal且所有写栅栏满足后才能发布READY，取消的槽在在途排空前不得复用。abort后的迟到frame_end仍带旧token；已经cancel的帧结束只结算诊断，不向复用后的槽重复seal。
- 原始`capture_first/last`是PCLK观测时间（含采样流水延迟），不是曝光中心时间。source/valid/error计数是本地32位诊断量，不替代u64权威身份或已测帧率。

## 分流与FIFO

`raw_admit/isp_admit`表示对应阶段在本帧起点拥有可用资源；ready是各**PCLK写侧**FIFO可接受当前像素的容量状态。必须转换为`valid && ready`才写队列。源不能等待ready；满队列后该支路立刻发abort并停止余下像素，独立计丢帧，下一帧只有旧事务/数据排空且重新admit才恢复。共享输入错误同时作废两支，RAW导出过载仅作废S0，不静默压低源帧率。

`raw_end/isp_end`无论是否丢数据都返回；对应legal同时受共同输入合法性和本支路完整接受影响。`raw_data/isp_data`同源并行，直接供RAW写DMA与ISP，不新增DDR读RAW再处理的路径。

本分区不私改共享IP配置，也未虚构一套已签核的异步FIFO。现有`raw_async_fifo`是8bit×2048，不能直接容纳完整像素tag/标记。集成需选择目标器件原生IP：

1. 数据与行帧标记/tag在同一有序通路中传送，或提供严格的每帧上下文引用机制；元数据事件通路也必须有容量保证。错误/结束事件不能因像素FIFO已满而丢失。
2. 共享FIFO满须接 `input_overflow`；分支FIFO满接各ready。不可通过单比特2FF传递像素、脉冲或多位参数组。
3. 01核验Gray指针/复位/双端启动与真实写满/读空延迟；03/04确认错误帧排空、代次和最终写确认。没有这些条件不能把局部接收器挂到诊断旧帧池就声称无撕裂。
4. 当前`raw8_isp.frame_abort`会进入 FINISH 停止接收并排空；整机仍须等待 ISP、数据 FIFO 和 DDR 事务全部排空后才允许下一帧，不能只观察输入分支 abort。
5. `camera_input_budget.py`按峰值PCLK与最长合法服务停顿计算entry需求。合成96MHz、20µs停顿、4entry CDC+2entry流水余量，需要1926entry；2048entry最多覆盖21.271µs。若每像素203bit内容向208bit对齐，2048entry仅按bits就需12块36K RAM，不能仍按原2048byte算容量。它们是计算预算，实际原生映射/停顿需要独立验证。

PCLK停钟时接收器本身不可能发脉冲，`dvp_clock_watchdog.clock_lost/loss_event`必须在控制/帧池域触发作废；不能等PCLK恢复才保护槽。控制域失锁/重置需与01/03/04共同切epoch并排空旧事务。

## RAW8配置与运行期SCCB

服务复用上一轮开漏SCCB读取。`init_finished`在同次复位内必须单调从0到1，初始化NACK/超时锁住服务直到复位。`cmd_valid`为单拍，cmd_ready接受，忙时cmd_rejected；cookie/地址/值/mask锁存。查询可在运行期执行，写只允许quiesced，即采集已关闭且在途DMA/FIFO/帧池已排空。拒绝写只读ID和不可回读的3212 group寄存器，不冒充验证了group launch下一帧生效。

状态：0成功、1 NACK、2超时/总线占用、3回读不符、5无效参数/mask、6未排空/排空丢失、7保护寄存器。写先读旧值、掩码合并、写、再读核对；响应成功只证明该事务。控制组期间排空信号失效或期限到达，mode_ready保持低，需要停止重用旧组并等服务空闲后完整重试。单寄存器期限/组级期限都有界；超时会释放主机开漏驱动；外设持续拉低仍需板级复位/恢复策略，本轮未验证主动总线恢复。

RAW8实体通过`ov5640_raw8_1080p.template.json`记录测量依据，零曝光/非法PLL有效位、超出裁剪/寄存器字段、采样/色序不符不应放行。配置器仅接受明确1920×1080、1:1增量、固定曝光/增益，清额外曝光行和夜间模式，禁止JPEG/binning；`4300`按色序、`501f[2:0]=4`选择SNR RAW。PLL、HTS/VTS、裁剪/偏移和曝光从请求实体提供，不自行复用720p常量。timing/debug高位用手册掩码保留，PLL3034低位是MIPI/时钟计算配置，**不能拿它独立证明DVP RAW8有效位**。

外围模拟从ID和实体寄存器证明43项写和132次读取（含每写两次读及最终复核），不模拟传感器光学/模拟链。真正应用前仍需已核验的共用传感器模拟初始化（可以保留244项路径的来源，另验RAW适用性）、实际D[9:2]/模组引脚、PLL/VCO/输出时钟及裁剪/Bayer相位。`mode_ready`是组写/回读成功状态，不能作为真实1080p30、S0来源或PWM已消条纹证明。

运行期几何/格式切换顺序：07关闭capture并保持→02返回坏/过渡帧→03/04完成取消/在途排空、01保证FIFO双端清理→quiesced→寄存器组成功及原子配置实体跨域→PCLK cfg_accepted→03新epoch/预分配tag→恢复capture并完成预热。本实现提供上述接口，本轮未接跨域配置桥、正式数据/事件FIFO或共享Top。

## 可复现验证

```powershell
./fpga/scripts/sim_camera_input.ps1
./fpga/scripts/sim_ov5640_pwm.ps1 -Simulator Icarus
python -m unittest discover -s fpga/sim -p test_camera_input_budget.py -v
python -m unittest discover -s fpga/sim -p test_ov5640_pwm_exposure.py -v
./fpga/scripts/build_camera_input_bench.ps1 -Benchmark input -Stage report_timing
./fpga/scripts/build_camera_input_bench.ps1 -Benchmark control -Stage synthesize
python fpga/scripts/audit_camera_input_bench.py --output fpga/build/camera_input_20261012/timing_resource_audit.json
```

Icarus默认沿用上一轮FPGA构建区便携工具，也可 `-IcarusHome` 指定bin目录。`-Cases`只重跑指定用例；`-SkipFullFrame`用于快速异常回归。两个PDS基准没有位流/JTAG命令，input基准100MHz只覆盖片内生成源到接收/分流的内部路径，control仅综合，不是板级部署工程。
