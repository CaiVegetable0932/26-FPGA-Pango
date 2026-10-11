# Host 后台 FPGA 上电/矫正参数恢复：软件验证

2026-10-11，基于用户指定的 GitHub `fd3335ab4efad8b993c46e949be9c93386cab347`，开发分支 `codex/host-auto-fpga-geometry`。本轮只修改 host，通过现有 UART 协议驱动已实现的 FPGA 矫正，不改 RTL、位流、MCU、网络像素格式或标定原件。

## 已实现

- 后台持续探测唯一已保存 CP2102 的真实 CAPS 应答；USB 出现不等于 FPGA 上电。
- 服务启动/板卡上电顺序不敏感；冷启动复用原网口初始化，热启动严格匹配已保存的 epoch/端点。
- opt-in 参数文件恢复，14 字/模型/增强活动回读，等待帧边界生效和 HDMI 已显示版本一致。
- 相同热启动参数不重复写入；稳定会话只探测 CAPS；断线清除缓存证明并完整回读恢复。
- 独占 UART、失败退避、显式停止取消、手动参数/显示控制优先；无浏览器也运行。
- 网页持久化入口、只读参数审校导入、状态/文件 SHA、实际回读日志；默认不自动上传。
- 保留 fd3335ab 的无标记 HDMI 独立验证、性能诊断和预览链路。Windows 增加独占 TCP 绑定，避免第二个服务绕过已有实例复用；Linux 分支不变。

使用与接口见[操作说明](../../docs/板卡上电自动恢复矫正.md)。

## 实际执行的软件验证

环境：Windows 11 AMD64，Python 3.12.4，Node v24.19.0。串口使用注入的模拟器；HTTP/UDP 使用隔离的 localhost 和 host/build 临时目录。没有执行 Linux/Jetson 设备验证。

| 验证 | 实际结果 | 证据 |
| --- | --- | --- |
| Python 全量回归 | 156 项：155 通过、1 跳过、0 失败/错误；22.655 秒 | [python-tests.json](python-tests.json) |
| 新自动恢复用例 | 19 项全部通过，含实际后台线程无网页恢复 | `host/tests/test_board_autoload.py`，包含在上述报告 |
| Node 全部前端脚本 | 11 个脚本，19/19 TAP 单元通过；含脚本内部断言 | [node-tests.tap](node-tests.tap) |
| app.js / board-autoload.js | Node `--check` 均通过 | 本轮执行，语法检查退出码 0 |
| Git 空白/冲突检查 | `git diff --check` 通过 | 提交前执行 |
| 实板上电、串口参数恢复、HDMI/UVC 图像 | 未执行 | 不以模拟器结果替代 |
| Jetson Ubuntu 22.04 ARM64 / Linux batch ABI | 未执行 | 交给 Jetson 后续验证 |

Python 跳过项为 Linux native batch ABI，在 Windows 不适用。Node TAP 部分脚本封装多个自有断言；19 是测试运行器的单元数，不把它称作全部像素/DOM 断言总数。生成的像素、记录、UVC 和帧率子报告保存在本目录，原历史报告恢复为原件。

主要覆盖：默认关闭、文件/类型/范围验证、损坏参数拒绝、旧固件拒绝、冷启动 14 字上传、同参数热重启不重写、失联后恢复、反复探测不上传、未知热启动端点不强制写入、摄像头等待、模拟源保护、UART 互斥、中途取消不继续 COMMIT、显示版本不一致不得 ready、无标记映射失败兼容、HTTP token 和只读 GET、配置持久化、退出释放线程。既有全量测试继续覆盖 CRC/序号、端口重编号、网络完整帧、RAW 保存、源身份、性能元数据及标定。

## 初次回归发现与边界

初次旧启动测试因 Windows 的 SO_REUSEADDR 允许重复监听而停滞；仅停止了本轮 unittest 进程。此失败分支创建的 host 后台只枚举设备，因找不到匹配的保存串口而退出探测，未打开物理 UART、未发送命令，记录保留在 [initial-run-unmatched-port.jsonl](initial-run-unmatched-port.jsonl)。随后隔离 launcher 测试配置根目录、加固 Windows 端口独占，完整重跑通过。

全量软件测试中，客户端主动断开预览流触发既有 Windows WinError 10053 输出；对应用例通过，不是本轮自动恢复或串口错误。本轮未改视频流的断连处理。

不宣称真实源帧率、完整网口帧率、FPGA 输出帧率、显示帧率或图像精度；没有采集实测图片/RAW/视频，没有 Flash 擦写。所有 HDMI 帧身份仍为 null/unverified，参数/显示头部回读不构成像素来源证明。

## 修改文件分组

| 分组 | 文件 |
| --- | --- |
| 后台/串口/生命周期 | `host/src/pango_video/board_autoload.py`、`board_link.py`、`web_server.py`、`web_launcher.py` |
| 前端 | `host/web/board-autoload.js`、`app.js`、`index.html` |
| 默认示例 | `host/config/board-autoload.example.json`，真实本机配置不随本轮提交 |
| 测试 | `host/tests/test_board_autoload.py`、`test_board_autoload.cjs`、`test_launcher.py` |
| 文档/结果 | `host/docs/板卡上电自动恢复矫正.md`、既有启动/RGB33说明、`host/README.md`、本报告目录 |

## Jetson 下一步

拉取后重启旧 host；首次成功保存本机板卡连接，在首页明确启用并保存自动参数恢复。按说明分别复验启动顺序、真正冷启动、host 热重启、串口拔插、暂停/手动改参、活动与已显示参数版本、真实图像与四段实测帧率。不需要重烧 FPGA，无法确认有效参数/图像时保留错误和日志。
