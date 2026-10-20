# MCU_POSE_V2 接口实现补充

日期：2026-10-11。对应 `MCU五轴控制与FPGA通信开发交接文档.md` 的 V1.3 实施版。本文件冻结本轮 MCU 适配所需的内部接口与旧功能封装；不表示 FPGA RTL、PC 界面或实板联调已经完成。

> **2026-10-20 变更（优先于下文）**：F1 放弃 MPU6050 姿态融合，pitch/yaw 只用舵机位置反馈。报文布局与长度全部不变，受影响的只有取值：能力 `feature_flags` bit1 恒 0、`imu_type` 置 0、GET_RAW_IMU 与 STATE 的 IMU/零位/零偏字段恒 0；`sample_seq` 改为舵机反馈采样计数。5 s 稳定判据改为"两轴 raw 持续在正对中心 ±12 内"。下文涉及 MPU 采样、六轴融合、安装四元数与零偏标定的段落视为历史设计，不再作为本版实现要求。

## 外部接口

外层固定 `55 AA / version=2 / cmd / seq:u16 / length:u16 / payload / CRC-16/CCITT-FALSE`，小端，CRC 覆盖 version 至 payload。通用回应前 16B 和 STATE 96B 沿用主文档。F4 的 USART3 接 PC，USART6 接 FPGA；两条链路会话独立，FPGA 无运动权限。

| cmd | 请求 | payload | 成功回应 data |
| --- | --- | --- | --- |
| 0x50 | LEGACY，PC 专用 | 上下文12B + request_id:u32 + ASCII 文本1..95B，不含 NUL/CR/LF | 原 F4 文本结果，不含 NUL；执行错误仍保留原语义，通用 result 非 OK 时无 data |
| 0x51 | CONFIRM_MANUAL_ZERO，PC 专用 | 上下文12B + axis_mask:u8 + 3B 零 | config_version:u32 |
| 0x52 | GET_GIMBAL，PC 专用 | 上下文12B | raw两项u16、绝对角两项i32、相对角两项i32、融合角两项i32、source:u8、zero_valid:u8、reserved:u16，共32B |
| 0x91 | LEGACY_NOTICE，F4→PC | 上下文12B + 原 F4 异步文本，不含NUL | 用于原 measure 结果、done/stopped/error 文本；正式动作终态同时通过 EVENT 提供 |

LEGACY 保留 `wake`、`measure n start/over`、`set n m`、`go x y s`、`out z s`、`state`、`stop n`。request_id 使用主文档 motion_id 的严格递增空间，不能与结构化 MOVE/HOME 重复。它是已确认驱动的兼容入口，XYZ 仍为 0..100 归一化值、RPM 1..60。`set` 和测量引起有效配置变化时增加 config_version；wake 停止旧 F4 任务，不重置行程或凭空建立零位。

云台 ready 对应 HOME mask=0x18，也可 LEGACY `ready`；云台 go 的正式表示为 MOVE_ABS mask=0x18、pitch/yaw 单位 mdeg，保留双角度和固定2000ms运动时间。LEGACY `gimbal go pitch_mdeg yaw_mdeg` 为整数调试入口，避免与龙门架 `go` 同名冲突；`get`/`gimbal get` 和 GET_GIMBAL 保留 raw、绝对和相对角回读。当前 F1 驱动把两只舵机视为同一机构，不在旧驱动之外增加单舵机并发任务，MOVE 的两个旋转位必须同时选择。

CONFIRM_MANUAL_ZERO 只接受 XYZ 掩码，不执行运动、不改脉冲计数。对应轴必须停止且已有脉冲计数为0。操作者须先断电人工置于真实零位再启动/复位，然后确认；设置行程或wake不自动确认物理零位。Z 未测量的2圈显示分母仍只用于旧state文本，正式STATE的Z无效。

SET_POSE_ZERO 重新使用中心反馈和5秒舵机居中等待（2026-10-20 起不再做 MPU 校准），期间普通云台运动被锁定；最终成功回应带新配置号和零角，另发 POSE_ZEROED。该事务等待期间必须单独继续 HEARTBEAT，每≤300ms；不使用一次查询阻塞PC心跳。通信超时、舵机报警或回正失败中断等待并返回失败终态。

## F4-F1 内部链路

USART1↔USART1，460800、8N1，沿用版本2外层，30ms整包期限。内部启动代次独立于F4；F4检测F1新boot后撤销旧姿态、时间映射和相关任务，需要重新ready。

| cmd | 名称 | payload |
| --- | --- | --- |
| 0x20 | INFO/keepalive | 0B，回应包括F1 boot；正常时F4每200ms发一次，本地控制故障后暂停 |
| 0x21 | READY | F1 boot:u64，8B |
| 0x22 | GO | F1 boot:u64 + pitch:i32 + yaw:i32，16B，mdeg |
| 0x23 | 保留（已取消） | 不接收全系统停机；返回 UNSUPPORTED，不执行动作 |
| 0x24 | POSE_ZERO | F1 boot:u64，8B；必须已回正、停止且两轴仍在中心容差内 |
| 0xA0 | REPLY | F1 boot:u64 + request_cmd:u8 + result:u8 + reserved:u16，12B |
| 0xA1 | STATE | 下表128B，F1目标发布200Hz，可能替换待发送旧状态 |

内部状态布局：0 boot:u64；8 IMU sample_seq:u32；12 phase:u8；13 zero_valid:u8；14 home_confirmed:u8；15 angle_source:u8；16 imu_capture_us:u64；24/32各舵机capture_us:u64；40融合角2×i32；48舵机相对角2×i32；56舵机raw2×u16；60原始IMU诊断32B；92/96 I2C错误和漏样u32；100/104 pitch/yaw零位i32；108陀螺零偏3×i32(µdeg/s)；120 F1 config_version:u32；124状态生成tick低32位。phase沿用IDLE/MOVING/HOMING/SETTLING/FAULT，数值4保留。**2026-10-20 起：8 处 sample_seq 为舵机反馈采样计数；16 与 60–91 的 IMU 诊断区、100/104 零位角、108 陀螺零偏恒 0；15 处 angle_source 在零位有效后恒为 1（纯舵机）。**

内部请求序号在单次F1启动内递增，不回绕；普通请求可使用至65535，耗尽必须维护重启。相同事务重试只执行一次；默认200ms、2次重试。INFO不占运动事务序号。F1发布时间、舵机和IMU采样时间分开保留，不把200Hz发送说成200Hz舵机反馈。

F4以F1状态生成时间和串行长度估算两端偏移，外部状态始终置时间近似位11；这是软件轮询映射，不宣称硬件同步。正常链路的序列化、排队和滤波延迟上界必须通过实板测量；时钟漂移和队列延迟未验收时FPGA应标记未同步。SYNC的t2在接收中断锁存，t3在启动实际UART传输前更新；锁存到引脚首位偏差仍需测量。

全系统 STOP 已取消，F4 不再通过 0x23 转发停机。F1 仅保留原驱动到位失败、报警和本地链路超时使用的当前位置取消调用，保留扭矩状态；不增加扭矩关闭模式。该本地处理不作为外部全轴紧急停机接口，也不宣称两块开发板同时停止。

PC 租约超时或控制链路故障后，F4 取消本地电机任务、清除待发送 F1 请求和事务重试并暂停 INFO。F1 在运动/回正/标定期间超过1000ms无有效内部请求时自行取消动作、禁止普通运动并报告 FAULT；静止状态发送继续。新 PC 心跳不直接清除故障，F1 退出忙状态后需 ready/HOME 恢复。对已完成的零位保留姿态采集，未完成的标定不写入零位。

## 可复核配置

**MPU6050 本版不启用**（原方案：±2g、±250dps、DLPF_CFG=3、SMPLRT_DIV=4、200Hz、PLL 陀螺参考、FIFO 关闭、DATA_READY 轮询；WHO_AM_I 与配置逐项回读失败不得标定；安装四元数为单位阵）。驱动与测试保留，F1 固件不再初始化 I2C1，也不参与构建。

**融合不再启用**（2026-10-20 起）：pitch/yaw 直接取舵机位置反馈相对正对中心的 mdeg 值，不做重力校正、陀螺积分和加权，阈值 3000mdeg、权重 9:1 等仅作为历史设计保留。舵机无效时不发布有效角；两轴反馈须连续 5 秒停留在正对 raw ±12 内才写入零位，通信超时、回正失败或任一轴越界/反馈中断即重启标定窗口。

F1时钟改为HSI PLL 64MHz，F4为HSI PLL 96MHz；F4四个步进定时器仍保持1MHz计数，通过47预分频与48MHz定时器时钟匹配。旧脉冲驱动代码未改。460800标称速率、内部HSI误差和FPGA IO电平必须实板核对。

boot持久计数使用两块Flash日志，CRC检查且提交标记最后写；失败关闭运动权限。链接脚本保留F4末端两扇区/F1末端两页。不要整片擦除持久代次；升级/恢复流程必须保存身份记录。原始资料和依赖来源见 `mcu/firmware/reference` 和配置文档。

配置实体为 `mcu/config/machine_config.json`、`pose_config.h` 和 `board_interfaces.md`，geometry_id=1 当前对应待实测安装，STATE 的配置验证位默认清除。完成实体与实物核对后设置 `POSE_CONFIG_VERIFIED=1` 并重建。构建脚本记录这些文件的 SHA-256 与固件校验；运行时自动零位、陀螺偏置和 F4 行程仍须通过 GET_CONFIG 原始回应按 boot_id/config_version 归档。

PC 查询 GET_CONFIG/GET_STATUS/GET_COUNTERS/GET_RAW_IMU/GET_GIMBAL 合计限为每100ms一次，HEARTBEAT单独继续。PC发送端以5760B/s预算调度完整帧，确保长期占用不超过115200串口的50%；单帧线占用不作截断。仅FPGA链路适用状态不饥饿超过10ms目标，PC大回应允许完整发送后再发最新状态。实际延迟和端到端占用须上板量测。
