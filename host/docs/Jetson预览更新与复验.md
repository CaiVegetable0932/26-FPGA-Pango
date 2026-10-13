# Jetson 预览更新与复验

对应云端规划 `fbccd8b8d` 的 [04 更新交接](../../output/host/04_Jetson显示解码优化与测试交接.md)。本文描述已实现的软件机制和复验入口；实测报告仅留设备本机。软件更新不代表稳定 1080p30、光学延迟或物理重启验收通过。

## 启动

```bash
sh /home/cai/26-FPGA-Pango/26-FPGA-Pango/host/scripts/start_workbench.sh
```

地址为 <http://127.0.0.1:8765/>。更新后重启 `pango-host.service` 并刷新已有主预览页，使 Python 服务、页面与 Worker 使用同一版本。入口复用工作台标签页。

板卡自动恢复功能来自前置提交 `c2b3f274`，沿用已有保存设置。默认监视连接，参数自动下发需在对应设置中明确启用。显示优化不改变摄像头或 FPGA 参数、JetPack、UVC 驱动、电源管理。

## 已实现机制

- 主预览在 Worker 内接收 WebSocket 额度通道：服务端收到一个额度后选择最新完整帧。下一张 RAW 的读取与当前位图提交重叠，但下一次转换仍等待绘制 ACK；最多一张位图和一张待处理 RAW。待处理 RAW 额外等待超过 100ms 时在 GPU 转换前丢弃，重新申请最新帧。模式、尺寸阈值、接收运行和可见性改变时取消旧代次，拒绝晚到结果并关闭废弃位图。协议变更与队列有界均不代表帧率验收通过。
- 不支持该路径的浏览器保留有限 HTTP 请求与 CPU 转换回退。应用层最多一个执行任务和一个最新待处理任务；CRC、完整接收、原始归档与源帧计数独立于预览。派生缓存最多四项、16 MiB，不额外缓存原 RAW。
- 原尺寸 RAW8 经长度、跨度与格式检查后直接上传单通道 GPU 纹理，保留各像素原灰度值。缩小 Bayer、基础彩色和平均灰度保留原有抗混叠及像素算法。
- `/api/clock` 提供单调时钟往返采样；偏移与不确定度始终关联，过期停止跨时钟年龄估算。`window.pangoPreviewDiagnostics()` 给出最近最多 512 帧的阶段分布、最新画面年龄和最多 256 个长任务。Canvas 提交时间不是 GPU 完成或显示器发光延迟。
- `/api/preview-performance` 给出缓存和有界套接字写入统计；不表示浏览器已消费。界面区分绘制 FPS、完整接收 FPS、HDMI 新帧回调与质量计数，并显示接收批次、原生校验启用状态和回退原因。原生加载检查架构、ABI、源码与二进制哈希。

本机通道 `/api/preview-socket` 仅接受可信来源。请求为 `{mode, downscale, after}`，模式 raw/gray/color、比例 1/2；每个二进制响应使用 `<II>` 小端元数据长度及像素长度，随后 JSON 和完整像素，无更新返回 `{"waiting":true}`。不在消息中途截断像素。

## 复验入口

```bash
cd /home/cai/26-FPGA-Pango/26-FPGA-Pango
source host/scripts/env.sh
python -B host/scripts/test.py --report host/reports/preview-update-unit-tests.json
python -B host/scripts/check_preview_update.py --inspect
python -B host/scripts/check_preview_update.py --cycles 20
python -B host/scripts/check_preview_performance.py --seconds 120 --preview-mode raw --label raw
python -B host/scripts/check_preview_performance.py --seconds 120 --preview-mode color --label color
python -B host/scripts/check_preview_performance.py --seconds 120 --preview-mode gray --label gray
```

先完成软件测试和模式切换，再单独测每种模式，不并行运行。`--verify-renderer` 启用独立 Worker/GPU 像素样本检查，`--seconds` 支持到 3600。报告写入 `host/reports/`；`--save-evidence` 才额外保存 RAW/RGB 至 `host/data/`。退出成功只说明脚本执行成功，需阅读 `software_checks`、丢包、源帧缺口、短窗口波动、P99 年龄及其时钟不确定度。报告源码哈希须起止一致，部署后重新加载再测。

```bash
python -B host/scripts/check_hdmi_transport_performance.py --seconds 10 --decoder nvjpegdec --live-decode
python -B host/scripts/check_hdmi_transport_performance.py --seconds 10 --decoder nvv4l2decoder --live-decode
python -B host/scripts/check_fpga_processing_framerate.py --seconds 20
```

HDMI 原生对照释放网页持有的唯一 Hagibis，读取本机插件与 MJPEG 属性，统计原始包及实际解码输出，最终恢复网页。不复位 USB，不修改电源管理。fakesink 成功不能当作网页已接入硬件加速。参考 [NVIDIA 原案例](https://forums.developer.nvidia.com/t/hardware-decoding-of-mjpeg/284525) 与 [R36.4.3 官方说明](https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/Multimedia/AcceleratedGstreamer.html)，以实际安装插件和真实测试为准，不直接套用旧 JetPack 补丁。

## 验收边界

RENH v2 保持“FPGA 增强 RAW8”标签，不能称为传感器原始 S0。HDMI 保持 `source_frame_id=null`、`pairing_status=unverified`；不按到达顺序配对，不以浏览器回调冒充 FPGA 唯一结果。实时几何矫正仍由 FPGA 执行。

多次 120 秒对照、30 分钟长时、五次物理冷启动和 USB 重连需分别留证。服务重启或 DOM 控件切换不能替代物理冷启动；未执行或未通过的项目保持未验收。实测数据、浏览器会话和安装环境按用户约定仅留本机。
