"""Refresh the live handoff after round-3 rejection; preserve frozen proofs."""
from pathlib import Path

root = Path(__file__).resolve().parents[4]
note = '''### 2026-10-20 01:43：DMA 第三轮终结与第四轮范围
- B（局部游标与统计比较）区域布线已收敛，输入和固定引脚一致；建立余量 −0.482 ns、保持余量 −0.029 ns，拒绝合入。关键路径经过 client_cursor、mask 与 useful_write_bytes。无合格同预算参考，不报告加速比。
- 第四轮仅尝试统计比较局部化，保留主设计原始游标和 RAM；10 组逐周期差分及 12 组参数覆盖通过，隔离综合进行中，候选未合入。
- HEAD 中 290 项 FPGA 输入与完整仿真快照一致，远端 HEAD 已核对。最近账户额度剩余 39%。整体布线与位流仍关闭。
'''
for name in ['route_optimization_progress_20261019.md', 'route_optimization_handoff_20261020.md']:
    path = root/'fpga/reports'/name
    text = path.read_text(encoding='utf-8').split('### 2026-10-20 01:38')[0].split('### 2026-10-20 01:43')[0].rstrip()+'\n\n'+note
    if name.startswith('route_optimization_handoff'):
        start = text.index('当前唯一 PDS 为 B：')
        end = text.index('\n\n第一份 writer', start)
        text = text[:start] + '''当前唯一 PDS 为第四轮统计候选的隔离综合：`dma_stats_only_20261020_013741_777089/owner_unit_probe_20261020_013831_335662`。第三轮 B 的终结记录见 `session_20261019/dma_round3_terminal_review_20261020.json`，原生检查点位于其区域 case 的 `native_checkpoints.zip`。新分阶段预算每侧准备/PnR/STA 上界为 20/20/2 分钟，旧模式结果保持原预算；不得混算加速比或并发运行重型 PDS。''' + text[end:]
        text = text.replace('1. 完成第三轮 DMA 的固定引脚局部物理筛选，保持同一 seed/时钟/工具策略。', '1. 第三轮 DMA 已终结且未合入；完成第四轮统计比较候选的综合前筛，必要时做固定引脚区域验证，保持同一 seed/时钟/工具策略。')
        text = text.replace('目前只是静态审查，没有启动第四轮候选。', '这些热点目前只是静态审查；第四轮候选针对 DMA 统计，不涉及 pool 或 snapshot-copy。')
        text = text.replace('00:38 最近 Codex 账户额度剩余 40%', '01:36 最近 Codex 账户额度剩余 39%')
        text = text.replace('区域物理每侧总上限 20 分钟，包含新鲜 compile/SYN/MAP/PnR/STA。', '区域物理默认每侧完整流程上限 20 分钟；显式 --phase-budgets 模式分别限制准备/PnR/STA 为 20/20/2 分钟，记录模式，不混算样本。')
    temporary = path.with_suffix('.refresh.tmp')
    temporary.write_text(text, encoding='utf-8', newline='\n')
    temporary.replace(path)
