# 2026-10-02 Jetson host 环境配置与验证

结果：本机 Web 上位机软件环境就绪。Ubuntu 22.04.5 / Jetson ARM64，项目 Python 3.12.13；Python 77 项测试、前端像素 11 项测试、实际桌面 Chromium 操作验证全部通过。

## 验证证据

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| Python 环境及本机工具 | Python 3.12.13、Node 22.23.3、pyserial 3.5、Playwright 1.63.0、Chromium 153.0.8010.12、FFmpeg 4.4.2、V4L2 1.22.1 可用 | [环境清单](environment.json) |
| 核心/HTTP/UDP/入口回归 | 77/77 通过，包含真实本机 socket、入口迁移、服务复用与退出 | [Python 测试](python-tests.json) |
| 网页像素处理 | 11/11 通过，含 Bayer、RGB、1080p 与源字节不变性 | [前端测试](frontend-tests.json) |
| 桌面浏览器 | 页面连接、mock RAW8 UDP、Worker 预览、手动保存、原字节校验、停止、记录/设置页通过；页面异常为 0 | [浏览器测试](browser-tests.json) |
| 默认启动 | `sh host/scripts/start_web.sh` 使用项目解释器，复用同仓库服务并打开独立本机浏览器 | [启动入口](../../scripts/start_web.sh) |
| 系统准备 | rmem_max 已设为 16 MiB；8 MiB socket 请求得到 Linux 含开销 16 MiB 返回；cai 已加入 dialout | [环境清单](environment.json) |

浏览器检查在有桌面窗口且 Chromium 沙箱开启的情况下执行，保存 2,073,600 字节模拟 RAW8，SHA-256：`77748d6fc7a77c5d7bf85f19a610c9e2cf07a2927108eb27e9ea5029c4cf84e6`。对应运行 `web-mock-20261002T075517Z-67c73f1e`，完成 45 个完整帧；该短窗口用于功能验证，不能据此宣称本机或板端已达到持续 1080p30。

第一次浏览器自动化检查因测试工具的字符串 eval 与页面 CSP 冲突而退出；修正为定位器与 HTTP 状态检查后通过。没有放宽页面 CSP；失败截图只作本地诊断留档。

## 本机留档

- 页面截图：本目录 `browser-idle.png`、`browser-live.png`；失败诊断 `browser-failure.png`。
- 模拟原图和元数据：`host/data/web-mock-20261002T075517Z-67c73f1e/e1_f35_t1_d1/`。
- 模拟运行报告：`host/reports/web-mock-20261002T075517Z-67c73f1e/`。
- 项目运行时与独立浏览器配置：`host/build/environment/`。

运行时大文件、截图和采集原图保留本地；本次提交保存安装脚本、锁定清单和文字/JSON 证据。未增加 Git 忽略规则。

## 当前设备状态与后续

检查时没有 CP2102、Hagibis 或 `/dev/video*`，有线网口未连接。当前桌面旧进程尚未获得新增 dialout 组，重新登录后生效。已安装的软件工具不代表实际串口、千兆网、HDMI 摄像头来源、完整 30fps 或同帧精度验收通过。

现有 PowerShell UART 工具和 DirectShow 诊断采集仍是 Windows 路径；Linux 实板控制与原始 HDMI 采集后端需要平台适配和接入后验证。操作与重建步骤见 [本机配置说明](../../docs/本机环境配置.md)。
