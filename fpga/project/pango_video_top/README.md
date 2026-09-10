# 原生 PDS 工程

入口：`pango_video_top.pds`。用 PDS 2022.2-SP6.4 直接打开；所有设计源及 IP 依赖均位于 `fpga/`。

`pango_video_top.tcl` 是 PDS `tcl2prj -tcl` 的原生输入。PDS 自己生成 `_timespec`、IP source-item、任务参数与全部语法。`create_project.tcl` 只调用原生转换；待 PDS 进程退出、释放文件后，再由 `finalize_project.py` 仅纠正实现目录选项，不修改文件/IP 语法。不能把另一版本的 `.pds` 片段拼接进来。

PDS 命令行在保存项目时也会把实现目录写回 `.`；构建脚本结束后由 `finalize_project.py` 再次仅校正此目录选项。`audit_project.py` 检查依赖闭合、15 个 IP 的目标与实例、板级引脚、DDR/HDMI 六条优先布线命令、实际时钟周期/来源/占空比、各阶段新鲜产物、快慢角八项时序汇总和错误日志；PDS 返回码为零本身不代表构建通过。

该版本连续添加两个 RCF 会只保留后一个。主工程因此只加载 `constraints/routing.rcf`，由脚本把原生 DDR RCF 与自有 HDMI 复位 RCF 的命令原样合并；原始两份输入不被改写。

重新构建使用 `fpga/scripts/build.ps1`。完整流程：原生 IP 生成 → 原生工程生成 → **直接读取 `.pds`** → Compile → ADS Synthesize → Device Map → Place & Route → Timing → Simulation Netlist → Bitstream → Power Report。

生成仿真网表不等于运行仿真；成功生成位流不等于经过板级验证。本工程目前是 IP 集成底座，不是完整视频应用。
