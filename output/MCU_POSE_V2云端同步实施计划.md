# MCU_POSE_V2 云端同步实施计划

日期：2026-10-21。当前方向以 GitHub MCU 分支 `codex/mcu-test-system` 的 `1db773613f18823d1aca31d210625932657b6fd4` 为基线。[源提交](https://github.com/CaiVegetable0932/26-FPGA-Pango/commit/1db773613f18823d1aca31d210625932657b6fd4)。2026-10-11 的 `adf340927` 是历史导入基线。本次在现有本地 FPGA 分支导入 MCU 组件及配套协议，不合并云端其他开发区或仓库管理规则。

权威协议为 [五轴交接 V1.3 实施版](MCU五轴控制与FPGA通信开发交接文档.md) 和 [MCU_POSE_V2 接口补充](MCU_POSE_V2接口实现补充.md)。V1.3 是文档版本，V2 是线上协议版本，两者不要混用。原本地 V1 稿仅作历史备份，旧 [串口修改方案](MCU对接现有FPGA串口的修改方案.md) 也不作为当前报文依据。本机同步、上游不一致字段的修正与软件验证见 [编码器角度闭环同步记录](../mcu/reports/编码器角度闭环同步记录_20261021.md)；2026-10-11 报告保留历史范围。

## 当前结构与撤销的约定

| 项目 | 当前云端方向 | 后续本地开发要求 |
| --- | --- | --- |
| 控制器 | F4 龙门架 + F1 云台，工程目标 STM32F407xx / STM32F103xB | 保留现有驱动与目录；实物型号/板卡修订另行核对 |
| XYZ | F4 四路 D36A 步进，Y 两路反向配对；软件步数估计 | 使用归一化整数，1000000=旧坐标1.0，100000000=满行程；不解释为µm或编码器测量 |
| 两旋转轴 | F1 JOHO 串口舵机 pitch(ID1) / yaw(ID2) | 撤销旧 pitch/roll 和云台 STEP/DIR 假设；MOVE 必须同时选择两个旋转位 mask=0x18 |
| 角度来源 | 舵机编码器位置反馈，F1 不编译/调用 MPU6050 | signed mdeg；STATE 每轴 source=1，双轴0x05，pose_status=3；IMU bit5=0/时戳0，不能因此拒绝新鲜有效角 |
| 回零 | XYZ 人工断电置零、复位后确认；F1 ready/HOME 回正并稳定标定 | 不实现自动 XYZ HOME；确认接口不执行运动，不能凭设定行程建立真实零位 |
| 新 STOP | 外部0x47、内部0x23已取消，返回UNSUPPORTED | 保留原驱动 `stop n` 和本地故障取消；不宣称新全轴急停或两板同时停止 |
| 对外姿态 | gimbal_pitch_yaw，yaw 是相对机械角 | 未知roll/q_wc为null；不能直接将yaw当图像面内roll或绝对航向 |

代码入口：`mcu/firmware/longmenjia/`（F4）、`mcu/firmware/yuntai/`（F1）、`mcu/firmware/common/`（帧协议/反馈角换算/启动身份）、`mcu/config/`（板卡和初值）、`mcu/tests/`（驱动与协议测试）。配置当前 `hardware_verified=false`，旧 IMU 参数仅作保留参考，舵机轴向、机械中心、相机外参和独立角度真值未验证；Z 正式行程未建立时位置无效。

## 链路及字节接口

| 链路 | 云端工程配置 | 职责 |
| --- | --- | --- |
| PC–F4 | USART3 PD8/PD9，115200、8N1 | PC 运动控制、心跳、查询、事件确认与归档 |
| F4–FPGA | USART6 PC6/PC7，460800、8N1 | FPGA独立会话，只读查询、同步和状态接收；PC不逐包转发 |
| F4–F1 | 两端USART1 PA9/PA10，460800、8N1 | 内部云台任务与状态汇聚 |
| F1–舵机 | USART3 PB10/PB11，115200半双工 | JOHO原驱动，不能发送MCU外层封包 |
| F1–MPU6050 | 历史 I²C1 PB6/PB7 | 当前不初始化、采样或融合；不得作为当前有效姿态源 |

以上为工程配置，电平、线序、干扰、HSI 时钟误差及 FPGA 引脚仍需实物确认。

外层：`55 AA | version:u8=2 | cmd:u8 | seq:u16 | length:u16 | payload | crc:u16`，整数字段小端，CRC-16/CCITT-FALSE覆盖version至payload，最大payload1024B。通过GET_INFO核对profile=0x4D32后才能OPEN；PC/FPGA会话独立。不得将新MCU命令加入现有PC–FPGA旧版本启动帧中。

STATE为96B payload / 106B完整帧，offset40为XYZ三整数，52为pitch/yaw，60为servo_tick_us，68..79必须为0；原速度数组已撤销。offset24 的 IMU 时戳当前为0，32/60 分别保留 XYZ/舵机时戳。有效位决定数值是否可用，零不是有效性的替代；angle_source 每轴1表示舵机反馈，历史2表示加权融合。GET_INFO feature_flags bit1清零、imu_type=0；GET_CONFIG 角轴 state_source=2（编码器），与 STATE 单轴值1属于不同枚举。F4 sample_seq标识状态生成周期，200Hz发送不代表200Hz新舵机反馈。F4始终置近似时间位11，配置验证位默认清除。

MOVE_ABS为48B请求，XYZ速度沿用三项RPM，不采用旧80B请求或新增加速度曲线。HOME只接受F1双旋转轴；人工XYZ零点用0x51，兼容旧文本用0x50，原始云台回读用0x52。精确字段、结果码、序号/会话/事件规则均按主协议实现，不在本文重定义。

## FPGA 下一步

1. 核心已存在独立 MCU V2 字节接口与姿态选择模块；继续用 `mcu/tests/encoder_vectors.json` 的真实 C 序列化向量及故障输入核对 CRC、长度、来源和有界接收，保留视频、PC 配置与 PRAW 协议。板级物理 UART 仍需验收。
2. 实现GET_INFO→OPEN→GET_CONFIG→SET_STREAM→SYNC、STATE接收和EVENT累计确认。FPGA不发送MOVE/HOME等PC专用命令；识别boot/session/config变化并撤销旧姿态与时间映射。
3. 将完整有效快照跨时钟域传递，按源帧锁定实际使用样本及config/sample_seq；分别归档当前 XYZ/舵机时戳、IMU无效标志、接收时刻、年龄和同步质量。过期、会话失效、CRC错误、未同步与未标定须进入明确降级状态。
4. 几何处理前先标定平台→相机外参和pitch/yaw到补偿模型的映射。当前机构±60°与旧规划360°面内旋转指标分别验收，不能互相代替。
5. 具体引脚/IO Bank、电平、CDC、PDS工程/IP/约束改动前查阅本项目PDS 2022.2-SP6.4官方只读资料及匹配板卡参考；仿真和构建产物写入`fpga/`。当前核心字节接口与物理板卡验收是不同阶段；未证明实板 MCU 链路、时序或标定完成前，保持物理使能和配置批准门控。

## 上位机 下一步

`host/src/mcu_pose_v2.py`和`host/tests/test_mcu_pose_v2.py`现已导入，但只提供字节编解码与互操作验证，尚未接入Web工作台。

1. 建立独立PC–F4客户端及会话状态机，识别profile/boot/config后开放运动；不要复用PC–FPGA启动客户端或把MCU状态逐包转发给FPGA。
2. 单独调度每≤300ms HEARTBEAT。SET_POSE_ZERO等长事务期间保持心跳，最终回应/事件决定完成；ACCEPTED不当作到位。查询GET_CONFIG/STATUS/COUNTERS/RAW_IMU/GIMBAL合计每100ms最多一次，长期PC发送预算5760B/s。
3. PC默认10Hz显示/记录状态，按需求支持20Hz；FPGA默认200Hz，支持100Hz。队列取最新完整状态、有界处理，图像接收与GUI刷新不阻塞心跳。
4. 界面标明XYZ归一化单位、人工零点/行程有效性、pitch/yaw及各源质量；无效值展示缺失。保存原始帧、GET_CONFIG实体、固件/配置哈希及boot/session身份；roll/q_wc及物理长度需要独立标定后才能生成。
5. 掉线按实际固件语义显示：F4取消本地任务并暂停内部keepalive，F1忙状态超过1000ms无有效内部请求后自行取消并FAULT；新PC心跳不直接恢复。需要ready/HOME恢复，不能承诺同步紧急停机。

## 验收顺序

先做离线向量、错误帧/重试/重启/会话与超时回归，再验证MCU与FPGA电气连接及收发；随后测发布/反馈/滤波/排队延迟、同步漂移和PC串口实际占用。最后结合人工XYZ零点/行程、舵机中心/轴向/回正、相机外参和独立角度真值验收整机。相机帧绑定、动态几何精度与主视频吞吐另行验证，软件编译成功不作为实板即时性结论。
