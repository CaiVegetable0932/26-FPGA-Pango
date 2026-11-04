# MCU 手动控制说明（host 上位机）

2026-11-03：点击“下发龙门架坐标”或“下发云台角度”后，界面倒计时 3 秒再发送请求，采用点击时的参数。倒计时内可“取消待发指令”；急停立即发出并取消待发运动，关闭或刷新页面也会取消。其他操作保持即时执行；不再自动录制视频。

本文说明 host 工作台里的龙门架与云台手动控制：走哪条串口、发什么帧、有哪些安全门限。轴 3 标定不在 host 内，见 [`mcu/firmware/longmenjia/tools/README.md`](../../mcu/firmware/longmenjia/tools/README.md)。

## 范围

**包含**：位置与角度反馈、龙门架 X/Y/Z 定位、云台 pitch/yaw 定位、零点确认、云台回正、姿态零位登记、急停（轴 3）。

**不包含**：轴 3 标定（`measure`/`set`/`out` 与单键标定台）、`wait` 脚本命令、配置/计数器/云台 raw 等诊断面。这些留在 `f4_host.exe` / `cal3.exe`。

## 串口与会话

- 使用**独立 F4 串口**，115200 8N1，打开前关闭 DTR/RTS；该口不得与 FPGA 串口相同（后端会核对并拒绝）。
- 打开后自动握手：`GET_INFO(0x40)` 校验设备字 `0x4D32` → `OPEN(0x41)` 新会话 → `SET_STREAM(0x43,0,0)` 关闭主动状态流。
- 后台每 200 ms 发 `HEARTBEAT(0x4C)` 续租，并用 `GET_STATUS(0x44)` 取反馈（120 ms 节流）。固件控制租约为 1 秒，**停止续租即等于全轴停止**。
- 浏览器只读后端缓存，刷新页面不会续租；HTTP 轮询（`/api/mcu/status`）不占用串口。

## 报文口径（与固件 `f4_link.c` 一致）

| 动作 | 命令 | 载荷（会话上下文 12 字节之后） |
| --- | --- | --- |
| 龙门架定位 | `MOVE_ABS 0x46` | 共 48 字节：运动号 4 + mask `0x07` + 保留 3 + 目标 5×int32 + 速度 3×uint16（+保留） |
| 云台定位 | `MOVE_ABS 0x46` | 同上，mask `0x18`，前三个目标（XYZ）填 0 |
| 云台回正 | `HOME 0x48` | 共 20 字节：运动号 4 + mask `0x18` + 保留 3（长度写错会得到 `BAD_LENGTH`） |
| 零点确认 | `CONFIRM_MANUAL_ZERO 0x51` | 共 16 字节：mask `0x07` + 保留 3；成功回 `config_version` |
| 姿态零位 | `SET_POSE_ZERO 0x4A` | 仅 12 字节上下文；**无即时回应**，最终结果约 5 秒后到 |
| 急停（轴 3） | `LEGACY 0x50` | 运动号 4 + 文本 `stop 3`（1..95 个可打印 ASCII） |
| 事件确认 | `ACK_EVENT 0x49` | 事件号 4，防止 64 条环形缓冲溢出 |

`MOVE_ABS` 目标顺序是**固件轴序** `(X, 逻辑轴2, 逻辑轴3, pitch_mdeg, yaw_mdeg)`：

- 逻辑轴 1 = 现场 **X**（单电机）
- 逻辑轴 2 = 现场 **Z**（双电机龙门架）
- 逻辑轴 3 = 现场 **Y**（悬臂伸缩）

界面上一律显示现场命名 X/Y/Z，下发时在 `mcu_control._gantry_targets()` 内部重排为 `X, Z, Y`。

## 坐标与角度

- 龙门架坐标是 **0..100 的行程百分比**，下发前 ×1e6，固件按 `0..100000000` 校验。
- 速度 **1..60 RPM**，一次下发三个轴用同一值。
- 云台角度是**相对姿态零位的绝对角**，范围 ±60°，可填任意 0.1°（不再限制为 3 的整数倍）。
- **单次变化门限**：每条定位命令对每个轴都要求 `|目标 − 当前反馈| ≥ 3°`。依据：
  - 舵机可分辨最小步进约 3°，1.6°/2.4° 指令物理上不动作（`mcu/firmware/longmenjia/WIRING_CHECK.md` §13.6-F）；
  - 低于死区的指令会被静摩擦吞掉，**而任务仍返回 `MOTION_DONE`**（同文件 §13.7）——所以“已接受”不等于到位，界面上的反馈对比才是判据；
  - 你方实测下限约 2.3°，因此门限取 3.0° 留余量。
- 反馈缺失（未连接、年龄 >1 s、有效位为 0）时**直接拒绝下发**，要求先读取有效角度，不用旧值猜位置。

## 安全规则

1. 复位或人工搬动机构后：`零点确认 → 云台回正 → 登记姿态零位`，缺一步后续运动返回 `result=7`。
2. 零点确认只是把当前位置声明为零点，**不会重新测量物理位置**；搬动过机构必须先复位 F4 再确认。
3. 姿态零位登记期间（约 5 秒），其它运动与二次登记全部拒绝；结果未知时保留 `unknown` 状态要求人工核对。
4. 急停走 `LEGACY stop 3`。若回执丢失（`STALE`）按“可能已执行”处理，不断开租约；若彻底无回应，**主动停止续租**，让固件在 1 秒租约到期后全轴停止，并把原因写进状态。
5. 断网/关页面不会立即停轴，仍由 1 秒租约兜底；要立即停请按急停。

## HTTP 接口

所有 `/api/mcu/*` 与板卡控制一样受同源校验和 `X-Pango-Token` 保护，字段白名单校验，未知字段直接 400。

| 方法 | 路径 | 字段 |
| --- | --- | --- |
| GET | `/api/mcu/status` | —（只读缓存，不动串口） |
| GET | `/api/mcu/ports` | — |
| POST | `/api/mcu/connect` | `port` |
| POST | `/api/mcu/gantry` | `x`、`y`、`z`（0..100）、`rpm`（1..60 整数） |
| POST | `/api/mcu/move` | `pitch`、`yaw`（±60，单次变化 ≥3） |
| POST | `/api/mcu/confirm` | — |
| POST | `/api/mcu/home` | — |
| POST | `/api/mcu/zero` | — |
| POST | `/api/mcu/stop` | — |
| POST | `/api/mcu/read` | — |
| POST | `/api/mcu/disconnect` | — |

状态字段要点：`connected`、`angles{pitch,yaw}`、`age_ms`（>1000 时角度置空）、`state.xyz_normalized_micro[3]`（÷1e6 得行程百分比）、`state.motion_state`、`state.fault_code`、`zero_operation`、`last_command`、`last_notice`、`recent_notices`。

## 测试

```powershell
cd host
$env:PYTHONPATH='src;tests'
python -m unittest test_mcu_control test_mcu_pose_v2 -v
node tests/test_mcu_ui.cjs
```

覆盖：握手/上下文、`MOVE_ABS` 三轴轴序与 mask、3° 门限（2.9° 拒绝 / 3.0° 通过）、反馈过期拒绝、零点确认回填、急停文本帧与无回应兜底、NOTICE 会话归属、前端门限与急停可用性。

真机联调仍需现场确认：`确认零点 → 回正 → 登记零位 → 龙门架小幅定位 → 急停`，并把实际反馈写入记录。本说明不代表已完成实板验证。
