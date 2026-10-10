# Jetson 与 FPGA 矫正参数联调

2026-10-10。本文随当前参数记录发布；本次没有执行串口上传、图像采集或板测。

## 参数与来源

- 用户审校原件：[fisheye-user-reviewed-20261002.json](../config/calibration/fisheye-user-reviewed-20261002.json)，保留 PC 软件参考身份，不覆盖。
- FPGA 联调记录：[fpga-fisheye-user-reviewed-20261010.json](../config/calibration/fpga-fisheye-user-reviewed-20261010.json)，含相同浮点参数、14 字定点编码、目标固件和未验证状态。

| 项目 | 数值 |
| --- | --- |
| 模型 | fisheye_equidistant，FPGA model=2 |
| 参考/板端尺寸 | 1920×1080 |
| fx / fy | 770 / 752 px |
| cx / cy | 945 / 553 px |
| k1 / k2 / k3 / k4 | 0.121 / -0.118 / 0 / 0.036 |
| 输出水平视场 | 139° |
| 本记录面内旋转 / 增强 | 0° / 开启 |

这是用户审校的手动近似参数，不是完整标定结果。镜头标称 200° 不等于本次透视输出 200°；不改变已选 139°。保留像素中心缩放 `(c+0.5)*scale-0.5` 和现有鱼眼方法。

前 10 字（仿射六字、k1～k4）Q26，后四字（fx/fy/cx/cy）Q16，按有符号 32 位整数小端发送。signed_words 是编码对照值；CLI/Web 仍从 parameters 编码。改变浮点参数或旋转后须重新生成记录，不能把旧数组当成新配置。

## Jetson 获取与启动

在仓库根目录执行；先保存 Jetson 未提交工作，有分叉时正常合并，不强制覆盖：

```bash
git fetch origin
git switch main
git pull --ff-only origin main
sh host/scripts/start_workbench.sh
```

启动入口复用本机环境，不修改系统 Python；依赖/ARM64 内核限制见[本机环境配置](本机环境配置.md)。核对 CP2102 身份和页面配置，不只按 `/dev/ttyUSB0` 序号猜测，不把 MCU 控制口或 JTAG 口当成参数口。

## 推荐：网页下发

1. FPGA 上电且运行 E4DD5BBB…180A2 候选，摄像头正常出帧；点击“启动 / 重连板卡链路”，建立有效 epoch/session。
2. 在“FPGA 几何与显示控制”将新记录 JSON 全文粘贴到参数框；parameters 字段是编码输入。确认旋转 0°、增强开启，点击“上传并验证 FPGA 参数”。只编辑标定页/PC 软件参考参数不会自动改变 FPGA。
3. 选择“FPGA 矫正图”，点击“应用板端显示”。对照时切换“原图”，两模式保持相同灰度 ISP 阶段。
4. 等待实际活动参数版本及已显示版本回读确认，再审校 HDMI。ACK 不是已经显示；超时/构表错误不能用 PC 软件结果冒充成功。

网页经过现有 UART 互斥锁，是联调首选；无需重编译/烧录。参数是易失配置，断电后重新下发。更改参数采用递增版本，不复用同版本不同内容。

## 可选：CLI

已安装项目环境时先 `source host/scripts/env.sh`。离线编码，不开串口：

```bash
python -B host/scripts/fpga_geometry.py host/config/calibration/fpga-fisheye-user-reviewed-20261010.json
```

真实下发须先由 host 建立板卡链路，然后暂停网页参数/标记轮询和其他 UART 操作，确保唯一串口使用者；替换为已核对的 CP2102 端口：

```bash
python -B host/scripts/fpga_geometry.py host/config/calibration/fpga-fisheye-user-reviewed-20261010.json --port /dev/ttyUSB0 --timeout 10
```

不指定 --port 只编码，不算下发。脚本不建立 boot 配置、不替代首次会话初始化、不烧 Flash，也不自动切换 HDMI 模式；显示仍由网页控制。版本默认取当前活动版本+1，不在静态文件里绑定某次运行的 epoch/session/版本。

## 来源与验收边界

- 本次记录 uploaded=false、实际版本=null，不声称板上正使用这组参数。真正上传后保存回复、影子/活动回读、实际版本与首次应用源帧号；Jetson 实测证据分别放 host/data、host/reports。
- FPGA 矫正图走 HDMI，网口仍是增强 Bayer RAW8 / RENH v2，不是矫正后网络视频，也不是未经处理 S0。
- HDMI 没有可信像素身份时保持 source_frame_id=null、配对 unverified，不能按报文到达顺序配对。
- XYZ、pitch/roll 自动补偿、完整彩色 ISP 与新候选真实 1080p30，不因发布参数而变成已验收功能。Jetson GPU 保留为独立软件参考。

完整 UART 接口见[参数接口](../../output/FPGA灰度鱼眼矫正参数接口.md)和[Web 控制说明](FPGA几何与显示Web接口.md)。
