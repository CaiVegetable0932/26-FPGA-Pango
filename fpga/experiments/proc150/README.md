# 150MHz处理域实验与生产接入

最终tile边界结构已在2026-10-20 05:25选择进入生产RTL（累计15项）；本目录仍是历史实验来源，不被构建器直接收集。生产入口为`rtl/geometry/geometry_processing_domain_external_refill.sv`与`config/integration/processing_domain.json`。完整1080p、主机原始快照一致性、最终主目录回归和板级MAP/CDC结构审查通过；整体布线、物理STA及硬件签核留待用户另派智能体。

低层burst读CDC两结构因超服务预算拒绝；帧池候选均未合入。早期失败/超时记录不改标PASS。源码与完整证明路径见[最终交接](../../reports/route_optimization_handoff_20261020.md)。
