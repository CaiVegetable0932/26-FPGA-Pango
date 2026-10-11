# GitHub 云端备份

远程仓库：https://github.com/CaiVegetable0932/26-FPGA-Pango

本地远程名为 `origin`。备份覆盖已提交并推送的文档、源码、配置和标签；保存文件、Git 提交、推送到云端是三个不同步骤。工作区未提交的修改不会上传。

## 每轮工作的同步要求

依据 [项目工作约定](../AGENTS.md)，每次开始修改前必须获取云端最新状态，并在已纳入当前对应远程分支最新提交的版本上工作。新分支尚未发布时，先核对来源分支（通常为 origin/main）。

完成本轮改动后，助手必须在最终回答前检查、提交、推送当前分支，并核对远程提交号与本地 HEAD 一致；首次推送建立跟踪关系。推送前再次获取远程状态，冲突通过保留双方工作并合并解决，不能强制覆盖。失败时明确说明尚未推送成功及原因。

其他任务原有的未提交文件保持原状，本轮改动单独提交。现有备份脚本要求整个工作区干净；若有明确无关的遗留文件，可只暂存本轮文件后直接执行 Git 推送，并通过远程提交号完成同等校验，不为运行脚本擅自提交或清除遗留文件。

这是助手的持续工作规则；VS Code 不会因保存文件自动提交或推送，手动流程仍按下面步骤执行。

## VS Code 日常流程

1. 打开整个项目文件夹，在“源代码管理”中检查当前分支。
2. 开始工作前，工作区干净时通过“…”菜单执行拉取；本仓库设置为仅允许快进，分叉时会停下供人工处理。
3. 编辑并验证，在源代码管理中逐项查看差异；需要备份全部改动时，选择“暂存所有更改”。根目录 reference 和 PDS 内的文件不会进入暂存。
4. 输入清晰的提交说明并提交。
5. 从“…”菜单执行推送；新分支使用发布分支。推送后检查 Git 输出没有错误，并在 GitHub 查看对应分支的最新提交。

“同步更改”可能同时拉取和推送；初学阶段建议分别执行。此配置不会定时上传，也不会自动提交正在编辑的内容。

## 一条命令备份当前分支和版本标签

提交完成后，在项目终端执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/backup.ps1
```

脚本检查工作区干净、远程推送地址正确，获取远程状态后以原子操作推送当前分支和可达的注释标签，再核对本地与云端提交号。失败会停止，不自动合并、不强制覆盖。它不推送其他分支，也不推送轻量标签；重要版本请使用 `git tag -a`。

推送被拒绝时，先获取并检查双方提交，再解决分叉。不要使用强制推送覆盖云端。若有其他需要备份的开发分支，分别切换到它们并运行脚本。

## 换电脑恢复

```powershell
git clone https://github.com/CaiVegetable0932/26-FPGA-Pango.git
```

用 VS Code 打开克隆后的目录。若需要编辑远程开发分支，从分支列表选择对应分支。安装 PDS、ModelSim，恢复外部资料并配置本机工具路径和 License。克隆不会复制旧电脑的本地 Git 配置，可在新仓库设置：

```powershell
git config --local user.name hagima410
git config --local user.email 2849996579@qq.com
git config --local user.useConfigOnly true
git config --local credential.https://github.com.username hagima410
git config pull.ff only
git config push.default simple
git config fetch.prune true
git config core.longpaths true
git config core.quotepath false
```

## 固定身份与 GitHub 登录

本项目提交作者与提交者均固定为 `hagima410 <2849996579@qq.com>`；推送使用已授权协作者 `hagima410` 登录账户。身份以 [项目工作约定](../AGENTS.md) 中 2026-09-25 更新的规则为准，远程仓库所有者仍为 `CaiVegetable0932`。提交前用 `git var GIT_AUTHOR_IDENT` 和 `git var GIT_COMMITTER_IDENT` 核对实际身份，提交后通过 `git log -1 --format=fuller` 复核。Git 配置不会替代 GitHub 登录。

使用 Git Credential Manager 或 VS Code 的 GitHub 登录提示完成授权。凭据由本机凭据管理器保存，不写入仓库。认证失败时可在终端运行 `git credential-manager github login --username hagima410 --force --browser` 重新登录，无需将密码或令牌发给他人。

## 不包含的内容

根目录 `PDS/` 和整个 `reference/` 被排除，合计约 9.6 GiB。其他目录及根目录文件默认纳入，包括隐藏文件、本地配置和构建结果。2026-10-11 用户另行授权忽略 MCU 临时 PDF 阅读工具、重复临时测试程序和失败下载页面，精确路径见根目录 `.gitignore`；正式构建产物和迁移归档继续提交。`reference/内容索引.md` 已停止跟踪但保留本地文件，旧提交中的历史不变。资料范围见[本地资料说明](本地资料说明.md)。请把它们单独备份到自己的网盘或外部磁盘；当前没有配置或上传这部分文件。

GitHub 分支保护和其他托管平台设置未配置。云端推送结果以 Git 实际返回值及远程提交号为准。

## 当前设计文档的备份范围

[RAW8千兆网＋HDMI回传方案](../output/OV5640_RAW8千兆网与HDMI双路回传方案.md)、主设计、上位机与测评规划、开发区说明均属于受版本管理的项目文档，更新后先进行链接、格式和跨文档参数一致性检查，再提交并运行上面的备份脚本。

文档同步不包含新的硬件验收结论。只有脚本最终给出Cloud backup verified且本地HEAD与远程分支相同，才报告该次云端备份完成；本页不预先写入尚未执行的推送成功记录。
