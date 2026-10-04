# 本地标定与 Linux 环境合并记录

日期：2026-10-02。合并基线 main `4fffb37f`，Linux/Jetson 来源 `931f2da6`，本地标定与手动鱼眼预览来源 `fca074eb`。

保留两端实现：Jetson 项目 Python/Chromium 环境、Windows 启动器、标定数据与候选拟合、可编辑鱼眼软件参考预览及用户审校预设。Linux 启动器优先使用显式解释器及准备好的项目环境；OpenCV/NumPy 清单共享，旧 Jetson 环境的标定安装器复用该环境。没有修改系统设置、FPGA 位流或官方参考目录。

用户要求推送后退出、不再测试。该要求前已启动的 Windows 软件回归运行 88 项，全部通过，见 [Windows 记录](windows-python.json)。已启动的 WSL Ubuntu 22.04 x86_64 回归运行 88 项，有 2 项 HTTP 超时错误，见 [Linux 记录](linux-python.json)；未重跑、未确认超时原因，不宣称 Linux 全部通过。ARM64 标定依赖轮子已下载可用，但未在本机执行 ARM64 测试。`931f2da6` 原 Jetson 验证记录仍单独保留，不作为本次合并版的实板验收。

后续由用户在 Linux 端独立复核。运行时、虚拟环境、下载包、实测图像/视频和标定样本均未提交。当前已开启的本地网页预览不重启、不接管。

## 已有 Jetson 环境更新

在仓库根目录执行：

```bash
git pull --ff-only origin main
source host/scripts/env.sh
python host/scripts/setup_calibration.py
sh host/scripts/start_web.sh
```

运行源码升级前正常停止旧服务，再按以上流程启动新版本；页面入口 `/calibration#manual-preview`。预览明确标记为 PC 软件参考，参数不是实测标定结果，不自动下发 FPGA。
