"""Persist the hourly update without changing historical evidence manifests."""
from pathlib import Path
root = Path(__file__).resolve().parents[4]
p = root/'fpga/reports/route_optimization_progress_20261019.md'
text = p.read_text(encoding='utf-8') + '''
### 2026-10-20 01:48：每小时汇报
- 主设计仍为已通过 20 项回归、完整 1080p 控制/同帧快照/实际显示模型及主机解码的 12 项选定修改；整个方案未完成，整体布线与位流未运行。
- unpack 实际 reader 的三 seed 内部时序均通过，PnR 中位 44→38 秒；不能推断整机收益。
- 第三轮 DMA B 布通但时序失败，已拒绝归档；第四轮统计单变量功能差分与参数覆盖通过，隔离综合进行中，尚未合入。
- 已推送至 codex/fpga-pds-project，文档提交 22abfc27；最近账户额度剩余 39%，10% 停止线持续监控。下一次汇报约 02:48。
'''
tmp = p.with_suffix('.hourly.tmp')
tmp.write_text(text, encoding='utf-8', newline='\n')
tmp.replace(p)
