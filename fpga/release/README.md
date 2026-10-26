# 位流发布区

2026-10-12 已生成并校验两套原生候选位流，见 [候选交付目录](candidates/20261012_220946/README.md)及[总体布线与位流记录](../reports/bitstream_candidates_20261012.md)。`candidates/` 保存离线候选，`manifest.json` 明确记录 `download_approved=false`；它们尚未通过板级验收。

历史主工程位流位于 `../build/pango_video_top/generate_bitstream/`，其对应来源、校验值、时序和边界见 [历史构建记录](../reports/pre_programming_build.md)。本轮应使用上方2026-10-12候选目录及其校验清单；主工程候选仍不代表完整摄像头、ISP、网络或几何算法已实现。

实板配置和接口时序确认、另行测试及验收后，再按仓库约定发布已批准的位流、源版本、配置、校验和与真实验证记录；候选文件存在不等同硬件放行。
