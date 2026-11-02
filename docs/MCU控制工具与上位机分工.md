# MCU 控制工具与上位机分工

本文件说明龙门架与云台控制的两套入口谁主谁备，避免同一台机器上同时开两个程序抢占串口，也避免两侧文档各写一套规范。

## 结论

- **日常控制以 host 总上位机为主**：`host/` 的 Web 工作台（“MCU 龙门架与云台”面板，接口 `/api/mcu/*`）。
- **`mcu/firmware/longmenjia/tools/` 下的 C 工具仅用于备用调试与现场排障**，不作为常规操作入口。
- 两者共用同一条独立 F4 串口和同一套 `MCU_POSE_V2` 报文，**不能同时运行**：同一 COM 口会被抢占，两处心跳也会互相干扰租约与运动编号。

## 入口对照

| 场景 | 应使用的入口 |
| --- | --- |
| 龙门架 X/Y/Z 行程定位、云台 pitch/yaw 定位 | host 工作台 “MCU 龙门架与云台” 面板 |
| 零点确认、云台回正、姿态零位登记 | host 工作台（复位后按 零点确认 → 云台回正 → 登记姿态零位） |
| 轴 3（悬臂伸缩）标定 | `tools/cal3.exe`（标定专用，未并入 host） |
| 串口模块排线自检（TX/RX 短接） | `tools/f4_host.exe --loopback` |
| 逐帧十六进制、配置/计数器/云台 raw 等诊断 | `tools/f4_host.exe` 的 `/config`、`/counters`、`/gimbal`、`/verbose` |
| 无 Python 环境的机器上做应急操作 | `tools/cal3.exe` 或 `tools/f4_host.exe` |

## 为什么保留 C 工具

1. 现场没有 Python 环境时，它是唯一可用的控制台；
2. `--loopback`/`--raw` 能把“PC + USB-TTL 模块”和“F4 + 接线”两段故障分开，这是 Web 面板做不到的；
3. 协议字节级自检（`--selftest`）与标定流程（`cal3`）属于一次性/低频工作，留在现场工具里更省事。

## 共同规则

- **角度**：云台 pitch/yaw 单次变化必须 ≥3°。小于舵机死区（实测下限约 2.3°）的指令会被吞掉，但固件仍会回报完成，所以两侧都不能只看“已接受”。
- **坐标**：龙门架 X/Y/Z 为 0..100% 行程百分比，固件内部按 ×1e6 定点。
- **复位后**：必须依次执行 零点确认（`c`）→ 云台回正（`h`）→ 登记姿态零位（`z`），否则后续运动返回 `result=7`。
- **断开即停**：两套工具都靠 1 秒控制租约保活，退出或断开后不再续租，固件会在租约到期后全轴停止。

## 详细文档

- host 侧的命令、帧格式、接口字段与安全规则：[`host/docs/MCU手动控制说明.md`](../host/docs/MCU手动控制说明.md)
- C 工具的构建、自检与排障：[`mcu/firmware/longmenjia/tools/README.md`](../mcu/firmware/longmenjia/tools/README.md)
- 固件侧协议与实测数据：[`mcu/firmware/longmenjia/WIRING_CHECK.md`](../mcu/firmware/longmenjia/WIRING_CHECK.md)
