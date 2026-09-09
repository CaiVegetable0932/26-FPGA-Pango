# `pango_video_top` PDS 工程

这是 PG2L100H / FBG676 / -6 的第一版 FPGA 视频工程入口。`.pds` 由 PDS 2022.2-SP6.4 的 `tcl2prj` 原生生成，输入为本目录的 `pango_video_top.tcl`；生成入口为 [`../../scripts/create_video_project.tcl`](../../scripts/create_video_project.tcl)。独立批处理构建入口仍为 [`../../scripts/build_video.tcl`](../../scripts/build_video.tcl)，两个入口的器件、源文件、IP 和流程参数应保持一致。

不要手写省略 `_timespec` 的 `_file` 节点：本版本会在工程解析阶段报 `Flow-0130`。原生生成之后，脚本仅将默认的 `prj_impl_dir` 调整为 `../../build/pango_video_top`，保持约定目录。2026-09-09 已完成实际解析、Compile 及完整批处理流程；仍有 FIFO/RAM 的 `IPSpecCheck` 参数警告，不能作为 IP 参数正确性或硬件验收。详见 [`../../reports/pds_project_read_fix_20260909.md`](../../reports/pds_project_read_fix_20260909.md)。

当前工程只集成了工具链与 IP 接口基线：顶层保留已核对的 MINI 时钟、复位、按键和 LED 管脚，实例化 PLL、异步 FIFO 和双口 RAM，用于确认 PDS 能读取生成的 IP 源码。DDR3 HMIC_S `.idf` 已加入工程 IP 清单，但暂不实例化，因为实际 MINI 的 DDR 颗粒、容量、管脚和控制器参数仍需按实物核对；不能把 100Pro/其他例程的 DDR 配置当作本板验证。

已复制到 `fpga/ip/` 的实例均来自本仓库 `reference/` 中、同为 PDS 2022.2-SP6.4 的生成目录，复制后没有修改厂商源码。原生重生成入口是 [`../../scripts/generate_video_ips.ps1`](../../scripts/generate_video_ips.ps1)，需要有效的 IP Compiler License；无 License 时保留的 `.idf` 与生成源码仍可供 PDS 读取，重生成命令会在对应 `generate.log` 中报告失败。

## PDS 操作

```powershell
# 如需指定许可证，仅在当前 PowerShell 进程设置 PANGO_LICENSE_FILE。
# 不要把许可证文件提交进仓库。

# 原生重建 .pds；tcl2prj 记录流程配置，不执行综合或布局布线
New-Item -ItemType Directory -Force 'D:\XDU\concept\26-FPGA-Pango\fpga\build\project_generation' | Out-Null
& 'E:\PDS_Pangu\PDS_2022.2-SP6.4\bin\pds_shell.exe' `
  -file 'D:\XDU\concept\26-FPGA-Pango\fpga\scripts\create_video_project.tcl' `
  -work_dir 'D:\XDU\concept\26-FPGA-Pango\fpga\build\project_generation' `
  -project_name project_generator

# 从正式脚本建立新的 PDS 工作目录
& 'E:\PDS_Pangu\PDS_2022.2-SP6.4\bin\pds_shell.exe' `
  -file 'D:\XDU\concept\26-FPGA-Pango\fpga\scripts\build_video.tcl' `
  -work_dir 'D:\XDU\concept\26-FPGA-Pango\fpga\build\pango_video_top' `
  -project_name pango_video_top

# 从 .pds 验证到 Compile；省略 -run 可能执行整个流程，不能当作只读检查
& 'E:\PDS_Pangu\PDS_2022.2-SP6.4\bin\pds_shell.exe' `
  -project 'D:\XDU\concept\26-FPGA-Pango\fpga\project\pango_video_top\pango_video_top.pds' `
  -work_dir 'D:\XDU\concept\26-FPGA-Pango\fpga\build\pango_video_top' `
  -run compile
```

构建输出只能写入 `fpga/build/`。本工程不是视频功能或上板验收结论；完成 HDMI、RGMII、OV5640 DVP 和实物 DDR 参数核对后，再在保持本基线可复现的前提下接入相应模块。
