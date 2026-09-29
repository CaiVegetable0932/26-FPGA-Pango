# FPGA–MCU 通信协议说明（V1，含偏转角度预留）

本文件面向 FPGA、MCU 和整机联调人员，说明当前约定的**独立 MCU–FPGA 二进制 UART 链路**。字节级权威定义及异常处理以 [FPGA–MCU 通信协议 V1](FPGA_MCU通信协议V1.md) 为准；本文件不另创不兼容的报文版本。几何矫正侧的留口见 [几何矫正单元说明](../fpga/rtl/geometry/README.md)。

## 1. 职责、连接与当前状态

MCU 负责云台、电机、补光等设备动作，并把**实际测得**的照度、偏转角度及自身时间戳发给 FPGA。FPGA 负责校验和记录测量事件；将来在完成坐标标定与帧同步后，角度才可参与矫正参数生成。主视频不经过 MCU：摄像头直接进 FPGA，网口和 HDMI 分别承担既定视频回传。

| 链路 | 用途 | 不能混用的原因 |
|---|---|---|
| 独立 MCU–FPGA UART | 本文的会话、环境测量与角度事件 | 需独立接收、校验和时序归属 |
| 板载 CP2102 / PC–FPGA 控制串口 | 当前板卡的启动、状态及诊断 | 不能把 MCU TX 无仲裁并接到同一 RX |
| MCU 现有 PC 文本串口（若使用相应固件分支） | ASCII 电机/光照命令 | `wake` 等文本命令不符合本文二进制格式 |
| 后续独立 IMU UART | 未冻结型号的融合姿态模块 | 它与 MCU 测量事件不是同一已确认数据源 |

物理接口暂按 **115200 bit/s、8 数据位、无校验、1 停止位（8N1）、空闲高、无流控**设计；电平、FPGA 引脚、接插件、MCU 型号及实际独立 UART 接线**尚未冻结**，接线前必须核对双方 IO 电平，不能直接接 RS-232/RS-485。现有 `fpga/rtl/control/mcu_protocol.v` 实现了协议端点及离线仿真；MINI 板级顶层的 `env_*` 输出目前悬空，MCU 固件适配和实物联通尚未验收。当前可用的 CP2102 诊断口不等于独立 MCU 口已经接好。

## 2. 帧格式和校验

```text
字节顺序：55 AA | version:u8 | cmd:u8 | seq:u16 | length:u16 | payload[length] | crc16:u16
固定值：  帧头        version=01
字节序：  除逐字节字段外，所有多字节整数及 CRC 均为小端
```

CRC-16/CCITT-FALSE 参数：多项式 `0x1021`、初值 `0xFFFF`、不反射、xorout `0`；覆盖 `version` 至 payload，**不**覆盖帧头和 CRC 本身。校验向量 `123456789 → 0x29B1`。示例：能力查询 `seq=1` 的完整请求为 `55 AA 01 01 01 00 00 00 55 97`（最后两字节为小端 CRC）。`seq` 只用于请求/应答配对，可回绕，不是测量事件的身份。

协议层 payload 上限 1024 字节；本端 V1 **请求上限 32 字节**，所有响应 payload 固定 **32 字节**。长度不符、CRC 失败或 UART 错误不会更新测量状态。应用端建议一次只保留一个未确认请求。

## 3. 命令

| cmd | 名称 | 请求 payload | 作用 |
|---:|---|---:|---|
| `0x01` | `GET_CAPABILITIES` | 0 字节 | 读取协议/本端长度、能力位、波特率与当前 epoch；不要求已打开会话 |
| `0x02` | `OPEN_SESSION` | 12 字节 | `epoch:u64 + session_id:u32`，建立或推进会话 |
| `0x03` | `GET_STATUS` | 12 字节 | 同上身份字段；读取板级状态快照 |
| `0x04` | `GET_COUNTERS` | 12 字节 | 同上身份字段；读取接收/错误/应答溢出计数 |
| `0x05` | `GET_BOARD_DIAGNOSTICS` | 12 字节 | 可选只读 PHY/板级诊断，能力 bit4 标识支持 |
| `0x06` | `GET_VIDEO_SNAPSHOT` | 12 字节 | 可选只读视频故障快照，能力 bit5 标识支持 |
| `0x07`～`0x09` | `DVP_GEOMETRY/PROGRESS/PIPELINE` | 各 12 字节 | 可选只读视频链路计数，能力 bit6 标识支持 |
| `0x10` | `SUBMIT_ENVIRONMENT` | 32 字节 | 提交实际测得的照度、角度与测量有效性 |

除 `0x01` 外，请求须带当前非零 epoch 和有效会话。V1 **没有**电机运动、补光设定、视频流开关、标定参数写入或 FPGA→MCU 执行命令；将来要增加这些能力须另行定义命令、鉴权/安全边界和验收，不能把 `0x10` 当作执行指令。

### `0x10` 环境事件 payload（精确 32 字节）

| 偏移 | 字段 | 类型 | 语义 |
|---:|---|---|---|
| 0 | `epoch` | u64 | 本次 FPGA 启动/配置代次，须与当前值一致 |
| 8 | `session_id` | u32 | 非零、当前会话 ID |
| 12 | `event_seq` | u32 | 同一会话内从 1 起严格递增的事件号 |
| 16 | `mcu_time_us` | u32 | MCU 自身微秒计数，约 71.58 分钟回绕 |
| 20 | `lux_milli` | u32 | 实测照度，单位毫勒克斯；无效时不得用于测评 |
| 24 | `angle_mdeg` | i32 | 实测偏转角，二补码，单位毫度；轴向/零位尚待冻结 |
| 28 | `measurement_valid` | u8 | bit0：照度有效；bit1：角度有效；bit7:2 必须为 0 |
| 29 | `reserved` | 3×u8 | 必须全 0 |

两个有效位可分别清零；数值字段即使非零，也不得在对应有效位为 0 时当作实测。`event_seq` 与 `(epoch, session_id)` 共同构成幂等身份。MCU 的设定角度、设定光强或控制命令**不可冒充**实测字段。

## 4. 会话、应答与重试

建议 MCU 启动流程：

```text
读取 GET_CAPABILITIES → 确认 FPGA 的非零有效 epoch
→ 以新的非零 session_id 发送 OPEN_SESSION
→ 按实际测量产生 SUBMIT_ENVIRONMENT（一次一个未确认请求）
→ 需要时查询 GET_STATUS / GET_COUNTERS
```

`link_epoch` 必须由板级集成提供且每次重启/重新配置不复用；当前 RTL 本身不生成可靠的非易失代次。epoch 未就绪时，能力查询仍是协议入口，其余命令返回 `NOT_READY`；但当前板级启动门控可能先要求 PC 完成网络配置，不能据此推断独立 MCU 口已可直接访问。`session_id` 在同一 epoch 内单调增加；MCU 重启后应持久化，或查询当前 ID 再加一。`event_seq` 严格递增且不回绕；最后事件**同内容**重发返回 `DUPLICATE`，不会再次更新 `env_valid`。同号不同内容为 `ID_CONFLICT`；旧号为 `STALE_EVENT`。新会话或 epoch 更换使旧测量失效。

响应仍用同一帧格式，`cmd=0x80` 表示成功或幂等重复，`cmd=0x81` 表示错误；`seq` 原样回显，`length=32`。响应 payload 前 20 字节固定：

| 偏移 | 字段 | 含义 |
|---:|---|---|
| 0 | `result:u8` | 结果码 |
| 1 | `request_cmd:u8` | 原请求命令 |
| 2 | `flags:u8` | bit0 会话有效、bit1 epoch 就绪 |
| 3 | `measurement_valid:u8` | 当前照度/角度有效位 |
| 4 | `epoch:u64` | 当前有效 epoch，未就绪为 0 |
| 12 | `session_id:u32` | 当前会话 ID |
| 16 | `last_event_seq:u32` | 最近接受事件号 |

剩余 12 字节依命令返回能力、计数、只读诊断或 `status_flags + rx_good_count + rx_error_count`，详细位布局见 V1 权威定义。`0x10` 的 ACK 仅证明 FPGA 协议端点**接受事件**，不证明偏转机构已到位、测量与相机曝光同步，或矫正图像已经使用该角度。

| result | 名称 | 典型处理 |
|---:|---|---|
| `0x00` / `0x01` | OK / DUPLICATE | 成功；重复响应按同一事件处理 |
| `0x02`～`0x06` | BAD_CRC、BAD_LENGTH、TIMEOUT、BAD_VERSION、UNSUPPORTED | 检查报文、能力与恢复间隔 |
| `0x07` / `0x08` | BAD_EPOCH / BAD_SESSION | 重新查询 epoch 并建立新会话 |
| `0x09` / `0x0A` | STALE_EVENT / ID_CONFLICT | 检查事件序号或同号内容，不改写旧事件 |
| `0x0B`～`0x0D` | BAD_FORMAT、UART_ERROR、NOT_READY | 修正保留位、检查串口或等待代次就绪 |

接收字节间超时默认 20 ms。普通请求建议以约 100 ms 作为应用层等待值，超时用**相同事件身份及相同 payload**重试；对超长帧或 UART 停止位错误，先留至少 20 ms 空闲恢复期。响应队列固定 8 项；过载可能直接丢请求而无 NACK，故不要持续无确认地灌入事件。

## 5. 偏转角度进入矫正模块的接口边界

成功接受 `0x10` 后，`mcu_protocol.v` 在本时钟域以一拍 `env_valid` 连同 `env_angle_mdeg`、`env_measurement_valid[1]`、`env_session_id`、`env_event_seq`、`env_mcu_time_us` 和 `env_board_time_us` 输出。后一个时间是 **FPGA 接受 UART 报文时刻**，已经包含传输/解析延迟，不是曝光中心。跨时钟域必须整体握手/快照，不可对多位事件逐位双触发器同步。

预留的 `geometry_frame_control.v` 接受已校验的 `env_*` 事件，并要求额外提供**当前** `mcu_context_valid/mcu_epoch/mcu_session_id`；它在帧边界更新活动角度元数据，旧 epoch 或旧会话会使角度失效。`mcu_protocol.v` 目前未对外暴露当前会话 ID，正式连接前需增加只读端口或等价适配。`geometry_frame_control.v` 尚未接到 MINI 顶层，也**未把角度变为旋转系数**。

后续允许角度参与图像矫正前，至少须冻结相机/云台坐标轴、正方向、机械零位与电角度换算；测量 UART/融合延迟及相机曝光中心；按源帧标识选姿态并记录参数版本和有效性。失效、过期或对不上帧时须有明确的保持/旁路策略，不允许静默把最新到达角度当作历史帧姿态。手动 PC 演示角度可单独生成仿射参数，但不能标成 MCU 实测补偿。

## 6. 联调和验收边界

1. 离线：运行 `fpga/scripts/sim_mcu_protocol.ps1`，检查 CRC、长度、会话、重试、错误恢复及有符号角度；再运行 `fpga/scripts/sim_geometry.ps1`，检查事件失效和按帧锁存。仿真通过不代表独立 UART 物理连通。
2. 板级接线前：核对 MCU 型号、TTL 电平、引脚、地线、独立 UART 与 CP2102 隔离，固定 MCU 固件版本和协议测试向量。不得拿现有 PC ASCII 电机口直接代替本协议。
3. 板测：使用实测角度/照度与事件序号，核对 ACK、事件输出、会话重启和帧边界元数据；再以标定的转角/光源和曝光时序验证真正的图像补偿。当前这些实物项目尚未完成，不应写成已验收。

本文件仅是跨端接口设计说明，应随协议、MCU 适配和矫正接入同步更新。源码、固件和实测产物分别落在 `fpga/`、`mcu/`、`host/`，不写入 `output/`。
