# Web 上位机一键启动验证

日期：2026-09-07。范围：双平台启动入口、本机服务复用、启动提示与正常退出。

## 实际环境与结果

- 执行时间（UTC）：2026-09-07T12:58:11.136055+00:00。
- 环境：Windows-11-10.0.26200-SP0，Python 3.12.4。
- 完整 Python 软件测试：63 项通过，失败 0，错误 0，跳过 0；耗时 10.668 秒。
- 其中新增启动器测试 11 项，其余为既有协议、UDP、归档、会话与记录管理回归。
- Windows 入口通过 cmd.exe 实际调用；Shell 入口通过 Git Bash 5.2.37 实际调用，仍使用 Windows Python。
- 当前 WSL 未安装，未执行 Ubuntu 24.04 实机测试；未操作浏览器 UI，未进行硬件验收。

原始测试输出：[webui-launcher-tests.json](webui-launcher-tests.json)。复核命令（项目根目录）：

~~~powershell
python -X utf8 -B host/scripts/test.py --report host/reports/webui-launcher-tests.json
~~~

## 已验证行为

| 检查 | 实际方法与结果 |
| --- | --- |
| 路径可迁移 | 复制源码、入口、配置和页面到 host/build 内带中文及空格的隔离目录，从另一个工作目录启动，HTTP 页面及状态均返回 200 |
| 启动不采集 | 新服务状态为 idle，running=false；重复调用各入口后保持 idle |
| Windows 入口 | 指定 Python 实际复用服务；自动查找 Python 的帮助输出通过；错误端口及不存在的解释器均返回 2 |
| Shell 入口 | Git Bash 语法检查通过，真实调用可传递端口并复用服务，不存在的解释器返回 2；不等价于 Ubuntu 实机通过 |
| 重复启动 | 同目录同端口复用既有会话，不调用停止，不新建第二个采集服务 |
| 端口身份 | 不复用另一目录实例；拒绝其他 HTTP 内容、非对象 JSON、超长响应和重定向；不自动结束其他进程 |
| 浏览器启动 | 就绪探测通过后才请求打开页面；取消时不打开；Linux 无桌面、浏览器报错或返回失败时给出手动访问提示（浏览器调用使用替身） |
| 正常退出 | 独立 Python 进程内注入 KeyboardInterrupt，实际服务收尾并返回 0；单元测试另覆盖收尾异常时仍关闭 socket 并返回 2 |
| 来源保护 | /api/health 返回应用名、启动接口版本和目录哈希，不返回绝对目录或会话 token；原有 Host/Origin 检查继续适用 |

测试临时文件只在已解析并确认属于 host/build 的目录内创建及清理。没有修改工作区原有采集记录，没有重启或停止用户已有的 Web 服务。

## 相关源码 SHA-256

| 文件 | SHA-256 |
| --- | --- |
| [scripts/start_web.cmd](../scripts/start_web.cmd) | 0139341759d34cc36a1b20a0c77c3580cbc45aced7cced7047d7b9b9068c333b |
| [scripts/start_web.sh](../scripts/start_web.sh) | c9c441bf6919eb36597597b4eed164f10c3bb876dfeb7b14010f95fa12c7f1e6 |
| [scripts/web.py](../scripts/web.py) | cebd255f1f63622d912805d96be8f08bf7cf53a72c4ac7ef3643c419c5e3bef8 |
| [src/pango_video/web_launcher.py](../src/pango_video/web_launcher.py) | 1a1ed0e19b143648809bc280ea3e35df35714f7d85ca275ae6be1c14571c4e34 |
| [src/pango_video/web_server.py](../src/pango_video/web_server.py) | 0a8bdcc66d5d83ed8cde0aaa41c3b3c2261b94f0e7194a2363d4ea1aca653025 |
| [tests/test_launcher.py](../tests/test_launcher.py) | 141ea9f63c1024dcbeb48ca473e7931b6a467206206730158793f3dbdc81f03d |

以上哈希按本机实际文件字节计算，Windows .cmd 使用 CRLF。源码、测试和入口均无新增第三方运行依赖。

## 目标机待验证项

Ubuntu 24.04 上的解释器与 Shell、桌面默认浏览器弹出、Ctrl+C / SIGTERM 和真实硬件采集仍需实机复核。测试中的 Windows KeyboardInterrupt 注入只验证 Python 收尾流程，不替代 Ubuntu 操作系统信号测试或 Windows 关闭终端窗口的行为验证。

本轮不改 PRAW 线协议、帧身份、FPGA 功能或 HDMI 配对语义。真实网口吞吐、1080p30、UART、HDMI 与图像质量仍未因启动器测试通过而取得验收结论。双平台使用方法见[一键启动说明](../docs/一键启动说明.md)。
