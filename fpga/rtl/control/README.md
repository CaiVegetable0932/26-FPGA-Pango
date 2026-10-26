# 07 控制服务实现与集成契约

2026-10-13：PC boot/status/mode/geometry及源帧调度已接入；2026-10-21快照服务删除，新AFG1仿射/图像/运动/相机实体接入 `pango_video_system`，正在总体布线。独立 MCU V2/姿态选择仍按用户范围暂缓外部接入，无样本明确降级。此前单元交付结果见
`../../reports/network_control_20261012.md`；不是实板、物理同步或相机外参验收。

- `uart_8n1`：125 MHz / 460800 默认独立双向 UART，2FF 接收同步、中心采样、停止位校验。PC 使用另一个实例和 115200 参数，不并接 MCU 电气口。
- `uart_v2_parser`：2048 B 有界缓存，1024 B 载荷上限，绝对整包期限，坏包丢候选首字节再扫描。默认 MCU `WIRE_VERSION=2/TIMEOUT_US=30000`。既有 PC 外层版本由其能力协商冻结，可独立实例化 `WIRE_VERSION=1/TIMEOUT_US=150000`，不把 MCU 命令分派到 PC 解析器。
- `mcu_readonly_client`：GET_INFO（profile=0x4D32）→OPEN→GET_CONFIG→SET_STREAM(200)→周期 SYNC；只读命令集合硬编码。请求序号不回绕，最多两次完全相同重试。`reopen_required` 后，调用者提供不同的非零 `new_session`，不能重用旧会话的 seq=1。STATE 的 sample_seq 使用模 u32 前向差，boot/session/config/线上 seq 匹配后才分发。
- `config_valid/config_entity` 是 264 B 实体，必须归档、核对模型/安装/参数后用 `config_ready/config_approved` 完成握手。不能固定批准一个配置号而丢弃实体。EVENT 完整记录须先消费再确认；队列满明确丢弃且不越过缺口累计确认。
- SYNC 锁存实际 UART 首字节许可的 t1，解析器保存 CRC 最后字节的实际到达时间 t4；t2/t3 保留 MCU 定义。四周期服务流水不阻塞 STATE。扣除 34/50 B 串行时间，加入整数取整误差和外部 `capture_error_us`；`timing_bound_valid=0` 时不建立映射。实际 UART 首位/MCU 中断/转发误差须测量后提供这个界。
- `pose_frame_selector`：32 个完整状态，满队列替换最旧并计数；按曝光参考时刻选择不晚于它的最近样本，不做跨来源插值。`clear` 至少在 session/config/boot 失效时同步断言。XYZ 为归一化坐标，pitch/yaw 为机械相对角，绝不生成 roll/q_wc 或相机外参。帧结果保持到 ACK。
- 失去有效角的新快照以接收时间建立**降级边界**，避免旧有效角掩盖故障；它不是测量时戳。有效样本使用映射后的 servo_tick_us。同步不确定度加入漂移保守界：默认 200 ppm 用每 4096 us 至多 1 us 的阶梯上界。映射相隔超过 2 s、年龄/误差超限或配置未验证，均明确降级。200 ppm/20 ms/1 ms 为待实测配置界，不能报告为晶振或机构实测性能。
- `parameter_entity_guard`：内部实体格式/逐字段有符号上下界/整体 CRC32 校验；不新分配 PC 命令号或载荷格式，不把实体 CRC 当 UART CRC16。调用者须给出冻结的字段布局、定点位数、模型与工作域区间证明；不删除未支持的高阶项来强行批准。
- `frame_parameter_bank`：完整实体通过校验后进入影子，合法采集边界整体生效，分别报告 received/validated/rejected/applied。帧管理器必须在生效边界采样 `capture_entity/capture_version/capture_entity_id`，不能在同一边沿采样旧 `active_*`；描述符携带版本、实体号和真实源身份。处理/几何读取保留的实体，不读取会变化的全局 active 总线。
- 采集/ISP 与几何应使用各自的提交实例及实体保留规则；板级几何实体与增强实体均以源采集边界提交，并在源槽保留整份系数；几何消费者读取该源槽保留记录。单元调用者须以其明确的合法源边界驱动通用 `capture_boundary` 端口，携带该源帧 epoch/frame_id。端口名称不允许集成方把几何版本在处理帧中途替换。
- `counter_snapshot_cdc`：源域一次冻结整个计数总线，双向 toggle 握手，目的域一次捕获并保持。两域复位共同断言、各域同步释放，集成时核验同步器与 held 总线的真实最大延迟约束；只有异步功能仿真不构成 CDC/PnR 签核。

PC 运行命令 90/92/94/95/A0～A6（93/96/97返回NAK6） 已在 [PC_RGB_CONTROL](../../config/integration/PC_RGB_CONTROL.md) 定义并与 RTL/host 编解码器交叉验证；成功 ACK 表示 validated/queued，实际 applied 源 epoch/frame 通过冻结状态/实体读回。不能宣称旧位流、未适配的旧 PC 界面或实板已支持本扩展。摄像头/SCCB 事务所有权由 02 执行，帧池实体保留由 03 执行，实际动态几何参数生成由 06 执行。
