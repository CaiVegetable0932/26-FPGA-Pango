# MCU 协议 RTL 与 ModelSim 自检报告（2026-09-21）

结论：两组真实 UART RX/TX 引脚级行为仿真通过；PG2L100H 目标、125MHz参数的独立 ADS 编译/综合通过。没有执行 MCU 固件通信、物理串口访问、引脚分配、顶层布局布线、烧录或硬件验证。

## 1. 工作范围与接口

- 工作树：`C:/Users/ROG/.codex/worktrees/fpga-camera-main-publish/26-FPGA-Pango`；分支：`codex/fpga-mcu-praw-protocol`。
- 五个RTL：`fpga/rtl/control/mcu_protocol.v`、`mcu_frame_rx.v`、`mcu_frame_tx.v`、`mcu_uart_rx.v`、`mcu_uart_tx.v`。
- 仿真：`fpga/sim/tb_mcu_protocol.sv`；入口：`fpga/scripts/sim_mcu_protocol.ps1`。
- 协议/集成合同：[FPGA_MCU通信协议V1](../../output/FPGA_MCU通信协议V1.md)。顶层模块为mcu_protocol，125MHz集成时覆写CLK_HZ；外部epoch/valid、board_time_us、status_flags与输出环境字段均为clock125同域。没有stream_enable或运动命令。
- env_valid仅新环境事件接受时单周期有效，其余环境字段锁存；MCU时间与FPGA接受时间独立。会话/事件有序去重，CRC/版本/精确长度/超时/非法内容拒绝；FIFO满时不执行请求副作用。
- 所有新模块、功能块、测试辅助函数和脚本块均有用途/设计意图注释。没有修改MCU代码、主设计或其他agent负责的实现文件；共享工作树中的其他并行修改不属于本报告。
- 本单项验证阶段没有提交、推送、合并或烧录；后续统一提交/备份和顶层集成结果见[总报告](comms_offline_20260921.md)。

## 2. 参考资料与 MCU 兼容边界

已先读共享工作树AGENTS.md、fpga/README.md、主设计§9.2 UART帧格式，再只读查阅当前安装版本官方资料：

| 资料 | 本轮使用内容 |
|---|---|
|`E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Simulation_User_Guide.pdf` V1.0|PDF页6–7、13–15、19–21：ModelSim编译/运行及各仿真阶段边界|
|同目录`ADS_Synthesis_User_Guide.pdf` V2.2|PDF页50–52：shell流程、参数覆盖、disable_io_insertion、frequency|
|同目录`ADS_Language_Support_Reference_Manual.pdf` V1.0|PDF页10–12、15–16、19、50、55–56：可综合Verilog、函数/循环、复位FSM|
|原始工作区MINI硬件手册V1.3及fpga/config/board.json|核对Logos2/PG2L100H/FBG676/-6、27MHz系统参考时钟、CP2102用途；未冻结MCU引脚|

没有向官方doc或reference写入、提取文件、日志或产物。PDF仅在内存中读取；资料原始路径及细节在协议文档中记录。

只读核对了 `origin/codex/mcu-test-system` 提交 `1b946569c9dcdb98e7c1aedb713e33a095332543` 的 `mcu/stm32/D36A_README.md`。其USART3 / PD8 / PD9 / 115200 / 8N1属于PC ASCII文本电机接口。本二进制协议需要独立UART或后续固件新增适配，**现有固件不能直接兼容**。没有发送wake或运动命令，没有合并/修改该MCU分支；其固件或实物测试结果未纳入本次“通过”。

## 3. 可复现运行与证据

在共享工作树根目录实际执行：

```powershell
./fpga/scripts/sim_mcu_protocol.ps1 -Synthesize
```

起止时间：2026-09-21 22:45:30–22:45:54（+08:00）。ModelSim SE-64 10.1c（2012.07）；PDS 2022.2-SP6.4 build146967。所有生成物位于同一新目录：

`fpga/build/mcu_protocol_20260921_224530_159/`

| 证据文件 | 内容 |
|---|---|
|[result.json](../build/mcu_protocol_20260921_224530_159/result.json)|退出码、参数/结果、7个输入SHA256、时间戳；hardware_tested/mcu_firmware_tested/programmed均false|
|[compile.log](../build/mcu_protocol_20260921_224530_159/compile.log)|5个RTL模块与testbench编译成功|
|[full.log](../build/mcu_protocol_20260921_224530_159/full.log)|完整协议/异常/负载测试PASS|
|[clock125.log](../build/mcu_protocol_20260921_224530_159/clock125.log)|125MHz、默认20ms测试PASS|
|[synthesis.log](../build/mcu_protocol_20260921_224530_159/ads125/synthesis.log)|ADS compile/synthesize命令、告警及完成标记|
|[mcu_protocol.snr](../build/mcu_protocol_20260921_224530_159/ads125/synthesize/mcu_protocol.snr)|独立综合资源与时序估算|
|[mcu_protocol_syn.vm](../build/mcu_protocol_20260921_224530_159/ads125/synthesize/mcu_protocol_syn.vm)|本次生成的综合网表|

运行后重新计算五个RTL、testbench和入口脚本SHA256，7项全部与result.json一致。模型只从UART引脚驱动/采样，不force内部状态，不绕过字节接收器，响应CRC由独立参考函数计算。每个TX字节检查起始位/停止位，每帧检查包头/版本/长度/CRC，再按seq和原cmd核验结果。

## 4. 实际仿真结果

| 组 | CLK_HZ | BAUD | RX_TIMEOUT_MS | 断言检查次数 | 完整响应 | 接受的新事件 | 仿真时长 | 退出码 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
|full|1,843,200|115,200|2|5,378|56|3|404.075ms|0|
|clock125|125,000,000|115,200|20|2,041|21|3|146.219ms|0|

断言次数包括UART每字节及帧校验，并不等于互不相同的测试场景数。full采用16clk/bit降低运行成本；clock125采用真实125MHz时钟与理想115200对端位时间，RTL分频1085clk/bit。两者均真实驱动串口引脚。

| 场景 | full | clock125 |
|---|---|---|
|独立CRC参考123456789=29B1，能力查询及1024/32能力区分|通过|通过|
|epoch未就绪拒绝OPEN，握手建立会话|通过|通过|
|正确事件、负角度、照度/角度valid、MCU时间与FPGA时间分离|通过|通过|
|同seq/不同seq重复同事件只ACK，无第二次env_valid且FPGA时间保持|通过|通过|
|坏CRC、版本错误、unsupported拒绝|通过|通过|
|断帧超时，70%期限不提前触发，110%后拒绝并恢复|通过（2ms）|通过（20ms）|
|无间隔event/duplicate/status三帧，TX响应逐帧核验|通过|通过|
|同事件ID不同内容冲突、旧事件、保留位/保留字节、精确长度拒绝|通过|未在此组重复|
|错误epoch/session拒绝、OPEN重试保留事件去重历史|通过|重启阶段覆盖旧epoch/session|
|噪声、55 55 AA重叠同步、短起始毛刺|通过|未在此组重复|
|对端位时间+1.5%和-1.5%的独立引脚刺激|通过|未在此组重复|
|33字节超本端能力后立即下一帧，1024字节完整排空|通过|未在此组重复|
|1025及65535声明长度拒绝；隔离中的合法嵌套事件不得执行|通过|未在此组重复|
|坏停止位/break、一次错误回应与空闲恢复|通过|未在此组重复|
|28个短查询使响应FIFO溢出，回复+丢弃总量守恒，顺序/CRC完整|通过|未在此组重复|
|GET_COUNTERS读回good/error/overflow准确|通过|未在此组重复|
|接收半帧时复位，更换epoch后旧OPEN和旧事件不能执行|通过|通过|
|新epoch事件、MCU会话升级、延迟旧OPEN不能回退会话|通过|通过|
|epoch_valid撤销后会话无效，后续OPEN返回NOT_READY|通过|通过|

125MHz默认超时计算为 `(125000000 / 1000) * 20 = 2500000`。先除1000避免32位有符号整数先乘溢出；真实引脚仿真又验证了超时边界行为。此次没有实际运行默认27MHz配置的单独回归。

## 5. ADS 独立综合结果与告警

实际流程是官方shell模式，选Logos2 / PG2L100H / FBG676 / -6，顶层参数CLK_HZ=125000000、BAUD=115200、RX_TIMEOUT_MS=20，然后 `synthesize -ads -disable_io_insertion -frequency 125`。没有生成引脚约束，没有运行PNR、gen_bit_stream或下载器。

| 项目 | 实际报告值 |
|---|---:|
|总LUT|1,644 / 66,600（2.47%）|
|其中逻辑LUT / 分布式RAM LUT|1,515 / 129|
|寄存器|1,355 / 133,200（1.02%）|
|锁存器|0|
|DRM / APM / 实体I/O插入|0 / 0 / 0|
|综合估算时钟频率|150.8751MHz|
|125MHz约束下综合估算周期/裕量|6.6280ns / +1.372ns|

以上是综合映射与估算，不能代替布局布线后的setup/hold、CDC、IO时序或板上运行结论。

日志包含594条W行，并非零告警综合：包括20条I/O约束缺失、163条输入未约束、325条输出未约束，以及常数寄存器裁剪、工具属性/命名、max-fanout相关警告。另有17条 `Loop was found during constant probe` 出现在compile的sdm2adm阶段；保留原始日志，未将这些工具信息解释成“已经完成完整时序签核”。报告显示0锁存器，行为仿真和独立综合均成功；本次未进行综合网表功能仿真或针对上述probe警告的形式验证。

ModelSim两组各有 `onerror/onbreak command for use within macro` 提示；本次没有Error/Fatal，进程退出0，且脚本同时要求MCU_PROTOCOL_PASS并拒绝MCU_PROTOCOL_FAIL，因此上述提示没有被用来替代通过判据。

## 6. 集成与未验收边界

- 主agent已从实际mcu_protocol.v读取端口并确认采用125MHz同域侧带接口；本报告不把其他agent的顶层集成测试计作本模块已经执行的结果。用户后续报告通信顶层也完成综合，因此不再重复独立综合。
- 顶层每次复位/配置后必须提供非零、未复用的外部epoch，未就绪保持valid=0。RTL没有非易失唯一代次生成器；重复固定epoch不能保证跨复位重放隔离。MCU需发现epoch、建立单调递增会话，再提交事件。
- 队列过载请求会被丢弃且没有响应空间；正常对端应一次只等待一个未确认请求，按相同事件身份重试。此次过载场景实际测试的是查询突发，副作用请求的“无预留响应槽则不执行”由RTL接受门控实现，未宣称穷举所有过载相位。
- 未验证真实MCU二进制固件、现有USART3文本固件直接兼容、实测照度/角度准确性、UART电平/引脚/接线、实物时钟误差、图像帧绑定、曝光同步、系统CDC、PNR后时序、硬件通信或长期运行。
- 现有MCU电机文本端点不改动；本次模块没有实现电机命令，没有通过软件到达顺序推断图像身份，也未将MCU时间冒充板端时间。
