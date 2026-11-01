# MINI PG2L100H 独立 MCU UART 接入

2026-10-23。目标 PDS 2022.2-SP6.4 / PG2L100H FBG676 -6。
MCU 协议基准为 22452f36dae80ebac5b5386a60a2e92481862b0e；本文新增板级边界，
不改变 V2/profile 0x4D32 的报文、CRC、命令和姿态有效性条件。

## 接线

| FPGA 端 | MINI J25 | FPGA 管脚 | MCU 工程端 |
| --- | --- | --- | --- |
| mcu_uart_rx | 9 | U19 / L6_G2_16N | F4 USART6 PC6 TX |
| mcu_uart_tx | 10 | T19 / L6_G2_16P | F4 USART6 PC7 RX |
| GND | 1 | GND | GND |

UART 为 460800、8N1、空闲高、3.3V CMOS。J20 必须将 BANK L6/L7 选择为 3.3V。
不连接供电引脚，不使用仅 200H 有效的 J26。本次用户授权设计接线，尚未实际接线；
F4 工程引脚必须与实际板卡核对，不能将该映射当作实物验收。

来源：MINI 硬件指导手册 V1.3 PDF 页37/38/41，以及 mini-base管脚映射.xlsx。
来源原件保留在 reference/盘古100K200K MINI开发板；本次提取证据在
fpga/build/mcu_link_20261023/board_reference.txt。
电气与 CDC 约束按安装目录 doc/User_Constraint_Editor_User_Guide.pdf 核对：
RX 仅约束到第一同步级 rx_meta，后续级继续正常分析；没有把 MCU 域整体设为 false path。
UART 与现有客户端均运行在 DDR 125MHz 域，不新增跨时钟字节总线。

## kind12 / schema1 / body64

通过既有 PC V1 A1/A2/A3 上传，整板参数掩码为 0x1BCA，A0叠加固有kind9/10后
在线掩码为0x1FCA。新增bit12，bit2/4/5为零，最大正文128字节。
A3 成功表示链接策略已提交；该实体不依赖视频源帧边界。
配置更新会暂时关闭链接并撤销旧配置批准，视频算法实体仍按各自源帧规则执行。

| body 偏移 | 类型 | 含义 |
| --- | --- | --- |
| 0 | u8 | enable，0/1；复位为0 |
| 1 | u8 | approve，0/1；完整配置批准，复位为0 |
| 2 | u8 | timing_valid，0/1；具有独立实测时间误差证据，复位为0 |
| 3 | u8 | 保留0 |
| 4 / 8 | u32 | first_session / last_session，包含两端的会话授权范围 |
| 12 | u32 | expected_config_version |
| 16 | u64 | expected_boot_id |
| 24 | u32 | config_entity_crc32，完整264字节 GET_CONFIG 实体的 ISO-HDLC CRC32 |
| 28 | u32 | capture_error_us；启用 timing_valid 时最大1000 |
| 32 | u32 | evidence_id，对应外部归档；非零不等于已标定 |
| 36..63 | bytes | 保留0 |

版本单调递增，version/entity_id 范围 1..0x7FFFFFFF。enable=1 要求非零会话范围，
first 必须严格大于本次 FPGA 生命周期已经保留的 last。整个范围一次保留，
即使尚未使用也不能回收。每次客户端要求重连，使用范围内下一个 ID；耗尽后关闭。
FPGA 复位会清除本地范围记录，因此 PC 必须先持久化分配，再上传，禁止复位后从1重用。
host/src/pango_video/mcu_link_policy.py 提供离线编码和独占持久化分配，不打开串口。
每个 FPGA 安装使用同一本账，账本丢失或回滚时必须从归档恢复，不能直接重建后连接旧 MCU。

approve=1 需要 enable、boot、config_version、evidence_id 全部有效；
FPGA 在客户端读取已经完成线帧CRC校验的完整264字节实体时逐字节计算 CRC32，
并核对 boot 和两处版本。板级CONFIG_DIGEST_ONLY=1仅保留摘要/版本，
不保留或声称可读回完整实体；外部归档仍须保存完整264字节。借用被撤销、UART错误
或缓冲溢出时不发布配置，即使发生在最后字节或配置发布同拍。
不匹配时阻断链接。approve=0 可用于 GET_INFO/OPEN/GET_CONFIG 发现，
状态可读出观察到的 boot/version/CRC，但不 SET_STREAM，不批准姿态。
timing_valid=1 还要求 approve 和 capture_error_us<=1000；实测前保持0。
原 pose selector 的 age+error<=20ms、error<=1ms、配置验证位等条件不放宽。

CRC32用于完整配置绑定，不是密码学签名。外部必须归档完整配置、来源和实际验证记录，
不能只凭 CRC 相等或 evidence_id 非零认定物理中心、轴向、相机外参已经验收。

## A4 kind12 的八页冻结状态

总长度192字节，每页24字节；先 page0，再按顺序读取1..7，支持既有同序号页重试。
32字节标准头：schema=1、kind=12、active version/id、body_length=160、
flags.bit0=active_valid、error；epoch/frame 恒为0（本实体不按源帧应用）。
偏移32..95为活动策略64字节，后续为诊断：

| 记录偏移 | 内容 |
| --- | --- |
| 96 | bit0 enable、1 session_valid、2 mapping_valid、3 config_valid、4 matched、5 blocked、6 scanning |
| 100 | error：0无、2会话范围耗尽、3完整配置不匹配 |
| 104 / 108 | observed_crc32 / observed_config_version |
| 112 | observed_boot_id:u64 |
| 120 / 124 | 当前 session / 范围内自动重连次数 |
| 128 / 132 | UART 接收字节计数 / framing error计数 |
| 136 / 140 | 已消费事件数 / 最后事件ID |
| 144..183 | 最后一个完整40字节 EVENT |
| 184 | 本生命周期 last_reserved |
| 其余 | 0 |

事件先锁存完整40字节，再通过 ready 允许既有客户端累计 ACK。此邮箱仅保存最后事件和计数，
不提供无损事件历史归档；需要全量历史时，必须由 MCU/PC另行保留。
客户端在禁用或重启会话时撤销未消费事件，防止旧会话事件被新会话确认。

## 与指定 MCU 提交的剩余边界

22452f3 的 GET_INFO 事件起点与 OPEN 后重放起点不一致仍须在 MCU 修复；
FPGA不猜测跳过缺失事件，也不放宽累计ACK规则。
该提交默认 POSE_CONFIG_VERIFIED=0，因此高频状态不会被误当作已验收姿态。
GET_INFO 的旧 IMU 能力声明仍须由 MCU 更正。控制链路250ms存活窗口不等于视频20ms新鲜度。
详见 output/MCU_FPGA协议适配交付标准_最小FPGA改动_20261023.md。
这些条件不妨碍离线综合与布局布线，但在实际联调前必须解决。
