"""Audit a completed control-pipeline experiment and optionally adopt its RTL."""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
from constraint_report import require_native_constraints
from implementation_readiness import require_mapped_lut_budget
from package_block_pressure_handoff import synthesis


def sha(p):
    """Record exact inputs, results and rollback bytes."""
    return hashlib.sha256(p.read_bytes()).hexdigest()


def read(p):
    """Read Python and PowerShell evidence with optional UTF-8 BOM."""
    return json.loads(p.read_text(encoding='utf-8-sig'))


def render_report(fpga, run, result, proof, full, old_map):
    """Write a routing handoff that distinguishes measured SYN/MAP from PnR."""
    before=result['before']; after=result['after']; mapped=result['mapped']
    candidate=Path(result['candidate']); mapping=Path(result['mapping'])
    selected=result['production_selected']; target=mapping
    gate=read(fpga/'config/implementation_readiness.json')
    link=lambda p:'['+p.name+']('+p.resolve().as_posix()+')'
    rows=[('MAP LUT',result['prior_mapped']['total_lut'],mapped['total_lut']),
          ('SYN LUT',before['lut'],after['lut']),('SYN FF',before['ff'],after['ff']),
          ('异步复位 FF',before['asynchronous_reset_ff'],after['asynchronous_reset_ff']),
          ('控制集',before['control_sets'],after['control_sets']),
          ('DDR 域综合 setup WNS / ns',before['ddr_domain_setup_wns_ns'],after['ddr_domain_setup_wns_ns']),
          ('DDR 域综合 setup TNS / ns',before['ddr_domain_setup_tns_ns'],after['ddr_domain_setup_tns_ns'])]
    table='\n'.join('| '+name+' | '+str(old)+' | '+str(new)+' |' for name,old,new in rows)
    artifact_table='\n'.join('| `'+n+'` | `'+h+'` |' for n,h in result['artifacts'].items())
    failures=[n for n,v in result['checks'].items() if not v]
    old_route=old_map/'resume_20261025_181607_149012'
    physical=result.get('physical')
    decongestion=physical['candidate']['options']['placement_decongestion'] if physical else 1
    physical_mode=physical['candidate']['options']['mode'] if physical else 'normal'
    next_target=target;next_decongestion=decongestion;next_mode=physical_mode
    if not selected and physical and physical.get('policy_study') and not physical['policy_study']['recommend_adoption']:
        # A rejected policy must not silently become the next default. Keep
        # the last function-proven normal/expansion-1 candidate as the
        # experimental starting point while production RTL stays unchanged.
        prior_policy=physical['policy_study']['baseline']
        next_target=Path(prior_policy['folder']).parent
        next_decongestion=prior_policy['options']['placement_decongestion']
        next_mode=prior_policy['options']['mode']
    diagnostic_note=''
    if result.get('placement_diagnostic'):
        diagnostic_note='\n布局数据库诊断：'+link(Path(result['placement_diagnostic_path']))+'。两份 PLC 报告各有 2,794 条数据路径，其中 2,670 条数据连线延迟为 0；DDR setup 示例亦为 0。该接口不能还原 placer 的最差裕量，不能据此宣称时序通过或认定具体最差逻辑路径。\n'
    if physical:
        p=physical['candidate']; b=physical['baseline']
        # Same-budget progress includes placement speed. Matched router
        # iterations below separately expose convergence within routing.
        old_rounds={r['iteration']:r for r in b['rounds']}
        round_table='\n'.join('| '+str(r['iteration'])+' | '+str(old_rounds[r['iteration']]['unrouted'])+' | '+str(r['unrouted'])+' | '+str(old_rounds[r['iteration']]['cpu_seconds'])+' | '+str(r['cpu_seconds'])+' |' for r in p['rounds'] if r['iteration'] in old_rounds)
        physical_summary=f"本轮已运行有界 PnR，状态 {p['status']}。详细布线完成：{p['routing_completed']}；物理时序通过：{p['physical_timing_met']}。"
        comparison_note='同一布局参数下的 RTL 对照' if physical.get('experiment')!='combined_RTL_and_policy_vs_original' else '原正式基线与 RTL＋布局策略组合对照；独立同 MAP 试验另列'
        physical_table=f'''\n本轮物理对照（{comparison_note}，30 分钟窗口）：

| 指标 | 原基线 | 本轮候选 |
|---|---:|---:|
| 全局布局线长 | {b['wirelength'].get('global placement')} | {p['wirelength'].get('global placement')} |
| 合法化后线长 | {b['wirelength'].get('legalization')} | {p['wirelength'].get('legalization')} |
| 详细布局线长 | {b['wirelength'].get('detailed placement')} | {p['wirelength'].get('detailed placement')} |
| 发生复制的源数 | {b['replication_origins']} | {p['replication_origins']} |
| boot 下发生复制的源数 | {b['replication_by_group'].get('boot',0)} | {p['replication_by_group'].get('boot',0)} |
| 复制实例数 | {b['replicated_instances']} | {p['replicated_instances']} |
| 窗口内实际采样时间 / s | {round(b['window_sample_seconds'],3) if b['window_sample_seconds'] is not None else '无采样'} | {round(p['window_sample_seconds'],3) if p['window_sample_seconds'] is not None else '无采样'} |
| 窗口内最少未布通连接 | {b['window_best_unrouted']} | {p['window_best_unrouted']} |
| 总子网数 | {b['total_subnets']} | {p['total_subnets']} |
| 布局 worst slack（原生日志单位） | {b['placement_slack_raw']} | {p['placement_slack_raw']} |
| 布局 TNS（原生日志单位） | {b['placement_tns_raw']} | {p['placement_tns_raw']} |

对照证据：{link(Path(result['physical_feedback_path']))}。推荐采用：{physical['recommend_adoption']}。
分项判定：同预算收敛改善={physical['convergence_better']}；详细布局线长不增加={physical['wirelength_not_worse']}；布局最差裕量不退步={physical['placement_timing_not_worse']}。本轮采用规则同时检查这些维度；任何一项未满足时保留试验候选，不能用面积下降或局部提速代替完整采用条件。
周期监控存在采样间隔，上表给出实际采样时间；不把 90 分钟基线的最终值与 30 分钟候选直接比较。部分布线的收敛改善不是最终布通或时序签核。

同编号详细布线迭代对照（原基线对应迭代可能发生在 30 分钟之后；此表用于区分布局提速与路由迭代自身变化，不是同预算结果）：

| 迭代 | 原未布通 | 新未布通 | 原迭代 CPU 秒 | 新迭代 CPU 秒 |
|---|---:|---:|---:|---:|
{round_table or '| 尚无共同完成迭代 | — | — | — | — |'}
'''
        if physical.get('policy_study'):
            previous=physical['policy_study']['baseline']
            previous_label=f"{previous['options']['mode']}，扩展 {previous['options']['placement_decongestion']}"
            current_label=f"{p['options']['mode']}，扩展 {p['options']['placement_decongestion']}"
            physical_table+=f'''\n独立同 MAP 对照：源码、MAP 数据库、PCF 哈希一致；只改变本次声明的策略参数，其余 seed/时钟/约束保持不变。沿用原先的功能测试证据，没有宣称重新综合或重新运行仿真。

| 指标 | 上轮候选：{previous_label} | 本轮：{current_label} |
|---|---:|---:|
| 详细布局线长 | {previous['wirelength'].get('detailed placement')} | {p['wirelength'].get('detailed placement')} |
| 窗口内未布通连接 | {previous['window_best_unrouted']} | {p['window_best_unrouted']} |
| 布局 worst slack（原生日志单位） | {previous['placement_slack_raw']} | {p['placement_slack_raw']} |
| 布局 TNS（原生日志单位） | {previous['placement_tns_raw']} | {p['placement_tns_raw']} |

试验证据：{link(Path(physical['policy_study_path']))}。这张表隔离布局策略效果，上方与原正式基线的表反映 RTL 与策略的组合效果。
该策略是否优于上轮实验候选：{physical['policy_study']['recommend_adoption']}。实验策略进步与正式 RTL 采用是两项判定，后者仍须满足原正式基线的综合比较条件。
详细布局校验值与上轮候选一致：{physical.get('same_detailed_placement_checksum','未检查')}。小幅耗时变化仅是本次观测，不据单次运行断言稳定加速。
'''
        if physical.get('previous_policy_studies'):
            physical_table+='\n本轮此前完成但未选用的试验：\n\n| 模式 / 扩展系数 | 详细布局线长 | 布局 worst slack | 30 分钟窗口未布通 | 证据 |\n|---|---:|---:|---:|---|\n'
            for trial in physical['previous_policy_studies']:
                t=trial['result']['candidate']
                physical_table+=f"| {t['options']['mode']} / {t['options']['placement_decongestion']} | {t['wirelength'].get('detailed placement')} | {t['placement_slack_raw']} | {t['window_best_unrouted']} | {link(Path(trial['path']))} |\n"
    else:
        physical_summary='本轮尚未运行 PnR；当前只有软件验证和 SYN/MAP。'
        physical_table=''
    text=f'''# 配置校验流水优化与布线交接

生成时间：{datetime.now().astimezone().isoformat()}。

## 结论与适用范围

本轮完成保留功能的配置路径优化。{'已采用到工作区 RTL。' if selected else '尚未采用到工作区 RTL；保留原基线。'}
不能据此断言设计已无法继续优化。后续状态读口局部化、控制集和互连布局仍有研究空间，下一步应根据新候选的拥塞位置与实际时序决定取舍。
{physical_summary} 本轮没有实板验证。是否改善布线，以物理对照为准，不按 LUT 数量评分。

| 指标 | 原基线 | 本轮候选 |
|---|---:|---:|
{table}

本轮 MAP 利用率为 {mapped['utilization_percent']:.6f}%；严格低于 70% 的门槛是 LUT < 46,620。
60% 为此前面积目标，本轮不以达到该目标决定采用；允许用额外寄存器改善互连和布线。LUTRAM 不另加到总 LUT。
SYN WNS/TNS 使用综合估算连线，不能替代布线后时序。输入、功能证据与运行条件审查 {sum(result['checks'].values())}/{len(result['checks'])}；失败项：{failures or '无'}。这些检查通过不代表候选获准采用，采用结论见下方物理对照。

## 改动及必须保留的约束

1. `pc_video_boot` 增加原始提交尝试输出，保留原 accepted-only 输出和 UART 返回码。板级 camera、MCU、motion 各用自身返回码决定接收；image 在 core 内分别用 colour/tone 返回码确认。
2. 共享返回码选择器仅供 UART 应答，不再绕回多个模块的寄存器使能。对任意被选中的 kind，原条件 `attempt && selected && selected_code==0` 与局部条件 `attempt && selected && own_code==0` 等价。BUSY、错误和内部等待码均不能提交。
3. tone 静态 body 合法性提前一拍，版本、generation、页占用、pending 和 uploaded_version 等可变状态仍在实际提交边沿检查。
4. 上传器 COMMIT 前增加 SETTLE 状态，保持 body/header 不变；125 MHz 下新增一拍为 8 ns。等待、CRC、事务重试、应答格式和帧原子发布规则保留。临近帧边界时，以实际接收边沿决定何时排队，不能假定旧版的逐拍 UART 响应延迟。
5. `REGISTER_BODY_CHECK` / `TONE_REGISTER_BODY_CHECK` 只能与保证 body 提前稳定的入口配套使用；板级已与 `COMMIT_SETTLE(1)` 成对启用。`QUALIFY_IMAGE_LOCALLY(1)` 的板级入口接 raw attempt。通用模块默认参数保持兼容。
6. motion 静态 schema 合法性同样提前一拍，kind/body 必须提前稳定，版本与 pending 继续现场检查。姿态匹配阶段先登记槽号，再读标定并计算角度；接收前重新核对该槽 epoch/frame，防止槽位复用后借用新帧标定。
7. 姿态模型请求增加一拍，原有 65,535 周期等待上限和手动矩阵回退保留。该变化不是所有 MCU 极限到达时刻的逐拍等价承诺；已用槽位复用、复位、正常姿态和超时场景验证所有权与回退。

保留 RAW8 千兆网、唯一 HDMI、基础 ISP、手动曝光/色彩/曲线、几何矫正和 MCU 姿态接口。像素算法、DDR 仲裁、缓存容量、时钟、引脚和时序例外未更改。没有以删除功能或放宽时钟获得对照结果。

## 验证证据

- 协议/控制：{link(proof/'result.json')}，13 项通过，包括默认接口、CRC/重试、相机等待与超时、MCU 配置、冻结分页与复位边界、三条内置曲线、motion 校验分拍和姿态所有权。
- 局部接收与旧接收脉冲在 UART fixture 中逐周期核对；tone 新旧实现比较 1,116 个周期。motion 局部接收由保持不变的互斥 kind 选择和 own-code 等价变换保证，未声称新增完整板级 UART 联仿。
- motion 配置随机比较 11,938 次，接收 1,198 次、发布 1,173 次；姿态专项 70 项检查覆盖被匹配槽重用、等待中复位及原超时回退。复位期间 registered legality 为 false，不把复位禁止接收期间的组合返回码差异误判成事务差异。
- 完整帧：{link(full/'result.json')}、{link(full/'run.log')}。三帧 geometry_cycles 为 {result['cycles']}，与原基线一致；最慢 {max(result['cycles'])/125000:.6f} ms（125 MHz 仿真计数域）。
- HDMI 校验 8,294,400 像素，failed=0、underflow=0；RAW 字节 6,220,800，三帧完成。该结果证明当前仿真场景行为，不等于真实传感器 1080p30、网络完整帧率或实板时序验收。
- 完整审查、源文件哈希、资源和约束：{link(run/'result.json')}。MAP 实际消费原有 10 条 post-SYN SCF，原时序命令集合未改变；共享引脚 critical warning 仍需板级核对。
- {'已同步正式 sim/tb_video_memory_core.sv 的板级配置参数，内容与已通过完整帧验证的 fixture 相同。' if selected else '正式 RTL 与正式仿真 fixture 均保留原基线；候选通过独立冻结 fixture 验证。'}

复现协议验证使用 `python fpga/scripts/verify_control_pipeline_candidate.py --candidate {candidate.relative_to(fpga.parent).as_posix()}`；该入口从冻结候选生成启用流水参数的 fixture，并保留默认兼容测试。完整帧使用 `evaluate_control_pipeline_candidate.py --phase full --candidate` 指向同一目录。不要仅运行默认参数 fixture 就声称验证了板级新增流水。

## 固定输入与回退

- 本轮冻结候选：`{candidate.as_posix()}`。
- 本轮显式 SCF MAP：`{mapping.as_posix()}`。
- 本轮物理诊断的交接目标：`{target.as_posix()}`；是否选作正式基线以上方采用结论为准。
- 正式入口仍为 `fpga/rtl/board/pango_video_system.sv`；不要使用旧 IP 骨架工程。
- 原基线 MAP：`{old_map.as_posix()}`。已有失败 PnR 不改变它作为历史 MAP 对照的用途。
- {'采用时的旧 RTL 与 readiness 字节保存在 '+str(run/'previous')+' 和 '+str(run/'previous_readiness.json')+'；回退前核对当前工作区后续修改，不能整仓覆盖或 reset。' if selected else '未采用时没有覆盖正式 RTL，因此无需回退；冻结候选及验证证据保留供后续试验。'}

下表均相对于本轮 MAP 目录，接手前逐项校验；`sources.json` 中的全部输入也要逐项校验。

| 文件 | SHA256 |
|---|---|
{artifact_table}

## 已有物理证据与当前门禁

原基线的 90 分钟尝试见 {link(old_route/'result.json')} 与 {link(old_route/'place_route.log')}。
状态为 TIMEOUT；最后完成的 detailed-route iteration 4 仍有 87,984 条未布通连接。Global routing 完成不能当作详细布线成功；该次没有完成 PRR/布线后时序签核。
原最差综合路径经过 motion 配置校验和共享返回码，再到 tone 的 publish_generation CE，14 级、WNS -1.555 ns。本轮针对这类跨模块使能反馈做了局部化。
原布局日志共有 87 个复制源、168 个复制实例，其中 76 个复制源属于 boot；详细布局线长从全局布局 1,313,845 增至 2,574,843。它们说明互连压力，不能单独证明唯一拥塞根因。CLMA/CLMS 实际占用须读取完成的物理资源报告，不把器件容量表当作已用块数。
{physical_table}
{diagnostic_note}

本轮交接不沿用旧 MAP 的 route_scope。{'采用后布线和位流门禁保持关闭，后续运行需重新审查。' if selected else '正式 RTL 未采用；本轮临时物理诊断许可结束后关闭。'}
当前 `whole_design_route_allowed={gate['whole_design_route_allowed']}`、`bitstream_generation_allowed={gate['bitstream_generation_allowed']}`。已结束 scope 的审查记录不能授权新的运行；物理时序是否通过以上方实际 PnR 结果为准。
旧 `prepare_area60_route_ready.py` 内含旧候选固定路径，不能直接用于本轮 MAP。接手任务应根据本文件的实际输入和脚本参数建立新的冻结 scope，并重新核验进程、锁、约束和哈希。

## 下一轮物理实现建议

若本轮有界结果支持采用，可继续做 90 分钟收敛验证；若不支持，应先根据差异修改候选，避免重复等待同一失败结果。本轮参数为 seed 13、decongestion {decongestion}、{physical_mode}、LUT6D strategy 3、logic optimize enabled。
后续实验起点为 `{next_target.as_posix()}`，mode={next_mode}、decongestion={next_decongestion}；未选用的策略不能作为默认值。须从对应 MAP 重新布局，不能复用其他策略的 PLC。以下命令只有在为该 MAP 建立并审查精确 route_scope 后才可执行；门禁未满足时应拒绝启动。

```powershell
python fpga/scripts/resume_video_system.py `
  --build {next_target.relative_to(fpga.parent).as_posix()} `
  --stop-after-timing --pnr-timeout-minutes 90 --phase-timeout-minutes 90 `
  --placement-seed 13 --placement-decongestion {next_decongestion} --mode {next_mode} `
  --control-chain-length 500 --congestion-iterations 200 --dump-congestion `
  --logic-optimize enabled --lut6d-strategy 3 `
  --pause-file { (candidate/'route_stop.json').as_posix() }
```

从仓库根目录执行。原生 PDS 在本机受限执行环境曾报 WinError 623，普通执行环境启动成功；应保留原生装载失败与真实设计失败的区别。不得编辑 PDS 安装目录或系统 DLL 作为绕过手段。

记录并比较：各 packing 阶段 LUT6D 合并数、CLMA/CLMS 块占用、复制数量与来源、布局 WNS/TNS、每轮未布通数/耗时、拥塞热点、最终 PRR 的 LUT/FF/APM/DRM。
若仍失败，先按热点判断配置互连、帧池仲裁、DDR 硬块邻近通道是否受限，再决定状态读口分区、局部控制复制或布局试验；每次只改变一个因素。不要把减小缓存当作默认方案，已有 64-tile 测试超过 33.333 ms。
若线长和收敛改善而布局最差裕量退步，需要先取得含有效连线延迟的物理路径或可定位到网络的拥塞证据。上述 PLC 诊断已证实当前 report_timing 结果不能还原 placer 最差路径，不应重复用零连线延迟报告做同样判断，也不能从 SYN 路径推断布局后最差路径。
结构审查可从候选剩余的 33 个 boot 复制源入手，评估上传/状态宽总线的分组与局部寄存。它只是有证据支持的审查入口，尚未证明是最差时序路径。任何后续改动都须保持 CRC、冻结快照、事务重试和帧原子发布语义，再做同参数物理对照；不以继续删除功能作为默认手段。
官方版本文档允许 decongestion、planning 和 LUT6D 等选项，但效果需要实测；旧 LUT6D OFF 对照更差，不能默认关掉它。不要新增 false path 或降低 125/150 MHz 来掩盖失败。

只有完成详细布线、产生正式 routed DB/完整 PRR，并通过实际资源门槛，才算布通。随后检查 min/max STA、hold/removal、未匹配约束和外部接口时序；本轮没有位流生成或下载。
超时、工具错误、约束失配或用户暂停后，仅通过本轮监督器停止本轮进程，保留失败数据库和日志；不要删除其他任务的锁或反复无限重跑。

## 参考依据与未验收项

- 只读官方资料：`E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/ADS_Synthesis_User_Guide.pdf`（物理页 20–21、88–89）及 `Pango_Design_Suite_User_Guide.pdf`（物理页 109、112–113）。fanout 引导不能代替时钟/复位/CE 网络优化；mode、decongestion 与规划选项可能影响时序、拥塞和运行时间，需要对照。`Timing_Analyzer_User_Guide.pdf` 物理页 5–7 说明 PLC/SYN/PnR 数据库的差异；读取 PLC 不代表已完成布线。
- 目标核对：PG2L100H、-6、FBG676；参考 `reference/盘古100K200K MINI开发板/1_Demo_document/实验例程说明篇/教程1_盘古MINI系列开发板硬件指导手册_V1.3.pdf`。
- MCU 时间映射、机械/光学校准、HDMI 来源身份、实板功耗与吞吐、DVP/RGMII/DDR/TMDS 外部时序仍未验收。没有把预算或仿真结果写成实测。
'''
    report=fpga/'reports/配置校验流水优化与布线交接_20261025.md'
    report.write_text(text,encoding='utf-8')
    return report


def main():
    """Require native improvement and complete source-bound proof before adoption."""
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ['candidate', 'proof', 'native', 'full']:
        ap.add_argument('--'+name, type=Path, required=True)
    ap.add_argument('--promote', action='store_true')
    ap.add_argument('--physical', type=Path, help='Completed routing-feedback comparison required for adoption')
    ap.add_argument('--mapped-copy-review',type=Path,help='Verified byte-identical MAP relocation for a physical policy trial')
    ap.add_argument('--placement-diagnostic',type=Path,help='Source-bound PLC delay coverage evidence')
    a = ap.parse_args(); fpga = Path(__file__).resolve().parents[1]
    candidate = a.candidate.resolve(); identity = read(candidate/'candidate.json')
    hashes = read(candidate/'sources.json'); base = Path(identity['baseline'])
    old_hashes = read(base/'sources.json')
    native = read(a.native/'result.json'); full_eval = read(a.full/'result.json')
    assert native['passed'] and native['inputs_intact'] and full_eval['passed'] and full_eval['inputs_intact']
    mapping = Path(native['mapping']); full = Path(full_eval['steps'][0]['path'])
    # A policy trial reuses the completed native MAP. Verify its identity
    # explicitly rather than inventing another synthesis/MAP completion.
    relocated=None
    if a.mapped_copy_review:
        relocated=read(a.mapped_copy_review)
        assert relocated['passed'] and all(relocated['checks'].values())
        assert Path(relocated['parent_mapping'])==mapping
        copy=Path(relocated['mapping'])
        for name in relocated['artifacts']:
            if name!='flow.tcl':assert sha(copy/name)==sha(mapping/name)
        assert read(copy/'sources.json')==hashes
        expected_flow=(mapping/'flow.tcl').read_text().replace(mapping.as_posix(),copy.as_posix()).replace(str(mapping),str(copy))
        assert (copy/'flow.tcl').read_text()==expected_flow
        mapping=copy
    old_map = fpga/'build/full_integration_20261013/board_postsyn_20261025_162347_361985'
    proof = read(a.proof/'result.json'); full_result = read(full/'result.json')
    source_intact = lambda root, manifest: all(sha(root/'source'/n)==h for n,h in manifest.items())
    checks = dict(candidate_intact=source_intact(candidate, hashes), baseline_intact=source_intact(base, old_hashes),
        mapping_intact=source_intact(mapping, hashes), mapping_manifest_equal=read(mapping/'sources.json')==hashes,
        declared_changes_only=sorted(n for n,h in hashes.items() if old_hashes.get(n)!=h)==sorted(identity['changed_files']),
        constraints_unchanged=all(hashes[n]==h for n,h in old_hashes.items() if n.startswith('constraints/')),
        protocol_proof_complete=proof['passed'] and proof['inputs_intact'] and proof.get('complete_suite') and len(proof['cases'])==13,
        protocol_proof_frozen=all(sha(a.proof/n)==h for n,h in proof['frozen'].items()) and all(sha(Path(n))==h for n,h in proof['origins'].items()),
        full_frame_complete=full_result['passed'] and full_result['snapshot_intact'] and all(full_result[k] for k in ['full_frame','control_test','display_test','board_manual_profile']))
    checks['working_rtl_matches_baseline'] = all((fpga/n).is_file() and sha(fpga/n)==h for n,h in old_hashes.items() if n.startswith('rtl/'))
    full_hashes = read(full/'sources.json')
    checks['full_frame_source_binding'] = source_intact(full,full_hashes) and all(hashes.get(n)==h for n,h in full_hashes.items() if n.startswith('rtl/'))
    checks['full_frame_pipeline_enabled'] = '.TONE_REGISTER_BODY_CHECK(BOARD_MANUAL_PROFILE)' in (full/'source/sim/tb_video_memory_core.sv').read_text()
    checks['full_frame_local_acceptance_enabled'] = '.QUALIFY_IMAGE_LOCALLY(BOARD_MANUAL_PROFILE)' in (full/'source/sim/tb_video_memory_core.sv').read_text()
    checks['full_frame_motion_pipeline_enabled'] = all(token in (full/'source/sim/tb_video_memory_core.sv').read_text() for token in ['.MOTION_REGISTER_BODY_CHECK(BOARD_MANUAL_PROFILE)', '.POSE_MATCH_PIPELINE(BOARD_MANUAL_PROFILE)'])
    # Keep the normal board-profile regression aligned if this candidate is
    # selected. Only promote the exact fixture already used in the full run,
    # after proving no unrelated user change would be overwritten.
    tested_fixture=full/'source/sim/tb_video_memory_core.sv'
    fixture_header='// Match production local acceptance, registered schema checks and pose lookup.\n'
    fixture_flags='.TONE_REGISTER_BODY_CHECK(BOARD_MANUAL_PROFILE),.MOTION_REGISTER_BODY_CHECK(BOARD_MANUAL_PROFILE),.POSE_MATCH_PIPELINE(BOARD_MANUAL_PROFILE),.QUALIFY_IMAGE_LOCALLY(BOARD_MANUAL_PROFILE),'
    old_fixture=tested_fixture.read_text().removeprefix(fixture_header).replace(fixture_flags,'',1)
    checks['working_full_fixture_matches_preoptimization']=(fpga/'sim/tb_video_memory_core.sv').read_text()==old_fixture
    for name in identity['changed_files']:
        if '/board/' not in name:
            checks['proof_binding_'+Path(name).stem] = proof['origins'].get(str(candidate/'source'/name))==hashes[name]
    constraints = require_native_constraints(mapping); resources = require_mapped_lut_budget(mapping)
    old_resources = require_mapped_lut_budget(old_map)
    timing_inventory = lambda p:{' '.join(s.split()) for s in p.read_text(errors='replace').splitlines() if re.match(r'^\s*(create_clock|create_generated_clock|set_\w+) ',s)}
    checks['mapped_timing_inventory_equal'] = timing_inventory(mapping/'device_map/pango_video_system.dmr')==timing_inventory(old_map/'device_map/pango_video_system.dmr')
    before = synthesis(old_map/'synthesize/pango_video_system.snr')
    after = synthesis(mapping/'synthesize/pango_video_system.snr')
    # User priority is routability. Do not rank by LUT reduction or reject
    # extra pipeline FFs merely because they cost cells. Keep the real device
    # capacity gate; adoption additionally requires actual physical feedback.
    checks['mapped_capacity_gate'] = resources['below_70_percent']
    physical=read(a.physical) if a.physical else None
    if physical:
        checks['physical_comparison_valid']=physical['passed'] and all(physical['checks'].values())
        checks['physical_candidate_binding']=Path(physical['candidate']['folder']).parent==mapping
    if a.promote:
        checks['physical_feedback_supports_adoption']=physical is not None and physical['recommend_adoption']
    diagnostic=read(a.placement_diagnostic) if a.placement_diagnostic else None
    if diagnostic:
        checks['placement_diagnostic_bound']=all(sha(Path(r['report']))==r['sha256'] and r['plc_intact'] for r in diagnostic['reports'])
    log = (full/'run.log').read_text()
    cycles = list(map(int,re.findall(r'FRAME_GEOMETRY job=\d+ geometry_cycles=(\d+)',log)))
    checks['frame_cycle_budget'] = cycles==[3949266,3971723,3964236]
    checks['display_pixel_oracle'] = 'DISPLAY_CORE_PASS new=3 repeat=1 checked_pixels=8294400 failed=0 underflow=0' in log
    checks['raw_byte_oracle'] = 'TB_VIDEO_MEMORY_CORE_PASS bytes=6220800 good=3 processed=3' in log
    gate_path = fpga/'config/implementation_readiness.json'; gate = read(gate_path); gate_hash = sha(gate_path)
    checks['no_active_route_authorization'] = not gate['whole_design_route_allowed'] and not gate['bitstream_generation_allowed']
    checks['native_slot_released'] = not (fpga/'build/route_optimization/native_phase.lock').exists()
    run = candidate/datetime.now().strftime('handoff_%Y%m%d_%H%M%S_%f'); run.mkdir()
    shutil.copyfile(__file__,run/'packaging_script.py')
    evidence = {label:dict(path=str(p.resolve()),sha256=sha(p)) for label,p in [('protocol',a.proof/'result.json'),('full',full/'result.json'),('native',a.native/'result.json'),('mapping',mapping/'result.json')]}
    if a.mapped_copy_review:evidence['mapped_copy_review']=dict(path=str(a.mapped_copy_review.resolve()),sha256=sha(a.mapped_copy_review))
    artifacts = {n:sha(mapping/n) for n in ['sources.json','device_map/pango_video_system_map.adf','device_map/pango_video_system.dmr','device_map/pango_video_system.pcf','synthesize/pango_video_system_syn.adf','synthesize/pango_video_system.snr','source/constraints/video_system/reset_fsm_postsyn.scf','flow.tcl']}
    result = dict(passed=all(checks.values()),checks=checks,candidate=str(candidate),mapping=str(mapping),
        evidence=evidence,artifacts=artifacts,before=before,after=after,mapped=resources,prior_mapped=old_resources,
        constraints=constraints,cycles=cycles,physical=physical,physical_feedback_path=str(a.physical) if a.physical else None,
        placement_diagnostic=diagnostic,placement_diagnostic_path=str(a.placement_diagnostic.resolve()) if a.placement_diagnostic else None,
        production_selected=False,routed=bool(physical and physical['candidate']['routing_completed']),hardware_tested=False,bitstream_generated=False)
    result['experimental_policy_improved']=bool(physical and physical.get('policy_study',{}).get('recommend_adoption'))
    (run/'result.json').write_text(json.dumps(result,indent=2))
    if not result['passed']:
        render_report(fpga,run,result,a.proof,full,old_map)
        raise ValueError('Candidate not adopted; failed checks: '+str([n for n,v in checks.items() if not v]))
    if a.promote:
        # Compare-and-swap semantics preserve unrelated user edits and newer
        # routing owners. Archive the exact previous bytes before adoption.
        assert sha(gate_path)==gate_hash
        assert all(sha(fpga/n)==h for n,h in old_hashes.items() if n.startswith('rtl/'))
        shutil.copyfile(gate_path,run/'previous_readiness.json')
        for n in identity['changed_files']:
            backup=run/'previous'/n; backup.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(fpga/n,backup); shutil.copyfile(candidate/'source'/n,fpga/n)
        fixture_backup=run/'previous/sim/tb_video_memory_core.sv'
        fixture_backup.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(fpga/'sim/tb_video_memory_core.sv',fixture_backup)
        shutil.copyfile(tested_fixture,fpga/'sim/tb_video_memory_core.sv')
        gate.update(selected_native_build=str(mapping.relative_to(fpga.parent)),latest_mapped_candidate=str(mapping.relative_to(fpga.parent)),
            latest_mapped_lut=resources['total_lut'],latest_mapped_utilization_percent=resources['utilization_percent'],
            latest_mapped_below_strict_70_percent=True,latest_mapped_below_target=resources['total_lut']<=39960,
            area60_target_achieved=resources['total_lut']<=39960,latest_resource_evidence=str((run/'result.json').relative_to(fpga.parent)),
            completed_simulation_evidence=str((run/'result.json').relative_to(fpga.parent)),
            completed_simulation_scope=['full_frame','control_test','display_test','board_manual_profile',
                'pc_entity_upload','tone_pipeline_equivalence','pc_mcu_link','camera_validation','snapshot_reset_fence',
                'motion_config_pipeline_equivalence','pose_match_slot_ownership'],
            selected_source_simulation_passed=True,resource_and_constraints_reviewed=True,
            reason='Control-path localization and pipeline adopted after protocol/full-frame, explicit SCF MAP, and comparable physical routing feedback; any further PnR requires a fresh scope.',
            review_document='fpga/reports/配置校验流水优化与布线交接_20261025.md',
            pre_route_review_complete=False,whole_design_route_allowed=False,bitstream_generation_allowed=False,
            latest_physical_status=physical['candidate']['status'],route_scope_status='DIAGNOSTIC_FINISHED_FRESH_REVIEW_REQUIRED',
            internal_timing_met=physical['candidate']['physical_timing_met'],
            physical_signoff_pending=not (physical['candidate']['routing_completed'] and physical['candidate']['physical_timing_met']),
            latest_routed_unrouted_nets=physical['candidate']['rounds'][-1]['unrouted'] if physical['candidate']['rounds'] else None,
            latest_physical_feedback=str(a.physical.resolve().relative_to(fpga.parent)),
            selected_physical_options=physical['candidate']['options'],
            updated_at=datetime.now().astimezone().isoformat())
        # The prior scope remains archived, and cannot authorize a new MAP.
        gate['previous_route_scope']=gate.pop('route_scope',{})
        # Atomic replacement protects the reviewed selection from a partial
        # write or a Windows file-watcher collision at the existing path.
        fd,name=tempfile.mkstemp(prefix='.control-selection-',dir=gate_path.parent);os.close(fd)
        temp=Path(name)
        try:
            temp.write_text(json.dumps(gate,indent=2)+'\n',encoding='utf-8')
            os.replace(temp,gate_path)
        finally:
            if temp.exists():temp.unlink()
        result['production_selected']=True
        result['working_after']={n:sha(fpga/n) for n in identity['changed_files']}
        result['working_after']['sim/tb_video_memory_core.sv']=sha(fpga/'sim/tb_video_memory_core.sv')
        (run/'result.json').write_text(json.dumps(result,indent=2))
    report=render_report(fpga,run,result,a.proof,full,old_map)
    print('REPORT',report,flush=True)
    print('CONTROL_PIPELINE_HANDOFF',run,flush=True)
    print(json.dumps(dict(passed=result['passed'],selected=result['production_selected'],mapped_lut=resources['total_lut'],
        ddr_wns_before=before['ddr_domain_setup_wns_ns'],ddr_wns_after=after['ddr_domain_setup_wns_ns'],checks=len(checks))),flush=True)


if __name__=='__main__':
    main()
