# PDS 工程解析错误修复与验证

日期：2026-09-09。工具：PDS 2022.2-SP6.4 build 146967。

## 原因

此前手写的 `fpga/project/pango_video_top/pango_video_top.pds` 在第 22 行的 `_file` 节点中只写了 `_format`，遗漏当前版本要求的 `_timespec`。PDS 在闭合文件节点时发现结构不完整，报 `Flow-0130`，随后以 `Flow-0121` 报告整个工程解析失败。这发生在 RTL 编译之前，与此前许可证路径失效是两个独立问题。

最小对照均由 PDS 实际解析，证据保存在 `fpga/build/pds_read_fix_20260909/`：

| 输入 | 结果 |
| --- | --- |
| `original.pds` | 复现第 22 行、第 91–92 列错误 |
| `line22_newlines.pds`，仅把节点分行 | 仍然失败，错误位置随换行移动 |
| `line22_timespec.pds`，仅补第一个文件的时间戳 | 第一个节点通过，错误移至第 23 行的第二个文件 |
| 原生重建后的正式工程 | 解析通过，进入 Compile |

`probe_syntax.ps1` 使用保留的旧工程作为故障样本。样本中的时间戳只是隔离实验值；正式工程的时间戳由 PDS 按真实文件生成。

## 修复

- 使用 PDS 内置 `tcl2prj` 从 `fpga/project/pango_video_top/pango_video_top.tcl` 生成正式 `.pds`，补齐文件、IP、IP 源文件元数据以及 DDR 源文件清单。
- 增加 `fpga/scripts/create_video_project.tcl` 作为可重复生成入口。此版本转换器要求综合等流程命令直接出现在待转换文件中，不能仅用 `source` 隐藏全部流程命令。
- 转换器会将 `prj_impl_dir` 留为 `.`；生成入口只对这个目录配置作确定性调整，使 GUI 工程记录的实现目录指向 `fpga/build/pango_video_top`。命令行验证仍显式指定 `-work_dir`，因为命令行的输出目录选择会覆盖项目设置。
- 未修改 RTL 或 IP 参数。用户提供的许可证仅设置到验证子进程的环境变量，没有修改系统/用户环境变量，也没有纳入 Git。

## 实际验证及边界

- `generation.log`：原生工程转换完成，无 `E:` 错误。
- `native_read.log`：直接加载重建工程成功；此次 `-project` 未指定 `-run`，PDS 默认运行了完整流程，Compile、Synthesize、Device Map、Place & Route、Report Timing、Report Power、Generate Netlist、Generate Bitstream 均有完成记录。位流位于同目录的 `generate_bitstream/pango_video_top.sbit`。
- `final_compile.log`：使用加入输出目录设置后的最终工程同层副本，显式限定 `-run compile`，再次解析并完成 Compile。正式 `.pds` 保持原生生成的初始状态。
- 保留所有实际生成的编译、综合、布局布线、时序和位流证据。原生转换期间落在工程目录的约束检查结果移至本次 `fpga/build/` 证据目录。
- 工程仍是 PLL/FIFO/RAM 集成检查，DDR 仅加入工程清单，未实例化。日志包含 FIFO/RAM 的 `IPSpecCheck` 参数警告：18K DRM 的 `c_WR_ADDR_WIDTH` 范围要求为 9–20；这些警告尚未修复。也有异步输入/输出约束警告；本次不作时序签核、视频链路通过、功耗实测或硬件验收结论。

对照依据：只读查阅本机官方 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Pango_Design_Suite_User_Guide.pdf` 第 2.2、2.6 节；命令签名取自本机 `pds_shell -help`、`tcl2prj -help`、`save_project -help`。同时核对 `reference/盘古100K200K MINI开发板/` 下同版本工具生成的工程节点结构，器件配置仍采用本项目 PG2L100H / FBG676 / -6，未采用参考中 PG2L200H 的器件参数。
