# FPGA–MCU 通信协议 V1

日期：2026-09-21。范围：FPGA 二进制端点、接口合同及离线验证方法；不包含 MCU 固件、电机控制、引脚分配、烧录或实物通信验收。

## 1. 依据与现有 MCU 的兼容边界

- 复用主设计 `output/PG2L100H_1080p畸变矫正详细设计方案.md` §9.2 的 UART 包络，保持与 RAW 图像网络 CRC32 的职责分离。本文件的命令空间属于独立 MCU 端点，不替换 PC 标定 UART 或 IMU UART。
- 只读查阅本机 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Simulation_User_Guide.pdf`（V1.0，PDF 页6–7、13–15、19–21）、`ADS_Synthesis_User_Guide.pdf`（V2.2，PDF 页50–52）、`ADS_Language_Support_Reference_Manual.pdf`（V1.0，PDF 页10–12、15–16、19、50、55–56）。RTL 使用支持的 Verilog 寄存器、组合逻辑、常数界限循环、函数和复位 FSM；行为仿真与综合、布局布线及 SDF 时序仿真分别记录。
- 目标核对：MINI 硬件手册 V1.3（原始工作区 `reference/盘古100K200K MINI开发板/1_Demo_document/实验例程说明篇/教程1_盘古MINI系列开发板硬件指导手册_V1.3.pdf`，PDF 页6、9–12）及 `fpga/config/board.json`：Logos2 / PG2L100H / FBG676 / -6，系统单端时钟27MHz。CP2102 是 PC 调试串口，不能无仲裁并接设备端 UART。共享工作树没有 `reference/`，仅从原始工作区只读查阅。
- 只读执行 `git show origin/codex/mcu-test-system:mcu/stm32/D36A_README.md`，对应提交 `1b946569c9dcdb98e7c1aedb713e33a095332543`。该分支说明中的 USART3 / PD8 TX / PD9 RX / 115200 / 8N1 是 **PC ASCII 文本电机接口**，以 CR/LF 分行，包含 `wake` 和运动命令。本次二进制协议不与之直接兼容；`wake` 本身还具有停止/清队列语义，不能作为本协议心跳。
- 新 MCU–FPGA 端点需要独立 UART，或由后续 MCU 固件新增明确的二进制适配与仲裁。当前主线 MCU 仅骨架；上述分支的器件/接线事实不等于本接口已冻结。此轮不合并/修改 MCU 分支，不发送任何运动命令，不打开物理串口。

## 2. 帧与字节序

默认115200 bit/s，8N1，无硬件流控，空闲高，LSB先传。所有多字节整数均为小端，包括 CRC。

```text
55 AA | version:u8=1 | cmd:u8 | seq:u16 | length:u16 | payload[length] | CRC16:u16
```

CRC-16/CCITT-FALSE：poly `0x1021`、init `0xFFFF`、refin/refout=false、xorout=0，覆盖 version 到 payload，排除55 AA和CRC本身。校验参考：ASCII `123456789` 的CRC为 `0x29B1`。

协议总 payload 上限1024字节。本端支持的请求最大32字节，响应固定32字节；能力查询分别报告1024和32，不能将本端能力误写成整个协议只有32字节。`seq` 仅用作响应关联，FPGA原样回送；它可回绕，不能替代业务事件身份。事件幂等身份是 `(epoch, session_id, event_seq)`。

## 3. 会话和重启隔离

1. 顶层提供非零 `link_epoch:u64` 与 `link_epoch_valid`，与 `clk` 同域且稳定。每次 FPGA 复位、重新配置、冷启动，或需要清除会话历史时，必须由外部可靠代次来源分配**不复用的 epoch**。未具备可靠来源时保持 valid=0：能力查询可用，所有会话/状态/事件请求返回 NOT_READY，不输出环境事件。
2. RTL 不具有非易失存储，不生成所谓“保证唯一”的固定种子时间戳。仅接常量、复位后从零计数、或重复使用旧 epoch，均不能保证跨重启隔离；顶层集成必须明确落实此条件。与 PRAW 的 stream_epoch 可由同一可靠来源协调，但本模块不自动将二者等同。
3. MCU 先 GET_CAPABILITIES，读取 epoch，再 OPEN_SESSION。`session_id:u32` 非零，并在同一 epoch 内单调增加、不回绕；MCU 重启需持久化该计数，或使用查询到的当前 session_id+1。达到FFFFFFFF后由顶层更换 epoch，不能归零复用。延迟的旧 OPEN_SESSION 不得回退当前会话。
4. 同一 OPEN_SESSION 重发返回 DUPLICATE，不清除已接受事件。更大的 session_id 开启新会话，清空环境有效性与事件历史；旧会话后续事件返回 BAD_SESSION。
5. 同一会话的 event_seq 非零、严格递增，允许跳号，不允许回绕。最后一次事件原样重发返回 DUPLICATE，不重新发出 env_valid、不改变 FPGA 接受时间；相同 event_seq 内容不同返回 ID_CONFLICT；更早 event_seq 返回 STALE_EVENT。更旧的成功事件重试可能收到 STALE_EVENT，但绝不重执行；需以状态查询判定进度。
6. epoch 或 valid 任一变化会清空接收状态、发送队列、当前会话和锁存环境字段，正在发送的帧可被截断。对端必须在切换后等待至少 RX_TIMEOUT_MS 空闲，再重新查询/握手，丢弃旧响应。统计计数保留至 rst_n 复位。

隔离用于防止延迟/重复请求误执行，不提供密码学鉴权或抗恶意伪造能力。

## 4. 命令与请求载荷

| cmd | 名称 | length | payload |
|---|---|---:|---|
|01|GET_CAPABILITIES|0|无，可在 epoch 未就绪时查询|
|02|OPEN_SESSION|12|epoch:u64，session_id:u32|
|03|GET_STATUS|12|epoch:u64，session_id:u32；必须为当前会话|
|04|GET_COUNTERS|12|同上|
|05|GET_BOARD_DIAGNOSTICS（可选）|12|同上；仅能力 bit4=1 时支持，只读板级快照|
|10|SUBMIT_ENVIRONMENT|32|见下表|

除01外，命令要求非零有效 epoch 和当前会话（02用于建立/提升会话）。所有其他 cmd，包括响应码误发到请求端，返回 UNSUPPORTED。没有运动、光照执行、流开关或视频参数写入命令。

环境事件固定32字节，载荷中的照度/角度只能代表 MCU 实际测量值，不能把设定值标成测量有效。

| 偏移 | 字段 | 类型/单位 |
|---:|---|---|
|0|epoch|u64|
|8|session_id|u32|
|12|event_seq|u32，1..FFFFFFFF|
|16|mcu_time_us|u32，MCU 自己的微秒时戳，约71.58分钟回绕|
|20|lux_milli|u32，毫勒克斯；valid=0时数值不得用于测评|
|24|angle_mdeg|i32，二补码毫度；坐标轴/零位由后续测评约定冻结|
|28|measurement_valid|u8，bit0实际照度有效，bit1实际角度有效；bit7:2=0|
|29|reserved|3字节，必须全0|

MCU时戳保持原值，并随 session 标识解释；不能用于冒充板端采集时间、曝光时间或 frame_id。`env_board_time_us` 是 FPGA 在协议接受时从 `board_time_us` 采样的时刻，已经包含 UART 传输及解析延迟，同样不能直接宣称与曝光同步。两个 valid 均可为0，用于提交“当前无有效实测”的状态。

## 5. ACK、NACK 和状态快照

响应使用相同包络、version=1、seq原样回送、length=32。cmd=80表示OK或DUPLICATE；cmd=81表示错误。所有响应 payload 前20字节一致：

| 偏移 | 类型 | 内容 |
|---:|---|---|
|0|u8|result，下表|
|1|u8|原请求cmd|
|2|u8|bit0 session_active，bit1 epoch_ready，其余0|
|3|u8|当前测量valid的bit0/bit1，其余0|
|4|u64|当前有效epoch；未就绪为0|
|12|u32|当前session_id；无会话为0|
|16|u32|最后接受的event_seq；无事件为0|

响应剩余12字节：

| 响应 | 偏移20 | 偏移24 | 偏移28 |
|---|---|---|---|
|成功能力查询|u16协议上限1024 + u16本端上限32|u32能力位图（基础0000000F，含板级诊断0000001F）|u32配置BAUD|
|成功计数查询|u32 rx_good_count|u32 rx_error_count|u32 tx_overflow_count|
|成功板级诊断|板级快照 word0|板级快照 word1|板级快照 word2|
|其余响应|u32 status_flags|u32 rx_good_count|u32 rx_error_count|

能力位图：bit0环境事件，bit1会话/事件幂等，bit2独立板端接受时间，bit3计数查询。`status_flags` 是主顶层只读透传，业务位定义由顶层接口冻结。响应保存的是入队时的完整快照，包括本次成功操作和本次统计；不会随之后的新事件改变。ACK只表示 FPGA 已接受/锁存，不表示机构运动、曝光、视频帧关联或 MCU 固件验证完成。

| result | 名称 | 含义 |
|---:|---|---|
|00|OK|成功|
|01|DUPLICATE|最后事件或当前会话的幂等重试，无新副作用|
|02|BAD_CRC|CRC不匹配|
|03|BAD_LENGTH|超过协议/本端能力或命令精确长度不符|
|04|TIMEOUT|帧中断且超过字节间超时|
|05|BAD_VERSION|CRC正确但version不是1|
|06|UNSUPPORTED|未知命令|
|07|BAD_EPOCH|请求epoch不匹配|
|08|BAD_SESSION|零/旧/不匹配的session|
|09|STALE_EVENT|event_seq为0或早于最后事件|
|0A|ID_CONFLICT|最后event_seq相同但payload不同|
|0B|BAD_FORMAT|环境flags保留位或reserved非0|
|0C|UART_ERROR|UART停止位错误|
|0D|NOT_READY|外部epoch未就绪|

有完整帧时拒错优先级：CRC、version、本端长度、命令/会话/内容。超过1024在长度字段完成后立即BAD_LENGTH并隔离。超时/停止位错误仅在cmd和seq已经完整收到时生成NACK；更早的噪声只计数，不伪造可关联seq。普通非55噪声字节直接忽略。

## 5.1 可选板级诊断

2026-09-22 可选扩展：能力 bit4 表示支持命令05；未使能 `BOARD_DIAGNOSTICS` 的通用端点返回 UNSUPPORTED，并保持原能力位图。命令05要求有效 epoch、当前非零 session、精确12字节请求，沿用公共响应前20字节，不改变任何板级寄存器或事件状态。

MINI 通信候选快照 v1：word0 为 PHY ID；word1 bit15:0 为最近 MDIO 读值、bit19:16保留0、bit20为最近读 TA 无应答标志、bit25:21为探测/选定地址、bit31:26为当前/失败初始化步骤；word2 bit15:0为 PHY 状态寄存器、bit23:16保留0、bit31:24为版本1。正常轮询时“最近读值”与“当前步骤”不一定同一事务；锁存失败时两者对应失败读操作。其它顶层必须另行定义版本及布局，不把全零通用输入当作有效诊断。参见 `FPGA通信上板联调方案.md`。

## 6. 超时、恢复和队列约束

- `RX_TIMEOUT_MS=20` 为已接收字节之间的超时，不是整帧总时长。默认115200时，1024字节载荷帧约89.8ms仍可完整排空。
- 33..1024字节的帧流式计算CRC并丢弃额外载荷，到CRC末尾返回BAD_LENGTH（若CRC/version错误则优先返回对应错误），随后立即允许下一帧。载荷中的55 AA不会被解析为嵌套帧。
- >1024的声明长度及UART停止位错误进入隔离；等待至少RX_TIMEOUT_MS无有效字节/帧错误后重新找帧头。发送端不得在这类错误后不留间隔就发送有效请求。
- 帧内超时后回到寻帧状态。55 55 AA重叠帧头能同步；错误CRC之后下一帧可立即接续。低于半位的起始毛刺会被UART RX过滤，持续低电平break不重复产生字节。
- 响应FIFO固定8项，外加正在发送/串行器中转的帧。短请求连续输入可能超过回复带宽。FIFO满时丢弃整个请求并增加tx_overflow_count/rx_error_count，**不更新会话/环境状态**；因没有响应空间，不能保证每个过载请求收到NACK。
- 正常对端采用“一次一个未确认请求”，超时后用同一事件身份及相同内容重发。默认可选择100ms应用层响应等待；长度拒绝或断帧后先等待上述空闲恢复期。有限背靠背突发可用，不能把FIFO容量解释为持续无限吞吐。
- rx_good_count统计通过CRC/version/本端长度检查的请求（语义错误也可计入）；rx_error_count统计解析、命令、会话或过载错误；tx_overflow_count统计需响应但队列满的请求。均u32模回绕，rst_n清零，epoch变化保留。

## 7. 可集成 RTL 端口合同

文件：`fpga/rtl/control/mcu_protocol.v`；同目录依赖 `mcu_uart_rx.v`、`mcu_uart_tx.v`、`mcu_frame_rx.v`、`mcu_frame_tx.v`。无PDS IP或第三方RTL依赖。

参数：`CLK_HZ=27000000`，`BAUD=115200`，`RX_TIMEOUT_MS=20`。要求CLK_HZ/BAUD至少8；整数分频四舍五入，默认27MHz得到234周期/位（约115384.6baud，+0.16%）。超时需大于一个完整UART字节并落在32位计数范围内。改变频率时顶层必须同步改CLK_HZ。

本轮主顶层集成使用 `CLK_HZ=125000000`：115200配置得到1085周期/位（约115207.4baud，+0.0064%）。超时常量采用 `(CLK_HZ / 1000) * RX_TIMEOUT_MS`，默认20ms为2,500,000周期，避免先计算125,000,000×20的有符号32位溢出。允许参数的超时周期数应为1..2,147,483,647，且满足上述字节时长约束；非整千赫兹时先除1000会有小于RX_TIMEOUT_MS个clk周期的截断误差。125MHz真实引脚仿真结果见验证报告。

| 方向 | 名称 | 位宽与语义 |
|---|---|---|
|in|clk、rst_n|时钟；低有效异步复位，释放由顶层同步|
|in/out|uart_rx / uart_tx|各1位；RX模块内两级同步，TX空闲高|
|in|link_epoch、link_epoch_valid|64位与1位；见会话隔离条件|
|in|board_time_us|64位，FPGA时间源|
|in|status_flags|32位，主系统只读状态|
|out|session_active|1位，当前会话已建立|
|out|env_valid|1位，新事件成功接受时仅一个clk周期；无ready回压|
|out|env_session_id、env_event_seq|各32位，锁存事件身份|
|out|env_mcu_time_us|32位，MCU原始微秒计数|
|out|env_board_time_us|64位，FPGA接受时刻|
|out|env_lux_milli|32位无符号|
|out|env_angle_mdeg|signed 32位|
|out|env_measurement_valid|2位，bit0照度、bit1角度|
|out|rx_good_count、rx_error_count、tx_overflow_count|各32位|

除UART RX外，全部输入必须在clk域同步，包含多位总线；接入其他域需由顶层使用一致快照/握手CDC，不能只逐位双触发器。env字段在env_valid同周期原子更新，保持至下一事件；复位、epoch/valid变化或新会话时全部清零。跨域消费者应捕获全部字段，并同时携带相应epoch，不能把清零当作新事件。没有stream_enable端口，本次不控制视频流。

## 8. 验证与未完成事项

RAW8 链路只读遥测（capability bit6，`CHAIN_DIAGNOSTICS=0`默认关闭）：命令07/08/09均请求12字节epoch+session，沿用长度、CRC、epoch/session检查，响应末12字节按以下顺序小端编码：

- 07 DVP_GEOMETRY：u16 VS下降沿计数、u16 VS低电平阶段行数、u16该阶段最短HREF宽、u16最长HREF宽、u16 VS高电平阶段行数、u8采集状态、u8版本（1）。统计上个VS下降沿间隔，以HREF上升时VS电平归属行，计数/行宽饱和65535，帧边沿计数模65536回绕。状态bit7配置同步就绪、6已arm、5正在采集、4坏帧、3关闭中、2结果待发、1字待发、0溢出。
- 08 DVP_PROGRESS：u32 PCLK累计周期、u32拒绝帧计数、u32溢出帧计数，模2^32回绕。来自与07同一192位摄像头域握手快照；但是不同命令读取时刻不同，**不保证跨响应原子一致**。约8.39ms请求一次，不运行的PCLK无法应答、输出保持旧值。仅观察到累计值不能推导即时频率，频率估计须使用间隔及回绕处理。
- 09 PIPELINE：u16已消费START数、u16已消费END数、u32已消费WORD数、u16原生W握手数、u8核心状态、u8写引擎状态。核心状态bit7:6采集FSM、5:3 HDMI取帧FSM、2记录valid、1记录ready、0commit。写引擎bit7 active、6:4 FSM（0接记录、1等AW、2等W、3申请栅栏、4等栅栏返回）、3 awvalid、2 fence_req、1 record_ready、0 wready。所有计数按宽度回绕，来自mem_clk；此页不等于已发布帧数。

几何/进度由独立观察模块生成，不改视频、不改变坏帧门禁、不丢弃故障。版本0或计数不变必须结合复位与其它状态判读；不将诊断页当作HDMI帧源身份。

RAW8 可选只读命令 `0x06 GET_VIDEO_SNAPSHOT`：仅 CAPS capability bit5 为1时调用；参数 `VIDEO_DIAGNOSTICS=0` 默认关闭，不影响旧顶层。请求为12字节 epoch+session，沿用0x05的长度、epoch与session检查。响应仍为32字节payload，末12字节（偏移20..31）为首次WORD错误快照：u24实际32字节偏移、u24期望偏移、u24已接受字数、u8行内字序号、u8标志、u8版本，均小端。标志bit0有效、bit1当时active、bit2偏移不符、bit3数量超限；版本1有效快照，复位后的全零版本0表示尚无快照，不代表视频已正常。快照锁存于mem_clk，保持到板端复位；查询不清错、不重新启动采集。PHY命令0x05及视频报文不变。

RAW8 双路顶层诊断扩展（2026-09-23）：GET_STATUS 的 status_flags 保留 bit0～10 和 PHY code bit16～19 原语义。bit14/15 分别为 GMII 桥读/写故障；bit24～28 分别为 RAW 写入、DDR读仲裁、帧池、网络输出、读队列溢出故障；bit29～31 为写引擎首次故障码（1重复START、2WORD偏移/数量、3END身份、4未知记录、5WID/WLAST、6读回栅栏不一致）。bit7 仍为视频核心/桥聚合故障，不屏蔽错误。旧 RAW8 镜像扩展位为0，未知原因不等于无故障。该扩展不改变报文长度、命令、PRAW格式或HDMI帧配对。

自检入口：`fpga/scripts/sim_mcu_protocol.ps1`；串行刺激/解码testbench：`fpga/sim/tb_mcu_protocol.sv`。所有工具产物归 `fpga/build/mcu_protocol...`。实际运行、检查数、版本与限制见 `fpga/reports/mcu_protocol_sim_20260921.md`，只有执行成功的条目才可报告通过。

未验收：MCU固件适配、真实串口通信、电平/引脚/接线、板端epoch来源、时钟CDC整体集成、实测照度/角度精度、曝光时序关联、布局布线时序和上板。禁止由RTL自检或独立综合推导这些项目已通过。
