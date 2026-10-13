# Jetson 上位机显示解码优化与测试交接

日期：2026-10-13。代码分析基线：`origin/main` 的 `c2b3f274896f3b14e0f7887be227a5f4833e7b1b`。

建议先完善延迟与后端诊断，再减少全尺寸 RAW 显示拷贝和预览积压，最后在实际 Jetson 上对比浏览器采集与原生硬件解码。本次交付仅包含修改建议和测试方案，未实现这些新增优化，也未执行新的 Jetson 实测。Jetson 端可以先按第 6 节采集现有版本基线，再逐项修改和对比。

## 1 适用范围与现有证据

实现代码、构建脚本和测试分别放入 `host/src/`、`host/web/`、`host/scripts/`、`host/tests/`；原始采集与元数据放 `host/data/`，实测报告放 `host/reports/`。本目录只保存规划，不放实现和实测产物。

两条链路分别分析：

- 网口 RAW8：UDP 收包、协议校验、组帧、基础可视化、浏览器显示。RAW8 没有 JPEG/H.264 这类压缩解码，不能直接套用视频硬件解码器。
- HDMI 回采：Hagibis UVC 采集、MJPEG 解码、浏览器或原生显示。现有接入由浏览器 `getUserMedia()` 持有设备。

当前主线已经实现 Linux `recvmmsg` 批量收包、C 校验组帧、半分辨率派生预览、Worker 与 OffscreenCanvas/WebGL、最新待处理帧替换、HDMI 新帧回调，以及降低 UI 状态更新频率。后续优化应在这些机制上迭代。

[硬件配置记录](../../host/config/hardware-inputs.json)保存过 2026-10-04 约 60.718 秒稳定窗口的网络完整帧率 29.892 FPS、网络预览 29.942 FPS、HDMI 历史浏览器统计 29.793 FPS，窗口内记载零 socket 丢包和零组帧失败。该记录同时说明启动阶段曾出现 8284 个 UDP 丢包和 9 次组帧失败。对应完整报告为设备本机留存，不能据此宣称当前主线已完成冷启动、长时稳定性或端到端延迟验收；HDMI 历史数字也不能替代现有新帧回调与内容新鲜度检查。

已留档的环境为 Ubuntu 22.04 ARM64、`5.15.148-tegra`、项目 Python 3.12 和独立 Chromium。Jetson 型号、实际 JetPack/L4T、解码插件和电源模式仍需在测试机读取，不能由内核字符串推定。

## 2 必须保持的数据与职责边界

- 保持既有线协议、CRC、设备来源、布局、重复冲突、超时检查及只发布完整帧的规则，不通过跳过校验提高吞吐。
- 当前固件若报告 `fpga_enhanced_raw8` 或 RENH v2，应明确标为 FPGA 增强 RAW8，不能因数据格式是 RAW8 就称为未处理 S0。基础可视化不等同于 FPGA S1。
- 实时几何矫正仍由 FPGA 承担。Jetson 已有软件矫正只用于独立参考，不作为 FPGA 结果替代品；性能对比必须记录该参考视图是否开启。
- 丢弃旧帧只作用于实时预览分支。完整接收统计、原始归档、帧身份及失败计数独立维护；归档过载须显式报告。
- Hagibis 采集须核对名称、`VID_1DE1/PID_F105` 和唯一物理路径，不回退到其他摄像头。浏览器与原生采集实验顺序进行，不能同时争用设备。
- HDMI 的 `source_frame_id=null`、`pairing_status=unverified` 保持到真实来源证明建立，不能按到达顺序配对。严格精度仍用板端 S1 与 S2/S3 同帧快照。
- RAW/RGB 与元数据作为原始记录；MJPEG 解码得到的 RGB 仍有有损采集来源，不能称为无损 FPGA 像素。PNG/JPEG 仅作派生可视化。

## 3 修改顺序与代码落点

| 顺序 | 修改项 | 主要代码落点 | 验证重点 |
| --- | --- | --- | --- |
| P0 | 延迟、停顿与后端诊断 | `web_session.py`、`web_server.py`、`app.js`、性能脚本 | 能定位耗时段，区分提交显示与实际呈现 |
| P0 | 冷启动与长时测量 | `host/scripts/`、`host/reports/` | 冷启动损失完整记账，长时无持续积压 |
| P1 | 全尺寸 RAW 单通道 GPU 显示 | `preview-worker.js`、`preview-renderer.js`、`pixels.js` | 像素一致，降低 CPU 分配与上传字节 |
| P1 | 预览背压和尺寸协商 | `web_server.py`、`preview-stream.js`、`app.js` | 慢显示恢复后尽快追上最新帧 |
| P1 | 原生接收后端状态 | `linux_udp.py`、`build_udp_fast.py`、启动诊断 | 哈希或架构不匹配可见，回退不冒充性能通过 |
| P2 | Jetson 原生 HDMI 解码对照 | 新建 `host/src/` 后端及 `host/scripts/` 实验入口 | 实际解码器、格式、延迟、CPU 和功耗可核验 |
| P2 | 缓冲复用与 ARM64 热点 | `reassembly.py`、`preview.py`、`raw_batch.c` | 根据 profiling 优化，保留校验和数据生命周期 |

新增或修改代码均按项目约定补充功能块注释，说明用途、关键逻辑和缓冲所有权。

### 3.1 延迟和帧率测量

现有 `frame_info()` 未公开接收与组帧时间；前端 `fetchMs` 主要覆盖浏览器解析一帧的时间，`paintMs` 和 WebGL 调用耗时主要反映 CPU 提交，不代表 GPU 完成或显示器发光。

建议记录：首包接收、组帧完成、派生转换开始与结束、发送开始与完成、浏览器收齐、Worker 开始与结束、提交绘制。每项附带运行 ID、epoch、frame ID、预览模式和尺寸；区分完整网络帧、预览替换、实际观察到的新视频回调、浏览器质量统计与 FPGA 唯一源帧。

后端单调时钟与浏览器 `performance.now()` 不同源，不能直接相减。先用往返采样建立偏移与不确定度，或分别报告两端局部耗时；真正的光学端到端延迟另用可识别光变或帧标记测量。测试开始前定义并记录延迟目标，不将下文的测试时长当作硬件性能承诺。

分布至少包括 P50/P95/P99、最大帧间隔、最新画面年龄、预览队列深度和浏览器长任务。逐帧大日志应改为有界采样和聚合，避免诊断本身影响接收。

### 3.2 全尺寸 RAW 单通道显示

[Worker](../../host/web/preview-worker.js)目前仅对宽度不超过 960 的紧凑派生图绕过 CPU 转换；原尺寸 RAW 会经 [像素转换器](../../host/web/pixels.js)展开 RGBA 后上传。

1920×1080 的 RAW8 每帧为 2,073,600 字节，RGBA 为 8,294,400 字节；30 FPS 对应单份数据流约 62.2 MB/s 与 248.8 MB/s。这只是理论字节量，不是实测节省，也不代表总内存带宽。

建议让经过格式、长度、跨度校验的原尺寸 RAW 直接作为单通道纹理，由着色器输出灰度。根据实际 WebGL 版本选择匹配的纹理格式，继续保留 CPU 回退。缩小显示仍执行完整 Bayer 色块抗混叠；后续彩色着色器须保持 Bayer 排列、取整及灰度权重一致，不能借优化改变算法语义或增加色调曲线。

测试覆盖四种 Bayer 排列、边界像素、原尺寸与缩小模式、颜色模式切换、纹理重建、上下文丢失、非法长度与跨度。原始帧的哈希和归档内容必须不变。GPU 像素回读用于离线一致性测试，不放进每帧生产显示循环。

### 3.3 预览背压和尺寸协商

[服务端](../../host/src/pango_video/web_server.py)连续发送二进制 HTTP 流；[前端](../../host/web/app.js)在接收并解析后才用 `pendingPreview` 替换旧帧。当前实现已限制应用层待处理帧，但不能据此排除 TCP、浏览器流和主线程调度积压，需通过帧年龄确认。

建议先比较有界发送额度或按需拉取方案：消费者只申请少量预览帧，服务端在获得额度时选择最新完整帧，并在派生转换前丢弃过时预览任务。不能在字节流中途直接截断一帧；已发送的消息按协议完整处理或明确关闭连接。WebSocket 也需背压，换传输协议本身不会消除积压。

保留“一个执行中任务和一个最新待处理任务”的上限；可进一步将流读取与解析移入 Worker，减少主线程与 HDMI 显示竞争。多个订阅者可共用按帧身份、模式和尺寸生成的有界派生缓存，避免重复 NumPy 转换。

当前缩放比例在流连接建立时确定，`ResizeObserver` 只更新显示宽度。建议尺寸跨阈值时取消旧流并重新协商，同时加入模式与连接代次，拒绝旧代次结果，关闭未使用的 ImageBitmap。校验高 DPI、全屏、缩放和前后台切换，避免资源泄漏或短暂旧模式覆盖。

### 3.4 接收与缓冲优化

[Linux 接收模块](../../host/src/pango_video/linux_udp.py)当前使用 256 包批次；历史 2026-10-04 配置记录为 32 包，不能把旧报告直接当作现版本的吞吐证明。C 模块仅在源码哈希、二进制哈希、ABI 和架构符合时启用，缺失或不符会回退。

启动状态应显示当前批次、原生模块是否启用和回退原因；部署后重新核对，不只检查 `.so` 是否存在。根据 profiling 再评估 ARM64 CRC、NEON 派生转换、组帧池及输出缓冲复用。不能假定加一个编译参数就让链接的 zlib 获得硬件加速。

`reassembly.py` 完整帧的 `bytes(state.data)` 提供不可变所有权。减少这次拷贝时必须有缓冲引用与归还机制，确保接收线程不会复用仍被显示或归档持有的帧。避免把共享可变内存的错误当作性能收益。

若测得 Python 调度或 HTTP/归档竞争仍影响接收，再考虑独立接收进程或原生服务。扩大 socket 缓冲、固定 CPU 亲和性和调整 IRQ 均应通过对照实验评估，不能以更大的队列掩盖延迟。

## 4 Jetson HDMI 解码专项

当前 `getUserMedia()` 没有显式选择 NVIDIA MJPEG 解码器。WebGL 后端显示 NVIDIA 只说明绘制上下文身份，不证明采集解码使用硬件；需结合浏览器媒体诊断、进程负载和实际管线确认。

原生对照路径为：已验证的 Hagibis V4L2 节点 → `image/jpeg` 采集 → JPEG/MJPEG 解析与匹配解码器 → NVMM 图像 → 必要的转换或缩放 → 原生显示。依据实际安装的 Jetson 插件，分别评估 `nvjpegdec` 或支持 MJPEG 的 `nvv4l2decoder`，不要混淆其他平台同名插件。先读取 `gst-inspect-1.0` 的插件来源、caps 与属性，再制定命令，不把通用示例作为可直接运行的板级配置。

重点比较 CPU 使用率、解码输出帧率、唯一内容更新、延迟分布、温度与功耗。缓冲格式允许时让后续处理留在 NVMM/EGL 等可互操作缓冲中，缩放和颜色转换优先评估 VIC；避免每帧下载成 NumPy RGB 后又上传到 GPU。VIC 格式转换不能直接替代 Bayer 去马赛克。

原生显示成功不等于浏览器内嵌显示完成。若继续使用 Web UI，必须单独评估桥接方式、额外复制和编码延迟；不默认通过“MJPEG 解码后再编码 H.264”接回网页。是否具备目标编码硬件也依赖具体 Jetson 型号。

现有 [鱼眼参考显示](../../host/web/fisheye-preview.js)对视频保留 `texImage2D(video)`，代码注明在当时 Jetson 实测中快于视频 `texSubImage2D`；对固定尺寸 Canvas 则复用纹理存储。保留这种输入类型区分，升级浏览器后用相同输入重测，不统一替换。

Hagibis 现有 UVC 修复绑定 `5.15.148-tegra` 及模块指纹。此次显示优化不要求升级 JetPack、替换驱动或修改系统电源策略；确需升级时，先完成内核 ABI、厂商基线、回退模块与设备格式复核。

## 5 测试矩阵与通过条件

| 场景 | 建议持续时间或次数 | 关注点 |
| --- | --- | --- |
| 仅网络接收 | 120 秒基线，随后长时采样 | 完整帧率、socket/NIC 丢包、组帧失败、CPU |
| 网络预览与 HDMI 原图双路 | 同模式 120 秒至少 3 次 | 回调帧率、完整帧率、延迟分布、最大停顿 |
| RAW 原尺寸与缩小显示 | 各 120 秒 | 原尺寸通道、Bayer 抗混叠、CPU 分配、像素一致 |
| 双路加抽样归档 | 120 秒，再持续 30 分钟以上 | 接收是否受磁盘影响、归档拒绝、RSS 增长 |
| 冷启动 | 至少 5 次，包含 host 先启动和板卡先启动 | 从启动计数，不跳过初期损失，记录首帧时间 |
| 隐藏恢复、全屏、模式切换 | 每类至少 20 次 | 旧帧追赶时间、旧模式覆盖、资源增长 |
| USB 断连恢复 | 独立测试窗口 | 设备身份不漂移、恢复时间、错误可见 |
| 浏览器与原生解码 | 相同设备和输入各 120 秒至少 3 次 | 解码器证明、延迟、CPU、GPU、EMC、功耗 |

这些是建议测试规模，不是已经通过的验收。现有双路性能脚本只覆盖部分场景，冷启动、单路、连续长时与跨端延迟需要扩展脚本后执行。

每轮记录代码 SHA、模块哈希、Jetson 型号、JetPack/L4T、内核、浏览器、显示分辨率、窗口尺寸、采集格式与帧率、电源模式和温度。A/B 测试每次只改一项，模式一致，记录预热条件；稳定窗口与启动窗口分别统计，不能用稳定窗口覆盖启动失败。

最低通过条件：

- 原始数据和帧来源语义不变；参考像素测试通过，GPU/CPU 路径在约定精度下匹配。
- 完整网络帧率不退化；稳定窗口若以无损完整接收为目标，新增 socket 丢包、组帧失败和帧 ID 缺失均须为零。
- 预览过载允许跳过旧画面，但需独立计数；帧年龄不能持续增长，恢复后应回到预先约定的延迟预算。
- 报告平均帧率同时报告尾延迟和停顿；30 FPS 协商值、60 Hz 显示刷新率、UVC 帧数均不能证明 FPGA 每秒产生相同数量的独立新图。
- 长时观察内存、温度和频率，解释降频与异常；功耗和性能改善必须来自同条件实测，不预填提升比例。

## 6 Jetson 端现有版本基线操作

### 6.1 获取文档与确认版本

在 Jetson 仓库根目录使用 Bash。先确认所在分支及工作区；有未提交工作先按原流程保存，有分叉正常解决，不用强制重置或覆盖。以下主线拉取命令只适用于已确认位于 `main` 的工作树：

```bash
# 确认分支和本地改动，再获取远端状态。
git status --short --branch
git fetch origin
git pull --ff-only origin main
git rev-parse HEAD
```

本次云端更新仅新增方案和索引，拉取后不会自动获得 P0/P1/P2 的新增优化。代码修改后应正常重启所属服务，单纯复用旧服务或刷新页面不等于后端代码已更新。

### 6.2 记录机器能力

```bash
# 使用项目解释器；证据全部落在 host 开发区。
source host/scripts/env.sh
pango_run="jetson-preview-baseline-$(date -u +%Y%m%dT%H%M%SZ)"
pango_report="host/reports/$pango_run"
mkdir -p "$pango_report"
git rev-parse HEAD > "$pango_report/code-sha.txt"
uname -a > "$pango_report/kernel.txt"
tr -d '\0' < /proc/device-tree/model > "$pango_report/model.txt"
cat /etc/nv_tegra_release > "$pango_report/l4t.txt"
dpkg-query -W nvidia-jetpack nvidia-l4t-core nvidia-l4t-gstreamer > "$pango_report/nvidia-packages.txt" 2>&1
nvpmodel -q > "$pango_report/power-mode.txt" 2>&1
gst-inspect-1.0 nvjpegdec > "$pango_report/nvjpegdec.txt" 2>&1
gst-inspect-1.0 nvv4l2decoder > "$pango_report/nvv4l2decoder.txt" 2>&1
gst-inspect-1.0 nvvidconv > "$pango_report/nvvidconv.txt" 2>&1
v4l2-ctl --list-devices > "$pango_report/video-devices.txt" 2>&1
lsusb -t > "$pango_report/usb-topology.txt" 2>&1
```

某条命令缺失、包未安装或权限不足时，保存错误并标记能力未确认，不把失败输出当成功结果，也不为完成清单自动升级系统。`nvpmodel -q` 只查询；不执行模式修改或强制锁频。

### 6.3 启动并测量双路预览

```bash
# 复用项目启动入口，保持既有设备身份与连接设置。
sh host/scripts/start_workbench.sh
```

在页面确认真实 FPGA 网络接收与唯一 Hagibis 已打开，选择 HDMI 原图预览。检查 `/api/status` 返回的 `metrics.backend.native_batch_parser` 和 `receive_batch_size`，记录实际后端。只有需要重建原生模块且本机编译依赖已满足时才运行 `python host/scripts/build_udp_fast.py`，随后正常重启服务并重新核对状态。

先检查 `host/scripts/check_preview_performance.py` 的适用条件：当前脚本使用固定网卡 `enP8p1s0`、UDP 端口 50000、服务地址 `127.0.0.1:8765`，依赖项目浏览器调试入口及已经打开的双路画面。测试机配置不同，应先将脚本参数化并验证，不能直接套用。脚本不负责替用户创建真实链路。

```bash
# 在同一 Bash 会话运行；保存 RAW/RGB 发生在测量窗口之后。
python host/scripts/check_preview_performance.py --seconds 120 --label "$pango_run-raw" --preview-mode raw --verify-renderer --save-evidence
python host/scripts/check_preview_performance.py --seconds 120 --label "$pango_run-color" --preview-mode color --verify-renderer
python host/scripts/check_preview_performance.py --seconds 120 --label "$pango_run-gray" --preview-mode gray --verify-renderer
```

各模式先采集基线，优化后按同模式比较；不能把 RAW 与彩色模式的性能差异算成优化收益。脚本在正式取样前等待 5 秒，因此只能作为稳定窗口测试，不能用于证明冷启动无丢包。脚本当前限制 `--seconds` 为 5 到 120，不能直接传入 1800；连续 30 分钟以上测试须扩展采样工具。连续执行多个短窗口也不能替代完整长时观测。

脚本报告自动保存在 `host/reports/preview-performance-*/`；启用证据保存时，HDMI RGB 位于对应 `host/data/` 目录，网络 RAW 通过接收会话归档。将生成路径登记到本轮测试记录；返回码为零不代表所有吞吐、丢帧和延迟条件自动通过，须检查报告具体字段。

另开终端采集 Jetson 资源数据，路径替换为本轮已创建的报告目录；测试结束后用 Ctrl+C 停止该前台采集进程：

```bash
# 前台记录资源、温度与功耗；按实际本轮目录替换路径。
tegrastats --interval 1000 > host/reports/<本轮目录>/tegrastats.log
```

`tegrastats` 可辅助判断负载，但硬件单元字段依型号和版本不同；某项未显示不能单独证明是否硬解。实际桌面与远程桌面显示应分别注明。

## 7 交付与结果回传

每项优化使用独立提交，保留前一可运行版本，先验证软件正确性再进行同条件实测。修改预览不需要改变 FPGA 位流或 MCU 协议。浏览器硬解实验与 UVC 驱动实验分开，降低问题归因难度。

Jetson 测试结果至少附带：

- 基线和候选代码 SHA、原生模块状态、环境清单及各报告路径。
- 原图与派生模式、HDMI 实际尺寸和格式、设备身份、源帧身份状态。
- 完整网络帧率、帧 ID 缺失、socket/NIC 丢包、组帧失败、预览替换及归档拒绝。
- HDMI 新帧回调与质量统计分别列出；延迟分布、最大停顿、CPU/GPU/EMC、温度、功耗和内存走势。
- 结论区分已通过、失败和未覆盖；解释异常发生在启动、稳定运行还是恢复阶段。

## 8 参考资料

- [RAW8 千兆网与 HDMI 双路回传方案](../OV5640_RAW8千兆网与HDMI双路回传方案.md)
- [Jetson RGB33 标定接入说明](../../host/docs/Jetson_RGB33标定接入说明.md)
- [Jetson 本机环境配置](../../host/docs/本机环境配置.md)
- [现有双路性能脚本](../../host/scripts/check_preview_performance.py)
- [NVIDIA Jetson Linux R36.4.4 Accelerated GStreamer](https://docs.nvidia.com/jetson/archives/r36.4.4/DeveloperGuide/SD/Multimedia/AcceleratedGstreamer.html)：解码、NVMM、VIC、转换与显示能力；实际执行须选测试机对应版本。
- [NVIDIA tegrastats](https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/AT/JetsonLinuxDevelopmentTools/TegrastatsUtility.html)：资源字段说明；可用字段以测试机版本为准。
