# 当前上位机与 MCU tools 兼容性检查

检查日期：2026-11-01。**后续修复状态：下述三处运行问题已修复，13 项 MCU 单元测试、32 项 Web 集成测试、页面状态测试与 5 组原始 C 固件交叉回归通过。** 当前仍为云台控制子集，XYZ 与标定功能不在此次修复范围。详见 [修复与验证记录](FIXES.md) 和 `results-after.json`。

以下正文保留修复前的检查结论、工作区指纹与问题证据，其中源码行号对应修复前版本。修复前结论：基础 F4 通信协议兼容，但存在三处运行兼容性问题，不能完整替代 MCU tool。

## 检查版本与范围

- 已通过 `git ls-remote origin refs/heads/codex/mcu-test-system` 在线核对 MCU 分支：`22452f36dae80ebac5b5386a60a2e92481862b0e`。
- 上位机检查对象为当前工作区（包括尚未提交的 `mcu_control.py`、`mcu_pose_v2.py` 及 Web 接入修改），不是仅检查 main 中已提交的代码。文件指纹见 `provenance.json`。
- MCU 工具包括 `mcu/firmware/longmenjia/tools/f4_host.c`、`cal3.c`，以及 `mcu/tests/tool/f1_proxy.c`。后者直接连接 F1，协议职责不同。
- 本次新增报告和复现工具，没有修改业务代码、切换分支或操作实际串口。未进行实板或电机运动验收。

`reference/` 中的文件均由上述 MCU 提交用 `git show` 原样提取，保留原始目录层次；`gateway_bridge.c` 编译其中未经修改的 `f4_link.c` 和 `wire.c`。测试替代了 UART、时钟、XYZ 电机和 F1 反馈，不替代 F4 的帧解析、命令处理、查询限流、零位异步应答和事件队列逻辑。

## 功能对照

| 项目 | MCU tool | 当前上位机 | 判定 |
| --- | --- | --- | --- |
| F4 PC 口 | 115200、8N1，MCU_POSE_V2 | 115200，pyserial 默认 8N1 | 协议一致；实物接线需接 F4 PC 口 |
| 帧封装 | `55 AA 02`，小端序，CRC-16/CCITT-FALSE | 相同 | 实际 C 固件解析通过 |
| 会话 | GET_INFO `0x40`、OPEN `0x41`，boot/session 校验 | 已实现 | 通过 |
| 状态与心跳 | GET_STATUS `0x44`；后台 HEARTBEAT `0x4C` | 后台约每 200 ms 心跳并查询 | 正常间隔兼容；存在查询限流处理问题 |
| STATE 流 | PC 可设 0/10/20 Hz | 设置为 0，主动轮询 | 固件允许，不是协议冲突 |
| 云台定位 | MOVE_ABS `0x46`，48 B，pitch/yaw 使用毫度 | 相同，mask=`0x18` | 交叉验证接受；上位机额外限定 3° 网格 |
| 角度范围/分辨率 | tool 可发 ±60° 内非 3° 整数倍角度，例如 10° | 只允许 -60..60 的 3° 整数倍；反馈保留小数 | 有效指令子集，不能等价复现所有 tool 目标 |
| 云台回正 | HOME `0x48`，20 B，mask=`0x18` | 相同 | 接受回执通过；并非实机到位证明 |
| 登记姿态零位 | `0x4A` 异步等待约 5 s，期间继续心跳 | 同步等待最多约 0.4 s | **不兼容，已复现** |
| 运动完成事件 | 接收 EVENT `0x90` 并 ACK_EVENT `0x49` | 忽略非 `0x80` 应答，未实现 ACK | **不兼容，已复现溢出故障** |
| XYZ 及五轴联动 | XYZ/三轴/五轴 MOVE_ABS、速度参数；cal3 有现场轴映射 | 只发送 pitch/yaw 两轴，XYZ 掩码为 0 | 未实现 |
| 三轴人工零位 | CONFIRM_MANUAL_ZERO `0x51` | 无 API/界面 | 未实现 |
| 行程标定与文本指令 | LEGACY `0x50`：measure/set/go/out/stop/wake 等 | 无 API/界面 | 未实现 |
| 诊断配置 | GET_CONFIG、GET_COUNTERS、GET_GIMBAL，原始串口/回环工具等 | 无对应操作 | 未实现 |
| F1 直连 | f1_proxy：460800、`0x20/21/22/24`，`0xA0/A1` 回帧 | F4：115200、`0x40..`，`0x80/81` 回帧 | 不可直接代替 f1_proxy，应经 F4 访问 F1 |

cal3 的 `go X Y Z YAW PITCH` 命令还将现场 XYZ 映射为固件 `{X,Z,Y}`，并把 pitch 放到载荷偏移 32、yaw 放到偏移 36。当前上位机的 pitch/yaw 偏移正确；未来扩展 XYZ 时必须保留该现场映射，不能直接照搬输入顺序。

## 已复现的问题

### 1. 姿态零位被过早报告为超时

- 上位机 `host/src/pango_video/mcu_control.py:50` 使用两次各 0.20 s 的统一等待，`action('zero')` 直接调用这个同步请求。
- 固件 `reference/mcu/firmware/longmenjia/Core/Src/f4_link.c:422` 接受零位请求后直接返回，不立即发应答；`:683` 在稳定时间超过 5 秒后发送最终回应。tool 的 `f4_host.c:655` 明确支持这一异步行为。
- 使用实际 C 固件，当前上位机在 **0.401 s** 报“MCU 应答超时”，此时固件仍处于 `zero_pending`。继续保持心跳后固件可正常完成，但上位机后续请求会忽略不匹配当前 seq 的旧零位应答，丢失这次操作的最终结果。
- 修复方向：将零位操作作为长期异步事务跟踪，等待期间独立续租、处理事件；不能只把现有持锁等待改成 5 秒，因为那会阻塞心跳并触发固件 1 秒控制租约。

### 2. 未确认运动事件，积累后触发锁存故障

- 上位机 `mcu_control.py:77` 丢弃命令号不是 `0x80` 的帧，没有 EVENT 解析与 `0x49` ACK。
- 固件 `f4_link.c:113` 的事件缓冲为 64 条；第 65 条未确认事件触发 `fault=9`、`sticky_overflow`，并停止控制。`:694` 表明即使 STATE 流率设置为 0，EVENT 仍单独发送。
- 使用实际上位机驱动 C 固件完成 **33 次模拟运动**，事件计数达到 66、ACK 始终为 0，复现 `fault=9`。独立边界测试确认第 64 条无故障，第 65 条触发溢出。现场发生次数取决于遗留事件和失败/回正/零位等额外事件，不能保证总在第 33 次运动才出现。
- 单独断开重连不会清除 `sticky_overflow`。tool 则消费并确认事件，包括启动阶段遗留的旧事件。
- 修复方向：校验 EVENT 上下文、解析并按已收到事件顺序确认、跟踪 motion_id 终态，妥善消费旧事件。

### 3. 查询限流 BUSY 被视为连接故障

- 固件 `f4_link.c:347` 对 PC 的 GET_STATUS 等查询要求至少间隔 100 ms，过快查询返回 `BUSY`。
- 手动“读取角度”和后台查询共用串口锁，但锁只保证不同时发报，不保证最小时间间隔。`mcu_control.py:149` 的后台轮询对任何异常都会关闭串口。
- 复现路径：正常连接 → 手动读取 → 20 ms 后后台心跳和状态查询。实际固件返回 BUSY，当前上位机状态变成 `connected=false`。
- 修复方向：统一查询调度，复用缓存或延迟至允许时刻；对 BUSY 做有界等待，不能当作串口失联直接断开。

## 验证结果与复现

现有 MCU 单元测试 **6/6 通过**，但其内存设备替身会立即回复零位命令，也不执行事件队列及查询限流，所以不足以证明完整兼容。

本次增加 5 组固件交叉检查：基础互操作通过，零位超时、事件溢出、查询 BUSY 断连以及第 65 条事件边界均成功复现。结构化结果见 `results.json`。

在仓库根目录运行：

```sh
PYTHONPATH=host/src python3 -B -m unittest discover -s host/tests -p 'test_mcu*.py' -v
python3 -B host/reports/mcu-tool-compatibility-20261101/check_compatibility.py
```

上面第二条为**修复前问题复现脚本**，断言旧缺陷仍存在，不应作为修复后的通过检查。修复后运行 `python3 -B host/reports/mcu-tool-compatibility-20261101/check_regressions.py`，它保留 `results.json` 历史证据并生成 `results-after.json`。两者需要 GCC，不访问设备。构建日志 `build.log` 有两条原始固件静态函数未使用警告；编译成功。

此外，上位机使用 pyserial 默认的 DTR/RTS 初始状态，tool 显式关闭两者。如果现场模块把这些信号接到 MCU 复位/启动脚，应进一步核对打开串口时的电平行为；本项为源码差异，未做电气验证。

本检查证明的是代码和仿真协议兼容性。完成上述修复后仍需在实际 F4/F1 固件上验证完整的回正、登记零位、连续定位和错误恢复流程。
