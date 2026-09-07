# Web 上位机界面与接入说明

本版把现有 PRAW V1 接收核心接入本机 Web 工作台。界面包含实时采集、采集记录和连接设置；实现及运行产物全部在 host/。浏览器访问本机 HTTP 服务，FPGA 的 UDP 数据由 Python 进程接收，不经过云端。

## 1. 启动与操作

Windows 可直接双击 [start_web.cmd](../scripts/start_web.cmd)，Ubuntu 在项目根目录执行 `sh host/scripts/start_web.sh`。两者会在服务就绪后自动打开浏览器，重复启动复用同一目录已运行的服务。完整步骤见[一键启动说明](一键启动说明.md)。

也可在项目根目录直接执行：

~~~powershell
python -B host/scripts/web.py
~~~

Ubuntu 24.04 使用同一份源码：

~~~bash
python3 -B host/scripts/web.py
~~~

默认自动打开终端打印的 http://127.0.0.1:8765，也可加 --no-browser 后手动访问。端口被其他应用或旧版服务占用时可以使用 --port 8766，或 --port 0 由操作系统分配空闲端口。所有文件路径按脚本所在位置解析，启动目录可以改变。HTTP 服务只绑定 127.0.0.1；UDP 接收地址由连接设置独立决定。

运行依赖为 Python 3.12 与支持 Worker、Canvas、fetch、AbortSignal.timeout 和 dialog 的现代浏览器。运行本版不需要 npm、Node、Qt、OpenCV 或外部 CDN；Node 仅用于可选的前端像素测试。Ubuntu 使用系统 Python 即可执行标准库代码；尚未在 Ubuntu 24.04 目标机器上实际联调。

1. 默认打开“本机模拟”，点击“开始模拟”，后台子进程向真实 UDP 接收端发送合成 Bayer 校验图。顶部始终显示 MOCK 来源。
2. 查看完整帧率、累计完整帧、有效 RAW 吞吐、CRC/组帧失败，以及来源和接收端地址。基础彩色/灰度按钮只改变预览。
3. “保存最新完整原图”保存服务端最近一张完整、1 秒内的新帧。它可能比浏览器当前显示的帧更新；提示会返回实际入队的源帧号。
4. 自动归档可选关闭、每 30 个完整帧、每个完整帧。选择每 N 帧时，保存第 1、N+1、2N+1…个完整帧。归档压力过大时有界队列拒绝新任务并计数，不覆盖旧证据。
5. 点击“停止”，等待接收退出与归档队列排空。到“采集记录”查看全部图像、全部运行及独立生成报告；完整图像可回看并下载RAW/RGB和原始元数据，运行与其他报告可单独下载。
6. 接实板前停止采集，到“连接设置”选择“板端数据”，填写回读确认的设备身份、源代次、实际 IP/端口和 Bayer 排列，再应用并开始接收。界面设置仅配置 PC 接收端，不向 FPGA 下发参数。
7. 关闭浏览器不会停止后台采集。正常退出时先点击“停止”，再在服务终端按 Ctrl+C；停止按钮不会关闭 Web 服务。默认模拟源最多运行 10 分钟，结束后服务会停止该次采集，可再次启动。

Web 连接设置在当前服务会话内生效；服务重新启动后使用 host/config/receiver.mock.json。每次运行单独保存配置副本，并在报告中记录启动时的核心/前端源码SHA-256，避免修改历史实验参数。多个标签页共享同一个接收会话。

## 2. 页面设计

| 页面 | 已接入的操作与信息 |
| --- | --- |
| 实时采集 | 启停、归档策略、S0 完整帧彩色/灰度预览、保存原图、帧率趋势、吞吐、错误、队列和来源身份 |
| 采集记录 | 全量图像、运行（含未完成）与独立报告；选择/全选、批量删除、原图回看和文件下载 |
| 连接设置 | mock/实板来源、device_id、64 位 stream_epoch、UDP 双端地址、Bayer、分辨率、接收缓冲；采集中锁定 |
| FPGA 结果区 | 明确显示 HDMI 采集未接入、源帧配对 unverified，不生成结果画面或对应帧号 |
| 控制状态区 | 明确显示 UART 未接入；不提供看似生效的灯光、电机、参数或快照按钮 |

S0 预览使用 2×2 Bayer 色块：取 R/B，平均两个 G，并按需要稀疏采样，输出宽度不超过 960。它只用于观察图案、通道顺序和来源，未经白平衡、色彩校准、板端 ISP 等价性或几何精度验证。灰度缩小时平均色块，避免只取单个 Bayer 相位。RGB888 归档可独立回看。

网络完整帧率在消费预览前计数，和浏览器 Canvas 绘制 FPS 分别显示。浏览器状态约每 500ms 更新，预览请求之间至少间隔 125ms；不追求浏览器 30 FPS。没有新帧返回 HTTP 204，超过 1 秒的新鲜度阈值会标记等待/停止，旧画面仍带提示。标签页隐藏时暂停轮询，接收与归档继续。

## 3. 与已有核心的连接

~~~mermaid
flowchart LR
    A[FPGA 或显式 mock 子进程] -->|UDP PRAW V1| B[UDPReceiver 单接收线程]
    B --> C[FrameAssembler 校验与重组]
    C --> D[有界完整帧预览队列]
    C --> E[有界归档队列]
    D --> F[WebSession 最新完整帧]
    E --> G[save_frame 原始证据]
    B -->|线程内状态快照| F
    F -->|本机 HTTP 二进制 RAW| H[浏览器 Worker]
    H --> I[Canvas 基础预览]
    G --> J[RAW/RGB + metadata.json]
~~~

- [web_session.py](../src/pango_video/web_session.py)：生命周期、配置校验、最新帧、采集事件、归档与运行报告。生命周期操作串行化，重复启动拒绝，停止可重复执行；重启清空旧帧并更换 run_id。
- [web_server.py](../src/pango_video/web_server.py)：本机 HTTP API、静态页面、证据查询与下载。
- [web_launcher.py](../src/pango_video/web_launcher.py)：启动与环境提示、同目录服务复用、就绪后打开浏览器，以及 Ctrl+C / SIGTERM 收尾。
- [receiver.py](../src/pango_video/receiver.py)：保留原有接收策略，新增可选 on_status 回调，由接收线程生成状态，避免 HTTP 线程遍历正在变化的组帧表。
- [app.js](../web/app.js)：交互、配置、状态、预览调度和记录操作；[preview-worker.js](../web/preview-worker.js) 与 [pixels.js](../web/pixels.js) 在 Worker 内处理像素，ArrayBuffer 通过 transferable 传递。
- [demo.py](../src/pango_video/demo.py)：显式 mock 校验图和实际 UDP 发送，包含彩条、棋盘、灰阶及移动标记；只能向回环地址发送。
- [storage.py](../src/pango_video/storage.py)：复用原有 metadata-last 提交流程，原图未压缩，SHA-256 来源为 host。未改变 PRAW 64B 报头、1400B 分块或跨端配对语义。

运行目录：

~~~text
host/
  web/                              HTML、CSS、JavaScript
  src/pango_video/                  Python 核心与 Web 适配
  scripts/start_web.cmd             Windows 双击启动
  scripts/start_web.sh              Ubuntu/Linux 启动
  scripts/web.py                    共用服务入口
  scripts/praw_demo.py              交互演示发送器入口
  scripts/web_smoke.py              1080p API/UDP 联调
  data/<run_id>/<帧身份>/image.raw   原始像素
  data/<run_id>/<帧身份>/metadata.json
  reports/<run_id>/receiver-config.json
  reports/<run_id>/mock-sender.log  仅模拟会话
  reports/<run_id>/web-session.json 停止后的运行快照
~~~

采集记录不再限制最近100张图像和30次运行；完整样本支持回看，不完整/组合记录也显示并可整体删除，但不冒充可预览的完整帧。下载像素时复核文件长度与 SHA-256，发现不一致返回错误。当前列表扫描 data/<run>/<sample>/，不把尚未接入的严格快照对目录解释为已支持的采集流程。

## 4. 本机 HTTP API

先 GET /api/session 获取当前状态及内存中的 token。所有 POST 使用 Content-Type: application/json 和 X-Pango-Token；token 不写入报告。错误响应是 {"error":"说明"}。

| 方法与路径 | 输入 | 返回 |
| --- | --- | --- |
| GET /api/health | 无 | service、launcher_api、workspace；启动器用目录哈希识别同一项目，不返回路径或 token |
| GET /api/session | 无 | token、status |
| GET /api/status | 无 | 状态、配置、完整帧身份、核心计数、短窗口速率、事件、历史、能力标志 |
| GET /api/frame?after=<key> | 最近显示的身份，可省略 | 完整 RAW8 二进制与 X-Frame-Info；无新帧为 204 |
| POST /api/start | 可选 config、archive_every、auto_mock | 开始后的状态；mock 默认启动自有发送子进程 |
| POST /api/stop | {} | 停止后的状态；归档仍在排空时返回 409，稍后检查 |
| POST /api/save | {} | 202，queued 或 already_saved_or_queued 及实际 frame_id |
| POST /api/config | 完整配置对象 | 生效的接收配置；采集中拒绝 |
| GET /api/archives | 无 | 全部图像记录，complete区分可预览帧与未完成/组合记录 |
| GET /api/archive/pixels?key=<key> | 列表返回的 key | 经 SHA-256 复核的原始像素 |
| GET /api/archive/metadata?key=<key> | 同上 | 未改写的原始元数据文件 |
| GET /api/runs | 无 | 全部运行，包含未结束或缺少报告的运行 |
| GET /api/report?key=<key> | 列表返回的 key | 原始运行报告 |
| GET /api/records | 无 | 全部archives、runs、reports和total；当前采集记录标记protected |
| GET /api/artifact?key=<key> | 独立报告列表返回的key | 下载host/reports根目录生成报告 |
| POST /api/records/delete | targets数组，每项kind和key | deleted与failed分别列出结果；删除前验证整批范围与运行状态 |

Web JSON 中 stream_epoch、frame_id 和帧号上下界使用十进制字符串，避免 JavaScript Number 对 64 位身份丢精度。下载的证据 JSON 保留原始格式与整数，若第三方客户端解析原始文件，也须使用能保留 64 位整数的解析器。

配置使用现有配置字段。Web 预览允许 2～4096 内的偶数宽高，总 RAW 不超过 8MiB；接收缓冲 64KiB～64MiB；端口 1～65535；mock 限回环 IP 且双端端口不同。实际接收缓冲值在 metrics.socket_receive_buffer_reported 中，Ubuntu 内核可能限制所申请缓冲，调优见 [跨平台运行说明](Ubuntu24.04与Windows运行说明.md)。

静态资源固定白名单，证据路径限制在 host/data 与 host/reports；不支持任意目录浏览。HTTP 限16个并行请求、10秒连接等待；普通控制请求体16KiB，批量删除请求体1MiB，每批最多5000条，界面每次提交100条。校验 Host、Origin、会话 token，不启用 CORS。此服务是本机仪器工作台，不提供账号权限或公网部署能力；不应改绑 0.0.0.0 后直接暴露到网络。

在支持 document.modelContext 的环境中可选注册状态读取、开始本机模拟、停止采集和保存最新原图工具，复用同一操作路径；普通浏览器不依赖这项能力。当前未取得支持该接口的验证环境，不声称 WebMCP 运行时验证完成。

## 5. 验证与后续接入

~~~powershell
python -B host/scripts/test.py --report host/reports/webui-tests.json
node host/tests/test_pixels.cjs
python -B host/scripts/web_smoke.py
~~~

测试和模拟证据见 [Web UI 软件验证记录](../reports/Web_UI软件验证记录.md)。Python 测试覆盖真实本机 HTTP/UDP、来源过滤、CRC、64 位身份、归档/磁盘异常、启停/重启、过期帧和接口边界；Node 测试覆盖四种 Bayer 与灰度/RGB。web_smoke.py 会新增带 MOCK 来源的 1080p 原图与运行报告，不修改实板配置。

后续 HDMI、UART、同帧快照和测评功能应通过独立适配器加入。只有设备身份与能力回读、板端 S1/结果同帧证据、目标 Ubuntu/网卡实测齐备后，才能形成相应验收结论。当前 measurement_ready=false、hdmi_source_frame_id=null、pairing_status=unverified，保持项目既有边界。

本版参考：[Python ThreadingHTTPServer](https://docs.python.org/3.12/library/http.server.html)、[Worker 消息与 transferable 对象](https://developer.mozilla.org/en-US/docs/Web/API/Worker/postMessage)。本地服务与后台像素转换的选择依据这些接口，硬件性能不由这些文档证明。


## 6. 全量记录、删除与对比布局更新

界面统一使用蓝白主题：白色操作面板、浅蓝背景、蓝色活动态与主按钮；错误/删除仍使用红色区分。S0与S2/S3为两个同级视频面板，桌面等宽并排、画面均为16:9，标题/信息/页脚高度统一；窄屏上下排列时仍保持相同尺寸。连接信息已移至两路画面下方。HDMI仍未接入，结果框不显示模拟的FPGA结果。

记录页显示全部图像、全部运行和其他生成报告，无最近条数截断；进入记录页及点击刷新时读取目录，页面可见时约每3秒刷新，选中项在刷新后保留。根目录README与隐藏管理文件不作为生成记录。组合样本按目录整体管理，不把缺少顶层metadata的组合记录当作单帧展示。

每行可选择，表头可选择该类全部可删除记录，也可一次选择所有可删除记录。删除前展示所选明细与范围；确认之后才删除本机文件：

- 图像记录：只删除host/data/<run>/<sample>/及其原始像素、元数据或组合内容，保留该运行的报告。
- 运行记录：同时删除host/data/<run>/与host/reports/<run>/，包括原图、配置、日志和结束报告。
- 独立报告：只删除host/reports/下选中的报告文件。
- 同时选中运行和其图像时按运行去重，不重复删除。当前Web会话正在采集或仍在结束写入的运行拒绝删除。
- 服务端在生命周期操作锁内校验整批记录；只允许列表中存在的对象，拒绝路径越界、符号链接和Windows目录联接，并在递归删除前重新核对绝对路径。文件被占用等运行期错误单独返回，已删除项从选择中移除，失败项可再次选择重试。

历史运行中的“写入帧数”描述当时写入结果，删除图像不会改写原始报告中的历史计数。删除功能测试只操作host/build/下隔离夹具，本次开发没有删除用户已生成的记录。更新测试见[记录管理更新验证](../reports/Web_UI记录管理更新验证.md)。
