# `pango_video_top` PDS 工程

这是 PG2L100H / FBG676 / -6 的第一版 FPGA 视频工程入口。工程文件使用 PDS 原生 `.pds` 格式；可重建批处理入口为 [`../../scripts/build_video.tcl`](../../scripts/build_video.tcl)。

当前工程只集成了工具链与 IP 接口基线：顶层保留已核对的 MINI 时钟、复位、按键和 LED 管脚，实例化 PLL、异步 FIFO 和双口 RAM，用于确认 PDS 能读取生成的 IP 源码。DDR3 HMIC_S `.idf` 已加入工程 IP 清单，但暂不实例化，因为实际 MINI 的 DDR 颗粒、容量、管脚和控制器参数仍需按实物核对；不能把 100Pro/其他例程的 DDR 配置当作本板验证。

已复制到 `fpga/ip/` 的实例均来自本仓库 `reference/` 中、同为 PDS 2022.2-SP6.4 的生成目录，复制后没有修改厂商源码。原生重生成入口是 [`../../scripts/generate_video_ips.ps1`](../../scripts/generate_video_ips.ps1)，需要有效的 IP Compiler License；无 License 时保留的 `.idf` 与生成源码仍可供 PDS 读取，重生成命令会在对应 `generate.log` 中报告失败。

## PDS 操作

```powershell
# 从正式脚本建立新的 PDS 工作目录
& 'E:\PDS_Pangu\PDS_2022.2-SP6.4\bin\pds_shell.exe' `
  -file 'D:\XDU\concept\26-FPGA-Pango\fpga\scripts\build_video.tcl' `
  -work_dir 'D:\XDU\concept\26-FPGA-Pango\fpga\build\pango_video_top' `
  -project_name pango_video_top

# 直接打开/读取本目录的原生工程文件
& 'E:\PDS_Pangu\PDS_2022.2-SP6.4\bin\pds_shell.exe' `
  -project 'D:\XDU\concept\26-FPGA-Pango\fpga\project\pango_video_top\pango_video_top.pds' `
  -run compile
```

构建输出只能写入 `fpga/build/`。本工程不是视频功能或上板验收结论；完成 HDMI、RGMII、OV5640 DVP 和实物 DDR 参数核对后，再在保持本基线可复现的前提下接入相应模块。
