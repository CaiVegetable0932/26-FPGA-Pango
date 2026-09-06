# 26-FPGA-Pango

基于紫光同创 PG2L100H（盘古100Kmini）的图像畸变矫正项目。当前处于方案和工具链准备阶段，尚未建立正式 RTL 工程或完成硬件验证。

- [FPGA 开发区](fpga/README.md)
- [MCU 设备端开发区](mcu/README.md)
- [上位机开发区](host/README.md)
- [当前设计与开发计划](output/README.md)
- [Codex + PDS 开发方案](output/Codex_PDS_快速开发方案.md)
- [参考资料检索索引（仅本地）](reference/内容索引.md)
- [Git 版本管理指南](docs/版本管理指南.md)
- [本地资料与恢复说明](docs/本地资料说明.md)
- [变更记录](CHANGELOG.md)

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
