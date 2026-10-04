# Host 板卡上电启动流程完善

基线：main `81152587`；开发分支：`codex/host-oneclick-startup`。日期：2026-10-02。

## 定位与实现

原 Web `/api/start` 仅绑定 UDP，默认使用 mock 配置，没有调用 RAW8 UART 启动入口；硬件每次冷启动依赖另行生成 epoch/IP/MAC 并运行 Windows PowerShell，因此只启动 Web 无法启动板卡发送。原采集卡控制器只有单次 getUserMedia，没有 USB ID 恢复、驱动暂忙重试和跨页面占用移交。

新增 Windows/Linux 共用 BoardLink：按实际网卡读取 IP/MAC，识别 CP2102，查询固件冷/热启动状态，先绑定 UDP，再保存配置意图并发送既有 0x71；校验 CRC、序号、RAW8 标记与 epoch，打开状态会话并等候完整帧。host 重开使用保存且回读一致的 epoch，ACK 丢失可恢复；未知已配置板卡不重复写 boot。启动阶段和 FPGA sensor/PHY/published/underflow 状态通过页面显示。

新增首屏一键启动、自动连接偏好、独立 HDMI 打开与明确重试入口。采集卡暂忙重试仅绑定原设备，唯一同名设备可恢复 USB 重插 ID，12 秒驱动请求超时后释放晚到流；同源网页通过 BroadcastChannel 移交占用。预览与标定导航可恢复曾打开的视频，显式关闭取消恢复。

实现不含重烧 FPGA、修改网络/防火墙/系统组设置，或杀死外部预览程序。运行会话配置与逐次串口日志归 host/config、host/reports。实际源帧身份、HDMI 信号锁定仍独立验收。

## 已执行验证

- Windows Python 3.12.4：99 项通过，包括网络/标定既有回归、新冷启动、热恢复、ACK 丢失、端口冲突、错误子网、USB 串口重编号、CRC 重同步及 HTTP 令牌保护。记录：[Python 结果](oneclick-startup-python.json)。
- Node：18 项视频设备测试通过，含权限、取消/晚到流清理、设备移除、暂忙重试、唯一名称恢复与重复名称拒绝替代。记录：[设备测试结果](video-input-frontend-tests.json)。
- WSL Ubuntu 22.04 x86_64、Python 3.12.13：新增 `test_board_link.py` 的 10 项全部通过（0.401 秒）。通过 unittest discover 执行，无实际 UART/网卡写入。没有冒充 ARM64 实机回归。
- 新增脚本语法检查通过。浏览器检查一键启动面板、串口/网卡枚举、标定入口和用户预设；标定显示 OpenCV 4.13.0 / NumPy 2.2.6，浏览器没有报告 JS 错误。

## 硬件边界

只读枚举发现 COM15/CP2102 可见；本机“以太网”“以太网 2”“以太网 3”均为 Disconnected。因此未发送本轮板端 boot、未进行真实网口/HDMI 双路画面验收。模拟串口和软件测试不代表实板启动已经通过，也未测试 Jetson 实际摄像头权限及 UVC 驱动。

使用方法见[板卡上电一键启动](../docs/板卡上电一键启动.md)。首次选择物理网卡并完成地址/浏览器设备授权后，保存自动连接偏好，日常只需板卡上电并启动同一份 host。
