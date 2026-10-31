# 此交付分支的工作约定

用户授权另一台电脑使用旧gray_optimized一次有界PLC布线及监控。先读README及fpga/reports/异机布线监控交接_灰度较好版_20261031.md。

唯一设计输入为fpga/release/gray_optimized_20261030/inputs。不能与开发分支或新候选混用。只用portable_gray.py进行audit、prepare、run；不手动重开旧scope，不直接运行flow.tcl里的综合命令。原生180分钟、主机185分钟；PnR成功后min/max STA；禁止位流/下载。只读原PDS官方doc，任何输出放fpga/build。

input/source/config/implementation_readiness.json和evidence中的授权只属旧冻结记录。当前机器的scope必须由prepare重新创建，不能复用旧路径或旧一次性scope。正常监控静默，有意义变化/失败/终结再汇报。不要删除任何既有工程或锁。
