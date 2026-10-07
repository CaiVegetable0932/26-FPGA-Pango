# 26-FPGA-Pango

基于紫光同创 PG2L100H（盘古100Kmini）的图像畸变矫正项目。当前实施基线为单路 OV5640 RAW8 DVP：S0 原图经板载千兆网传给 PC，FPGA 独立完成基础 ISP 与矫正，完整 RGB888 结果经唯一 HDMI 输出回采。真实 1920×1080@30FPS 为必达目标。

2026-10-07 核心集成：已有正式 PDS 工程、摄像头/DDR/网络/HDMI、FPGA 灰度矫正及 20 点硬件标记；本候选时序闭合、Flash 固化和回读通过，用户反馈功能正常。host 含 Linux/Jetson 工作台、标定和独立软件参考；MCU 含三轴 D36A 与二维舵机驱动。完整彩色处理、严格同帧证据、完整 MCU 遥测、测评自动化及新矫正候选四类 1080p30 实测尚未完成，不能将主线合并等同于题目全部验收。MCU 协议差异和实施顺序见[串口修改方案](output/MCU对接现有FPGA串口的修改方案.md)。

- [FPGA 开发区](fpga/README.md)
- [MCU 设备端开发区](mcu/README.md)
- [上位机开发区](host/README.md)
- [当前设计与开发计划](output/README.md)
- [RAW8 千兆网＋HDMI 回传架构与接口](output/OV5640_RAW8千兆网与HDMI双路回传方案.md)
- [上位机专项规划](output/host/README.md)
- [Codex + PDS 开发方案](output/Codex_PDS_快速开发方案.md)
- [参考资料检索索引（仅本地）](reference/内容索引.md)
- [Git 版本管理指南](docs/版本管理指南.md)
- [本地资料与恢复说明](docs/本地资料说明.md)
- [变更记录](CHANGELOG.md)

## 当前验收口径

- 官方双目模组启用一颗相机，1080p30 RAW8 配置须实测，不能以低分辨率 RGB565 例程代替。
- PC 收到 S0 后只做基础彩色预览，不转发主视频、不替代 FPGA 实时矫正；PC 预览不自动等于 FPGA 的 S1。
- 完整原始证据用未压缩 `.raw` / `.rgb` 和元数据保存，PNG 仅用于派生预览。正式精度采用板端 S1 与 S2/S3 同帧快照。
- HDMI 回采与源帧关联尚未验证时明确标记，不能以到达顺序配对。板端帧池按 76MiB 起规划，包含 S0、S1、结果和两个独立快照槽。
- 真实 1080p60 需要更换输入源，并升级或重新设计原图回传；RAW8 60FPS 加协议开销已超过千兆网。
- FPGA 结果可直连独立显示器，加载参数后可脱离 PC 演示；板级功耗与整机功耗分别测量。

## 目录职责

- `fpga/`：FPGA 代码、工程、仿真、参考模型及相关生成结果。
- `mcu/`：MCU 控制固件、设备驱动、板级测试与相关产物。
- `host/`：上位机界面、通信、控制、采集、测评及数据与报告。
- `output/`：仅规划、需求、设计和计划，不存放实现代码或运行结果。
- `docs/`、根目录 `scripts/`：仅仓库管理说明和 Git 备份工具。
- `reference/`、`PDS/`：本地资料，保持现有排除规则。

项目实现直接在三个开发区中修改。后续工作遵循 [项目工作约定](AGENTS.md)，现有规划中旧的实现路径以三个开发区 README 为准。

## 仓库范围

Git 默认管理根目录文件及除根目录 `reference/`、`PDS/` 以外的所有目录中的文件，包括隐藏目录、构建结果和本地配置。VS Code 的源代码管理直接读取根目录 `.gitignore`；新增文件保存后会作为未跟踪文件显示，暂存、提交并推送后才进入云端。Git 不跟踪空目录，如需保留空目录可放置 `.gitkeep` 文件。

`PDS/` 和整个 `reference/`（含内容索引）保留在本机，不进入后续 Git 提交；首次克隆后需单独恢复这些资料。实际参与构建的厂商源码应连同依赖复制到 `fpga/rtl/`、`fpga/ip/` 或 `mcu/firmware/` 等对应开发区，并记录来源。

## 日常使用

在项目根目录打开终端：

```powershell
git status
git switch -c feat/video-input
# 编辑并验证后，按实际改动选择文件
git add -- output/README.md
git diff --cached
git commit -m "docs: 更新设计文档入口"
```

默认主分支为 `main`，功能使用短期分支。首次提交是文档与管理配置基线，不代表可运行的硬件版本。已配置 GitHub 远程仓库 origin；日常推送、标签备份及换机恢复见 [GitHub 云端备份](docs/GitHub云端备份.md)。
