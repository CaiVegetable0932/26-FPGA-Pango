# f4_host —— 龙门架控制器的 PC 侧测试工具

> **定位：仅备用调试。** 日常龙门架与云台控制以 host 总上位机的 Web 工作台为主
> （`host/` 里的“MCU 龙门架与云台”面板，接口 `/api/mcu/*`）。本目录工具保留给：
> 无 Python 环境的现场应急、串口排线自检、协议逐字节诊断，以及**轴 3 标定**
> （标定未并入 host）。分工与共同规则见
> [`docs/MCU控制工具与上位机分工.md`](../../../../docs/MCU控制工具与上位机分工.md)，
> host 侧实现细节见
> [`host/docs/MCU手动控制说明.md`](../../../../host/docs/MCU手动控制说明.md)。
> 两套程序不能同时连接同一条 F4 串口。

把 `MCU_POSE_V2` 的二进制帧封起来，让操作者只打 ASCII。

| 项 | 内容 |
| --- | --- |
| 目标 | STM32F407 龙门架控制器（`firmware/longmenjia`），`MCU_POSE_V2` 构建 |
| 串口 | Windows COM 口，默认 115200 8N1，关闭 DTR/RTS |
| 依赖 | 无。Win32 API + C 运行时，不用任何第三方库 |
| 构建 | `gcc -O2 -Wall -Wextra -o f4_host.exe f4_host.c`（MinGW-w64） |

## 为什么需要它

固件在 `MCU_POSE_V2` 构建下，USART3 只接受 `55 AA 02 cmd seq len payload crc` 这种帧，
裸 ASCII 会被逐字节丢弃（不会报错，只是一点回应都没有）。另外每次运动都会启动 1000 ms
控制租约看门狗，**连续 1 s 没有有效报文就全轴停止**。所以用普通串口助手发
`measure 3 start`，轴只会转约 1 秒就自己停。

本工具补上这两件事：

1. 把 `measure 3 start` 这类文本自动封装成 `0x50 LEGACY` 帧；
2. 后台每 300 ms 自动发 `HEARTBEAT`（`0x4C`）续租。

## 构建

```powershell
cd mcu\firmware\longmenjia\tools
gcc -O2 -Wall -Wextra -o f4_host.exe f4_host.c
```

## 自检（不需要硬件）

```powershell
.\f4_host.exe --selftest
```

覆盖：CRC-16/CCITT-FALSE 标准校验值、帧构造/解析往返、分片喂入、前导垃圾与坏 CRC、
回应头字段位置、坐标定点转换、LEGACY 文本长度与字符约束。全部 PASS 才继续。

## 阶段 A：PC 直连 USART3（运动控制）

接线：F4 **PD8** → 模块 RXD，F4 **PD9** ← 模块 TXD，GND 共地，3.3 V TTL。

```powershell
.\f4_host.exe --port COM5 --log f4_20261021.log
```

启动后自动握手：`GET_INFO` → `OPEN`（新 session）→ `SET_STREAM 10`。
看到 `boot_id=...` 和 `会话建立：config=...` 就说明链路通了。

### 建议顺序

```
/confirm 0x03      断电人工摆到零点、上电后确认 X/Y 手动零位
/state             看 valid=0x03、motion=IDLE、fault=0
/move 2 2 5        小范围低速试探方向
/move 0 0 5        回零
/gimbal            raw 应接近 1881 / 2405，确认 F1 链路
/home              云台回正（mask=0x18），至少等 5 s
/posezero          姿态零位，约 5 s 后出结果（无即时回应是正常的）
/gimbal            确认 zero_valid=1
/gimbalgo 10000 -10000    云台 ±10° 定位
```

### 轴 3 标定（走 LEGACY 文本）

```
measure 3 start    从零点以 10 RPM 正转（要求软件位置=0）
measure 3 over     结束并回报圈数（异步 NOTICE 行：measure 3 1.234000）
set 3 1.234000     用回报的圈数设置行程
out 0 10           回到物理零点
state              三个坐标都应是有效值
```

安全约定：

- `measure 3 start` 没有上限、没有限位，只有人工 `over` 才停；10 RPM 下人反应 0.5 s
  ≈ 0.083 圈，第一次务必留足余量。
- 急停用 `stop 3`（比打全 `measure 3 over` 快，但不回报圈数）。
- 缩回能力：探针测得任意小圈数后，`set 3 <该圈数>` 就能让 `out 0 10` 精确退回零点，
  不必断电重来。这是第一次测量的安全阀。
- 标定结果**只存 RAM**，F4 一复位就丢，务必立刻记下圈数。

## 阶段 B：PC 模拟 FPGA（只读）

接线换到 F4 **PC6/PC7**，460800。

```powershell
.\f4_host.exe --port COM6 --mode fpga
```

自动使用 460800、`SET_STREAM 200`。可用的结构化命令：

```
/state  /config  /counters  /sync
```

预期：

- `STATE` 的实际到达率约 **133 Hz**（固件内部有 7.5 ms 发送间隔），不是 200 Hz，属正常；
- `/sync` 收 `0x82`，可看 t1/t2/t3 时戳；
- 试图发 LEGACY 运动命令会得到 `result=6 UNSUPPORTED`（FPGA 无运动权）。

## 交互命令

不带 `/` 的行原样封装成 `0x50 LEGACY`，语义与固件原生文本命令完全一致：
`state`、`measure n start/over`、`set n m`、`go x y s`、`out z s`、`stop n`、`wake`。

| 命令 | 作用 |
| --- | --- |
| `/state` | 二进制 STATE（96 B）：valid、flags、fault、motion_state |
| `/config` | 配置实体，看各轴 `limit`；三轴开机自动 set，应分别为 9114 / 9913 / 4664 |
| `/counters` | CRC/长度/超时/溢出/看门狗计数 |
| `/gimbal` | 云台 raw 与绝对/相对角，判断 F1 链路 |
| `/confirm [mask]` | 人工零位确认，默认 `0x03` |
| `/move x y [rpm]` | `MOVE_ABS` mask=0x03 |
| `/movez z [rpm]` | `MOVE_ABS` mask=0x04（轴 3 必须先 set） |
| `/move3 x y z [rpm]` | `MOVE_ABS` mask=0x07 |
| `/home` | `HOME` mask=0x18（仅云台；F4 的 XYZ 返回 UNSUPPORTED） |
| `/posezero` | `SET_POSE_ZERO`，约 5 s 后出最终回应 |
| `/gimbalgo p y` | 云台相对角度定位（mdeg，±60000） |
| `/ack <id>` | 确认事件，防 64 条环形缓冲溢出 |
| `/sync` | FPGA 专用 SYNC |
| `/stream <hz>` | PC：0/10/20；FPGA：0/100/200 |
| `/open` | 重新握手（板子复位后必须做） |
| `/verbose` | 打印完整帧十六进制 |
| `/wait <ms>` | 等待（脚本化用；等待期间心跳照常） |
| `/help` `/quit` | |

## 排线自检：先证明模块是好的

把 USB-TTL 模块的 **TXD 与 RXD 直接短接**（先拔掉通往 F4 的线），然后：

```powershell
.\f4_host.exe --port COM8 --loopback
```

- `PASS` → 模块收发与电平正常，问题在 F4 那一侧（接线/引脚/固件/供电）；
- `FAIL：一个字节都没回来` → 短接没生效或模块/驱动有问题。

`--loopback` 不做握手、不发命令，只发 3 个探针帧并逐字节比对回波，所以能干净地
把"PC+模块"和"F4+接线"两段分开。

## 一点数据都没回来时怎么读

```powershell
.\f4_host.exe --port COM8 --raw
```

`--raw` 会打印收到的每个字节。判读方式：

| 现象 | 结论 |
| --- | --- |
| 0 字节（115200 和 460800 都是） | 发送方向不通：TX/RX 接反、没共地、模块 VCC 用 5 V 导致 3.3 V TX 低于 VIH，或根本没接在同一只模块上 |
| 有字节但不成帧（选 115200） | 接错口了：PA9/PA10 或 PC6/PC7 是 460800，用 `--baud 460800` 复核 |
| 有帧但 `result=5` | boot_id 过期，`/open` |

注意：V2 固件在收到请求前**不会主动发任何东西**（状态流要 OPEN 之后才开始），
所以"0 字节"本身也可能意味着"我们发的 GET_INFO 根本没进到 F4"。

## 故障排查

| 现象 | 原因 |
| --- | --- |
| 没有任何回应 | 口名错、波特率不是 115200、PD8/PD9 没交叉、没共地、BOOT0 误入下载模式 |
| 有回应但 `result=5 BAD_CONTEXT` | boot_id 过期（板子复位过）：`/open` |
| `result=2 BUSY` | 有轴在动，或 100 ms 查询限流 |
| 运动中 1 s 左右自己停 | 心跳没发出去；查 `--heartbeat` 是否 < 1000 |
| `measure` 只转 1 秒 | 同上，租约看门狗 |
| 云台定位 `result=7 NOT_READY` | 没先 `/home` + `/posezero`（`zero_valid=0`） |
| 定位 `result=7 NOT_READY` | 该轴没 `set`（轴 3 开机自动 set，失败才会出现），或没 `/confirm` |
| 事件越积越多 | 没 `/ack`，64 条后 `fault=9` |
| 退出/`Ctrl-C` | 会先发 `wake` 尝试停轴 |

## 已做的验证

- 编译：MinGW-w64 GCC，`-O2 -Wall -Wextra`，**零警告**。
- `--selftest`：32 项全部 PASS。
- 交叉比对：用固件自己的 `firmware/common/wire.c` 与 `wire_frame()` 构造
  `GET_INFO`/`OPEN`/`HEARTBEAT`/`LEGACY`/`MOVE_ABS`/100 B 随机载荷 六种报文，
  与本工具输出**逐字节一致**。
- 未做：真实串口与实板联调（无硬件在手）。首次上板请先跑 `/state` 和 `/gimbal`。
- 2026-10-21 首次实测：COM8（当前在插的 CH340）在 115200 与 460800 下**均收到 0 字节**，
  已用 `--loopback` 与 `--raw` 把"PC+模块"与"F4+接线"两段分开，待现场短接确认。

## 备注

- 本工具只发命令、只读状态，不烧录、不改固件。
- 手动控制（龙门架 XYZ、云台 pitch/yaw、零点确认、回正、姿态零位、急停）已并入 host 总上位机；
  本目录继续承担**轴 3 标定**与现场排障，作为备用入口保留。


---

## cal3.exe —— 第 3 轴标定控制台（双击即用）

标定操作对时序敏感，用通用工具（`f4_host`）需要敲命令、还要记得心跳；这个程序把常用动作压成单键。

### 构建

```powershell
gcc -O2 -Wall -Wextra -o cal3.exe cal3.c -ladvapi32
```

### 使用

**直接双击 `cal3.exe`**：自动枚举串口（跳过蓝牙口，多口时提示选择），完成握手、建立会话并启动 300 ms 心跳。

| 输入 | 发送的文本 | 说明 |
| --- | --- | --- |
| `1` + 回车 | `measure 3 start` | 轴 3 以 10 RPM 正转开始测量 |
| `2` + 回车 | `measure 3 over` | 停止并回报圈数（异步 `[通知] measure 3 x.xxxxxx`） |
| `3` + 回车 | — | 显示已回传的标定数据、脉冲数、以及要执行的 `set 3` 命令 |
| `4` + 回车 | `set 3 <测得圈数>` | 直接把 3 得到的圈数写入行程（无需换工具） |
| `5` + 回车 | `out 0 10` | 以 10 RPM 回到物理零点，验证重复性（需先 `4`） |
| `0` + 回车 | `stop 3` | 急停（比 `over` 快，但不回报圈数） |
| `s` + 回车 | `state` | 打印当前坐标文本 |
| `q` + 回车 | `wake` | 停止全部轴并退出 |

### 设计要点

- **内置心跳**：固件有 1 秒控制租约，缺少心跳时 `measure` 只转约 1 秒就被看门狗停掉。本程序每 300 ms 发一次 `HEARTBEAT`。
- **motion id 处理**：LEGACY 命令要求 motion id 严格大于固件的 `latest_motion`，程序从 `OPEN` 回应的 `latest_motion` 继续递增，否则会收到 `result=10(STALE)`。
- **DTR/RTS 关闭**：避免打开串口时复位目标板。
- **只发不解析状态流**：连接后把 `SET_STREAM` 设为 0，控制台不被 STATE 帧刷屏。

### 标定时的注意事项

1. `measure 3` 没有软限位，只有 `2`（over）或 `0`（stop 3）能停；10 RPM 下 0.5 秒反应约多转 0.08 圈，靠近机械端点时不要用它，改用短脉冲试探。
2. 圈数**只存 RAM**，F4 复位即丢失；测到后立刻记录，随后用 `set 3 <圈数>` 写入行程。
3. 写入行程后可用 `out 0 10` 回到物理零点验证重复性。

---

## cal3.exe 手动姿态控制（2026-10-22 新增）

除轴 3 标定外，`cal3.exe` 现在同时是**最小可用的手动控制台**，双击运行即可。

### 命令

| 输入 | 作用 |
| --- | --- |
| `go X Y Z YAW PITCH [rpm]` | 一条命令同时下发三轴坐标与云台两角。例：`go 20 20 20 20 20` = X/Y/Z 各 20%、yaw=20°、pitch=20° |
| `speed <1..60>` | 设置默认速度（`go` 省略第 6 参数时生效） |
| `wait <ms>` | 等待指定毫秒，便于连续动作 |
| `s` | 查询位置，**已按现场命名换算**（Y=伸缩轴，Z=双电机轴） |
| `c` | `CONFIRM_MANUAL_ZERO`：声明当前位置为三轴零点 |
| `h` | `HOME`：F1 两轴回正（约 10 秒），同时清除 F4 的锁存故障 |
| `z` | `SET_POSE_ZERO`：把回正位置登记为姿态零位 |
| `1` `2` `3` `4` `5` `0` `q` | 轴 3 标定与急停/退出（原功能不变） |

### 复位后必须按顺序恢复

F1 或 F4 任一复位后，所有运动命令返回 `result=7`，需依次执行：

```
c   → 确认三轴手动零位
h   → F1 回正
z   → 登记姿态零位
```

**手动搬动机构后必须先复位 F4 再按 `c`**：`c` 只是把当前软件位置声明为零点，
不会重新测量物理位置，否则坐标系整体偏移，之后按坐标运动可能朝限位方向走。

### 已修的两个工具侧缺陷

- **序号竞争**：心跳线程与主线程共用 `g_seq` 但在锁外自增，可能取到重复序号；
  F4 对重复序号不返回 0/1，就不会刷新 1 秒控制租约，长距离运动中会被判
  `fault=8(LEASE_LOST)` 并中止（实测 40% 行程触发）。已改为锁内自增，
  心跳间隔 300→150 ms，并去掉可能阻塞的 `FlushFileBuffers`。
- **旧事件重放**：启动后 1.5 秒内只 ACK 不打印，避免把上次会话的事件误当成新结果。

### 载荷长度提醒

`HOME(0x48)` 的载荷是 **20 字节**（ctx 12 + id 4 + mask 1 + 保留 3），不是
`MOVE_ABS(0x46)` 的 48 字节；发错长度返回 `result=3(BAD_LENGTH)`。