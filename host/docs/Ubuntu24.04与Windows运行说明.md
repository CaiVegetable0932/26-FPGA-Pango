# Ubuntu 24.04与Windows运行说明

日期：2026-09-07 · 对应[协议与核心实现](千兆网视频协议与上位机实现.md)

## 1. 平台选择

接收核心只依赖Python标准库，没有PySide6、OpenCV、NumPy、抓包驱动或Windows专用视频API。Python的socket支持Windows和Unix平台，当前使用的recvfrom_into避免逐包新建接收字节串。[Python 3.12 socket文档](https://docs.python.org/3.12/library/socket.html)

以Python 3.12为运行基线；Ubuntu 24.04（noble）仓库提供Python 3.12。[Ubuntu软件包](https://packages.ubuntu.com/noble/python3.12) 本轮实际验证环境为Windows与Python 3.12.4，本机没有可运行的Ubuntu/WSL测试环境。以下是移植步骤，尚不是Ubuntu实机通过记录。

路径通过pathlib及脚本自身位置解析，默认配置、采集、报告均在host内；不依赖D盘、E盘、反斜杠或当前终端目录。业务运行不需要PDS。脚本关闭自身字节码缓存，不添加.gitignore规则；已有Git跟踪范围保持不变。

## 2. 无硬件快速验证

以下相对路径命令在项目根目录执行；从其他目录运行时，将脚本路径改成绝对路径即可。Windows用python或py -3.12；Ubuntu用python3。

~~~bash
python3 --version
python3 -B host/scripts/test.py --report host/reports/protocol-tests-ubuntu24.04.json
python3 -B host/scripts/smoke.py
python3 -B host/scripts/benchmark.py --report host/reports/decoder-benchmark-ubuntu24.04.json
~~~

test.py执行固定向量、完整1080p、畸形包、乱序、丢包、冲突、代次、快照、UDP回环和磁盘失败测试。smoke.py启动两个本机进程，传30张1080p合成RAW8并核对一张归档原始字节；第二个场景每帧故意缺一块，预期不输出完整帧。benchmark.py只测预构造数据报在内存中的CRC/重组，不含NIC、socket或存盘。

smoke.py用系统分配的临时UDP端口，把该次配置保存在host/build；原始合成图在host/data/mock-*，结果在host/reports。它们都标记mock。脚本不安装软件、不改网络、不下载参考资料。

Ubuntu若尚未安装Python，可通过系统软件包安装python3；本核心不需要pip安装依赖或改变系统Python。后续GUI、OpenCV和采集后端应使用独立虚拟环境并另做兼容验证，不能把本核心通过当作整套上位机通过。

## 3. 手动模拟收发

终端A先启动接收，等待listening：

~~~bash
python3 -B host/scripts/praw.py receive --seconds 10 --archive-every 30
~~~

终端B发送显式合成数据：

~~~bash
python3 -B host/scripts/praw.py simulate --frames 30 --fps 30
~~~

默认使用[receiver.mock.json](../config/receiver.mock.json)：127.0.0.1、目的50000、来源50001、epoch1、1920×1080、RGGB。模拟器仅允许loopback的mock配置，不会把合成图送往实板。fps为发送节奏目标，实际值以报告为准。

接收结束会输出报告绝对路径。--seconds 0表示持续接收至Ctrl+C；--archive-every 0为不存图；--archive-every 1请求逐帧归档。无GUI消费者时预览替换计数增长正常；磁盘失败或归档拒绝会单独报告。

~~~bash
python3 -B host/scripts/praw.py simulate --frames 2 --fps 5 --drop-index 1
~~~

上述故障测试要有已启动的接收端。缺包对应帧100ms后失败，没有“补零完整图”。CLI正常退出0；配置/传输/存盘故障、缺帧、没有收到完整帧等返回2。返回0也只是本次接收流程状态，不能自动认定硬件验收成功。

## 4. 实板连接配置

将[receiver.hardware.example.json](../config/receiver.hardware.example.json)复制成host/config/receiver.hardware.json，填写回读确认的device_id、peer_ip、stream_epoch，并核对目的port、peer_port、尺寸和bayer_code。模板中的null会让程序拒绝启动；RGGB和端口只是待确认示例。

IP应使用实际板卡地址和PC专用网口地址。默认bind_ip=0.0.0.0允许本机接口接收；正式采集建议绑定对应专用网口的确定IPv4，避免路由/接口歧义。按现场策略放行该接口对应UDP端口，不需要关闭整个防火墙。

~~~bash
python3 -B host/scripts/praw.py receive --config host/config/receiver.hardware.json --archive-every 30
~~~

本次没有UART自动握手，所以必须先由已验证控制工具确认设备能力和身份。source_mode仍为hardware_unverified；不能仅修改标签把未完成验收标为完成。采集重启应由控制适配层通知set_live_epoch；持续采集期间仅PC重连不能重编号既有源帧或快照。

首次联调顺序：固定图案逐字节对比 → 单帧 → 低帧率 → 1080p30持续RAW → 混合快照 → HDMI和主视频同时运行。每阶段保存板端发送完成/丢弃计数、主机包计数和帧号覆盖。图案对齐通过后仍须验证OV5640真实输入与Bayer/曝光配置。

## 5. Ubuntu接收缓冲与性能排查

程序申请SO_RCVBUF=8MiB，并在报告保存请求值与getsockopt返回值。Linux受net.core.rmem_max约束，而且返回值包含内核加倍的记账空间；不要仅按返回数字与8MiB相等判断设置成功，也不要把它等同于可用纯像素缓冲。[Ubuntu socket(7)](https://manpages.ubuntu.com/manpages/noble/man7/socket.7.html)

先读取当前设置：

~~~bash
sysctl net.core.rmem_max net.core.rmem_default
ip -s link
ss -u -m
~~~

若确认缓冲上限不足，可由目标机管理员按现场策略临时提高上限，再重启接收进程；下面只是配置示例，本次未执行：

~~~bash
sudo sysctl -w net.core.rmem_max=16777216
~~~

保留原值并在实验结束按需恢复。该操作影响系统可配置上限，不会自动修复慢磁盘、CPU不足或板端突发；本程序不使用SO_RCVBUFFORCE，也不要求以root运行接收器。

分别核对1000Mbps全双工、端到端MTU1500、NIC硬件接收丢包、Linux UDP RcvbufErrors、应用CRC/重组失败和归档拒绝。系统级计数可能混入其他socket流量，测量时需记录前后增量和接口。不能只记录应用见到的包而声称系统没有丢包。

先以不存图模式验证44,460包/s及62.208MB/s净载荷，再启用预览与采样归档，最后评估全程录像。Python后台线程仍可能竞争CPU；当前性能不足时，先根据测量定位，再把同一线协议的接收/重组下沉到原生后端。Linux批量接收属于后续优化，本次未实现recvmmsg，不声称已经验证原生后端。

## 6. 移植验证清单

| 项目 | 通过证据 |
| --- | --- |
| Python与系统 | 目标机Python版本、Ubuntu版本、网卡/驱动与接口配置 |
| 协议正确性 | test.py通过报告、固定向量、字节顺序与CRC一致 |
| 系统socket | 本机UDP模拟、停止恢复、外部源过滤、超长包拒绝 |
| 实网吞吐 | 板端发送计数、应用完整RAW、系统/网卡丢包、同窗口持续时间 |
| 存盘 | 原始字节与元数据SHA-256、磁盘满/权限错误不生成有效提交 |
| 长稳与快照 | 主视频/RAW/快照独立计数、2小时目标及资源趋势 |
| 身份与质量 | S0不冒充S1；快照描述符实板回读；HDMI未配对仍null/unverified |

Windows单元测试和短本机回环只是软件证据。Ubuntu实机、真实千兆网、板端协议实现、真实1080p30和整机测评各自验收。

## 本机Web界面

现已提供基于浏览器的S0工作台。Windows 双击 [start_web.cmd](../scripts/start_web.cmd)；Ubuntu24.04在项目根目录运行 `sh host/scripts/start_web.sh`。两者自动检查 Python、打开本机页面，并复用同目录已运行的服务；参数与退出步骤见[一键启动说明](一键启动说明.md)。也可直接运行 `python -B host/scripts/web.py`（Ubuntu 用 python3）。默认仅监听 http://127.0.0.1:8765，UDP网卡地址在连接设置中独立指定。无需安装Qt、npm或第三方Python包，Node只用于可选的像素测试。启动、保存、回看、API与限制见[Web界面与核心接入说明](Web界面与核心接入说明.md)。

当前已完成Windows软件联调；Ubuntu目标机器、浏览器交互兼容、真实千兆网卡和HDMI仍未验收。关闭页面不会停止后台采集，正常退出请先停止采集再结束服务。
