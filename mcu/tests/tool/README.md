# f1_proxy —— F1 云台的"最小 F4 代理"（台架工具）

在 F4/FPGA 未就绪时，用 USB-TTL 直接驱动 F1 云台固件：输入自然语言式命令，程序负责封装 F1 内部代理帧、维护 boot_id 与序号、自动保活，并把回执和状态帧翻译回文字。

## 构建

```powershell
cd C:\Users\ROG\Desktop\工作\FPGA工作空间\26-FPGA-Pango\mcu
gcc -std=c11 -O2 -Wall -Wextra -o tests\tool\f1_proxy.exe tests\tool\f1_proxy.c -lm
```

工具链：`C:\MinGW\mingw64\bin\gcc.exe`（已有）。零第三方依赖，只用 Win32 串口 API。

## 用法

```powershell
tests\tool\f1_proxy.exe COM7          # 默认 460800 8N1
tests\tool\f1_proxy.exe COM7 460800   # 显式波特率
tests\tool\f1_proxy.exe --selftest    # 不连板，验证帧编解码
tests\tool\f1_proxy.exe COM7 --script run_seq.txt   # 批量执行命令
tests\tool\f1_proxy.exe COM7 --f4sim                # 模拟 F4 跑运动矩阵
```

**先关掉串口助手**：Windows 串口独占，工具打开失败会提示 `cannot open COM7`。

| 命令 | 作用 |
|---|---|
| `info` | 读 boot_id（首条命令会自动做） |
| `ready` | 核验 + 回正两轴，然后等 5 s 舵机居中判据 → `zero_valid=1` |
| `zero` | 重新确认姿态零位（要求已回正、空闲、两轴仍在容差内） |
| `go <pitch> <yaw>` | 相对正对角度，单位度，两轴各限 -60..+60，如 `go 10 -20` |
| `status` | 打印最近一帧 STATE 的解码 |
| `mon on` / `mon off` | 以 5 Hz 滚动打印状态帧 |
| `sleep <ms>` | 脚本模式下延时 |
| `boot` | 打印缓存的 boot_id |
| `help` / `quit` | — |

## `--f4sim`：模拟真实 F4 的控制效果测试

按 F4 的实际行为跑一遍，不需要人工敲命令：

- **200 ms 心跳**（INFO），与接口文档中 F4 的节奏一致；
- **超时重发**：500 ms 无回执就用相同 seq、相同 payload 重发，最多 3 次，用于检验 F1 的重复事务缓存不会二次执行；
- **运动矩阵**：`(0,0) (+20,+20) (−20,−20) (+50,0) (0,+50) (−50,0) (0,−50) (+50,+50) (−50,−50) (+20,+20) (0,0)`，每次运动后停 3 s，最后 `ready` 归零；
- 逐步输出目标 raw、实测 raw、误差（计数与度）、耗时，结束时给出 `max|err|`、`mean|err|`、拒绝次数与链路统计（帧数、CRC 错误）。

实测参考（±30° 矩阵、容差 24 计数）：`max|err|=0.99°`、`mean|err|=0.69°`、CRC 错误 0。

矩阵在 `f4_simulate()` 里，改 `plan[]` 与 `gap_ms` 即可调整行程和间隔。

## 程序替你处理的三件事

1. **boot_id**：从 INFO 回帧取，每次上电/复位自动刷新；`READY/GO/ZERO` 的 payload 与 CRC 都依赖它。
2. **seq**：严格递增；心跳 INFO 用固定 seq=0，不占运动序号。**seq 会按 boot_id 持久化到同目录的 `f1_proxy.seq`**——固件对"同 seq 同内容"直接回缓存结果，进程重启后若从 1 开始会拿到假回执（看着成功其实没执行）。
3. **通信租约**：后台每 200 ms 发一条 INFO，回正/运动期间不会因"没有心跳"被固件本地取消。

## 输出示例（实机）

```text
F1 proxy on COM7 @ 460800 8N1. Type help, quit to exit.
[STATE] phase=idle    zero=0 home=0 src=0 | pitch raw=1873 ang=  +0.000 deg | yaw raw=2365 ang=  +0.000 deg
[INFO]  boot_id = 0x2
f1> [INFO]  boot_id = 0x2
f1> [STATE] phase=idle zero=0 home=0 src=0 sensor=0 i2c_err=0
        pitch raw=1873 ang=+0.000 servo=-0.527 | yaw raw=2365 ang=+0.000 servo=-2.637
```

`i2c_err=0`、`sensor=0` 是**放弃 MPU6050 后的正常值**；若板子里还是旧的融合固件，这里会看到 `i2c_err=1`。

## 帧格式（与固件一致）

```text
55 AA | ver=0x02 | cmd | seq:u16 | len:u16 | payload | crc16
CRC-16/CCITT-FALSE（0x1021, init 0xFFFF），覆盖 ver..payload 末字节，小端
```

| cmd | 含义 | payload |
|---|---|---|
| 0x20 INFO | 心跳/取 boot | 空 |
| 0x21 READY | 核验并回正 | boot:u64 |
| 0x22 GO | 相对运动 | boot:u64 + pitch:i32 + yaw:i32（mdeg） |
| 0x24 ZERO | 确认姿态零位 | boot:u64 |
| 0xA0 REPLY | 回执 | boot:u64 + cmd:u8 + result:u8 + 2B 填充 |
| 0xA1 STATE | 状态 | 128 B，见 `firmware/common/internal.h` |

## 边界

只覆盖 F1 的这四条命令与两种回帧，**不是完整 F4**：没有会话、motion_id、EVENT、GET_CONFIG 和五轴电机。帧编解码部分可以直接搬进 F4 工程复用。
