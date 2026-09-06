# GitHub 云端备份

远程仓库：https://github.com/CaiVegetable0932/26-FPGA-Pango

本地远程名为 `origin`。备份覆盖已提交并推送的文档、源码、配置和标签；保存文件、Git 提交、推送到云端是三个不同步骤。工作区未提交的修改不会上传。

## VS Code 日常流程

1. 打开整个项目文件夹，在“源代码管理”中检查当前分支。
2. 开始工作前，工作区干净时通过“…”菜单执行拉取；本仓库设置为仅允许快进，分叉时会停下供人工处理。
3. 编辑并验证，在源代码管理中逐项查看差异、点击“+”暂存。
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
git config pull.ff only
git config push.default simple
git config fetch.prune true
git config core.longpaths true
git config core.quotepath false
```

## GitHub 登录

使用 Git Credential Manager 或 VS Code 的 GitHub 登录提示完成授权。凭据由本机凭据管理器保存，不写入仓库。认证失败时可在终端运行 `git credential-manager github login --username CaiVegetable0932 --force --browser` 重新登录，无需将密码或令牌发给他人。

## 不包含的内容

约 9.6 GiB 的 `PDS/` 和原始 `reference/` 资料、License、本地配置、编译缓存不在 GitHub 备份中。资料范围见[本地资料说明](本地资料说明.md)。请把它们单独备份到自己的网盘或外部磁盘；当前没有配置或上传这部分文件。

GitHub 分支保护和其他托管平台设置未配置。云端推送结果以 Git 实际返回值及远程提交号为准。
