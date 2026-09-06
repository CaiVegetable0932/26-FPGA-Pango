# 26-FPGA-Pango

基于紫光同创 PG2L100H（盘古100Kmini）的图像畸变矫正项目。当前处于方案和工具链准备阶段，尚未建立正式 RTL 工程或完成硬件验证。

- [当前设计与开发计划](output/README.md)
- [Codex + PDS 开发方案](output/Codex_PDS_快速开发方案.md)
- [参考资料检索索引](reference/内容索引.md)
- [Git 版本管理指南](docs/版本管理指南.md)
- [本地资料与恢复说明](docs/本地资料说明.md)
- [变更记录](CHANGELOG.md)

## 仓库范围

Git 管理设计文档、资料索引，以及后续新增的 RTL、IP 依赖、约束、测试和构建脚本。`output/` 是设计文档目录，已纳入版本管理。

`PDS/` 安装资料和 `reference/` 下的原始厂商资料保留在本机，不进入 Git；首次克隆后需单独恢复这些资料。实际参与构建的厂商源码应连同依赖复制到 `rtl/`、`ip/` 等受控目录，并记录来源。

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

默认主分支为 `main`，功能使用短期分支。首次提交是文档与管理配置基线，不代表可运行的硬件版本。当前尚未配置远程仓库，连接和备份步骤见版本管理指南。
