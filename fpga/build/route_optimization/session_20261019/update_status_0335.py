"""Refresh mutable status documents without changing frozen evidence."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4]
reports=ROOT/'fpga/reports'
status='''
## 2026-10-20 03:35 当前状态

整个方案尚未完成；主设计仍为已经过完整功能验证的 12 项修改，没有合入以下实验。账户额度最近读数剩余 37%，10% 停止机制继续运行。整体 PnR / 位流门槛保持关闭。区域时钟统一 8 ns，不能据此宣称 150 MHz 或板级签核。

| 区域方案 | 最新证据与决策 |
| --- | --- |
| 帧池 slot-local flags | seed11 两侧完成；setup −0.450→−0.687 ns，候选时序失败，不合入，终止该候选 |
| snapshot-copy local capture | 两侧时序通过；PnR 37→38 秒、线长 10539→11165，无布线收益，保留原设计 |
| writer 完整 signed 乘积 A | 413798 次算术检查、31 组差分、20 项回归通过；APM 6→3，setup −7.796→−1.649 ns，仍失败，不单独合入 |
| 帧池 16 位分块完整 64 位计数器 | 11 组差分含 16/32/48 位进位与 64 位耗尽、20 项回归通过；256 个计数 FF 从 CE 改为连续更新，控制集 25→21。区域 slow setup +0.166 ns，但 fast hold −0.001 ns；不合入、不忽略违例。正在仅改变 decongestion 1→2 复核，RTL/引脚/seed11/8ns不变 |
| writer 两拍入口流水 B | 50 组独立字节记分板/范围/取消/延迟测试及20项集成回归通过。每帧入口多2拍，分段多0拍；不是逐周期等价。seed11 区域全角时序通过，slow setup +2.726 / slow hold +0.163 / fast hold +0.116 ns，线长22112。完整1080p控制/快照/显示模型正在运行，未合入；尚需有限seed7/13稳定性验证 |
| 独立150 MHz处理域 write CDC 原型 | 位于 `fpga/experiments/proc150/`，未实例化到生产工程。四组异步时钟/相位测试全部通过，每组32场景，覆盖数据/掩码、背压、取消、错误、复位。未做原生映射、CDC静态检查或整机吞吐验收，不能当作150MHz目标已实现 |

主要路径均相对于项目根目录：

- `fpga/build/route_optimization/session_20261019/control_writer_terminal_review_0323.json`：前三项物理终结结果。
- `fpga/build/route_optimization/pool_chunk16_20261020_025740_906990`：计数器候选及证明；screen `pool_unit_screen_20261020_030600_250387`。
- `fpga/build/route_optimization/writer_span_pipeline_20261020_031048_641108`：两拍 writer 候选290项输入、原始备份及语义证明。
- `fpga/build/route_optimization/writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_032713_550985`：writer B seed11物理结果。A参考输入、wrapper、引脚/时钟一致性见 screen 的 `physical_reference_reuse_20261020.json`；参考时序失败，不计算加速比。
- `fpga/build/full_integration_20261013/verilator_20261020_033308_185785`：writer B完整帧模型，03:35仍在运行，不计PASS。
- `fpga/build/route_optimization/proc150_write_cdc_20261020_031859_818696`：CDC原型独立测试。

续接先核对 quota / native_phase.lock / 活动进程，严格单个 PDS。当前唯一PDS是帧池 decongestion=2区域候选，writer完整帧模型可并行。计数器若通过，才做有限稳定性复验；writer也须完整帧和主机原始字节验证后才可单文件合入。已冻结ZIP/manifest不能覆盖；新检查点 `checkpoint_0335_manifest.json` 只归档已终结运行，活动任务排除。

处理域150MHz尚缺job CDC、联合复位/PLL接入、约束、全帧服务期限和资源验收，按原方案继续设计；生产DDR PHY和125MHz真实时钟保持原配置。不能以孤立桥接器通过代替整机设计完成。完成设计/仿真后通知用户，由用户安排其他智能体监控整体布线。
'''
handoff=reports/'route_optimization_handoff_20261020.md'
text=handoff.read_text(encoding='utf-8')
start=text.index('## 当前实验与唯一活动 PDS')
end=text.index('## 续接顺序',start)
text=text[:start]+status+'\n'+text[end:]
text=text.replace('更新时间：2026-10-20 02:40','更新时间：2026-10-20 03:35')
handoff.write_text(text,encoding='utf-8',newline='\n')
for name in ['route_optimization_progress_20261019.md','regional_verification_plan_20261019.md','control_locality_review_20261020.md']:
    p=reports/name
    with p.open('a',encoding='utf-8',newline='\n') as f:f.write('\n'+status)
print('STATUS_REFRESHED')
