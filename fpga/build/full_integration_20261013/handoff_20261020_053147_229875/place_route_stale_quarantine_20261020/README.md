# place_route 残留产物隔离区（2026-10-20 14:35）

为验证 seed 7 重试而隔离的原生状态文件；内容均已在第 1 轮归档
native_place_route_timeout.zip（31 成员，逐成员 SHA manifest）或本机失败轮证据目录中保留。

- pango_video_system_plc.adf : 第 1 轮 seed 11 布局数据库（13:08），与本轮 seed 7 不匹配，不可用于 --from-placement
- prr.db / pango_video_system.prr : 第 2 轮失败运行（14:24）遗留，失败日志见 resume_20261020_142155_652622

若 clean 重试仍以 Place-0006 失败，将按 seed 相关问题重新诊断。

--- 追加（14:45）---
clean 目录 seed 7 重试（2b，resume_20261020_143304_667663）仍以同一 Place-0006 OSERDES 错误在 150s FAILED，
证明 seed 7 确定性失败于布局（2/2），与残留产物无关。seed7_failed_2b_20261020/ 为该次失败的原生小文件；
CongestionNetInfo/CongestionPlot/layers/logbackup 为第 1 轮遗留（已归档于第 1 轮 ZIP）。
随后切回 seed 11（第 1 轮证明可完成布局）并以 1.5h 预算重启。
