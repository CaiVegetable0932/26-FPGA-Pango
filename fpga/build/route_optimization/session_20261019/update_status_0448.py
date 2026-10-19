"""Hourly status: distinguish selected RTL, rejected pool and pending processing domain."""
from pathlib import Path
import hashlib,io,json,re,subprocess
ROOT=Path(__file__).resolve().parents[4];S=Path(__file__).resolve().parent
F=ROOT/'fpga';B=F/'build/full_integration_20261013';R=F/'reports'
hashes=json.loads((S/'writer_pipeline_finalist/sources.json').read_text())
process=subprocess.run(['git','-c','core.fsmonitor=false','cat-file','--batch'],cwd=ROOT,
    input=''.join('HEAD:fpga/'+n+'\n' for n in hashes).encode(),capture_output=True,check=True)
stream=io.BytesIO(process.stdout);bad=[]
for n,h in hashes.items():
    header=stream.readline().split();data=stream.read(int(header[2]));assert stream.read(1)==b'\n'
    if hashlib.sha256(data).hexdigest()!=h or hashlib.sha256((F/n).read_bytes()).hexdigest()!=h:bad.append(n)
assert not bad
(S/'selected_main13_source_check_0448.json').write_text(json.dumps(dict(source_count=290,
    head_and_worktree_intact=True,differences=bad,selected_changes=13),indent=2))
pool=F/'build/route_optimization/pool_chunk8_20261020_034402_468921/pool_unit_screen_20261020_035039_067599'
records=[]
for case in sorted(pool.glob('regional_route_*')):
    d=json.loads((case/'result.json').read_text());j=next(j for j in d['jobs'] if j['label']=='candidate')
    records.append(dict(seed=d['seed'],case=str(case),timing_clean=j['all_internal_constraints_met'],wirelength=j['wirelength']))
assert [r['timing_clean'] for r in sorted(records,key=lambda r:r['seed'])]==[True,True,False]
(pool/'stability_terminal_review_0448.json').write_text(json.dumps(dict(decision='NOT_PROMOTED_STABILITY_FAILURE',
    sample_count=3,passed_count=2,failed_count=1,records=records,additional_seed_scan=False),indent=2))
# A fixture-generation failure never launched RTL; publish that distinction
# separately instead of treating it as an unexplained functional test result.
for folder in (F/'build/route_optimization').glob('proc150_tile_faults_*'):
    if not (folder/'result.json').exists():
        (folder/'generation_failure.json').write_text(json.dumps(dict(status='FIXTURE_GENERATION_FAILED',
            rtl_simulation_launched=False,reason='Checked generator anchor mismatch before compile; corrected in a new run'),indent=2))
status='''
## 2026-10-20 04:48 小时进度

当前主设计仍为13项，最近已推送 `cd9ce316`；290项输入的工作树与HEAD绑定核对通过。整体方案未完成，整体PnR及位流继续关闭。最近真实账户额度剩余35%，到10%停止优化并保存交接。下次小时汇报05:48。

本小时结论：

- 帧池8位计数分块：seed11/7内部STA通过，seed13 setup−0.135ns（2端点），三次仅2次通过。稳定性不合格，未合入，不再扫描seed。其组成版本正常全帧功能通过也不能替代物理稳定性；后续选定组合已改回原帧池。
- 新故障恢复测试暴露旧125MHz设计的问题：源读错误之后首个正常帧仍失败，事务已排空。同步原版复现 `proc150_tile_faults_20261020_042448_053067`。原因是cache_start延后一拍清旧cache fault，新帧busy提前看到旧标志。
- 单行恢复修正只在既有cache初始化拍屏蔽旧fault，不增加延迟/改变精度。修正后同步参考及三组双时钟的15帧测试均通过：6类源/结果完成错误、取消、坏tag；每个坏作业后跟一个独立字节验证的好帧。证据 `proc150_tile_faults_20261020_042552_100909` 与 `proc150_tile_faults_20261020_042552_140908`。尚未合入，不能把当前主设计13项说成已通过新增恢复场景。
- 恢复修正、原帧池组成版本：`geometry_recovery_20261020_042541_182177`；20回归 `sim_20261020_043508_583868` PASS，全1080p模型 `verilator_20261020_043518_857947` 运行中。
- 150MHz低层burst CDC方案A首个作业4470577 DDR周期，功能全帧PASS但服务期限不合格。读预取方案B首个4323516周期，仍不合格，其全帧模型 `verilator_20261020_035853_729207` 在原2400秒预算TIMEOUT，未延时/未补签PASS。
- 新一轮改在tile/四像素流边界跨域：逐行3beat请求保留DDR域，64个完整quad经既有异步FIFO交给处理域；不增加native在途事务。八组独立CDC测试、三组真实几何字节模型、控制/同帧快照小模型通过。首个全帧作业3948091 DDR周期，低于旧同场景4073517及4166666.67周期服务预算，其他场景仍待结束。
- 最终待选处理组合已排除帧池候选并包含恢复修正：`proc150_video_model_20261020_043529_242103`；小模型 `verilator_20261020_043626_233147` PASS；完整1080p控制/快照/实际显示 `verilator_20261020_044250_609135` 运行中，软件预算预先设3600秒（旧双时钟实测2337.9秒），观察额度停止文件，未改变任何活动旧预算。
- projective处理子系统原生SYN `proc150_mapping_20261020_043616_243611` PASS：LUT10975、FF9043、APM117、物理DRM41；不是整机资源，不能与旧MAP直接相加，无150MHz物理签核。
- 实际板级接入候选 `proc150_board_20261020_044427_625524` 准备完成：已有125MHz参考的sys_pll OUT1 150MHz、真实CLKBUFG、共同冷复位、窄CDC界限。共同复位原型7场景通过（含停时钟及短失锁）。原生 `board_20261020_044551_218517` 只运行Compile/SYN/MAP，当前活动中，固定20分钟；没有整体布线或位流。
- 安装版UCE手册印刷p83确认max-delay端点支持get_clocks。新增作业总线约束从命名的、持有到作业完成的DDR寄存器出发，到处理时钟捕获端；同步器只界定首级，后续级普通计时。实际非空匹配、映射与资源仍需原生核对，不能把草案当CDC签核。

未选定实验、失败记录、原始数据库均保留。`fpga/experiments/proc150/`仍不在生产RTL收集目录；主设计时钟仍125MHz，恢复修正和150MHz接入均未合入。设计与仿真完成后通知用户，由用户安排其他智能体监控整体布线。
'''
for n in ['route_optimization_progress_20261019.md','regional_verification_plan_20261019.md','control_locality_review_20261020.md']:
    with (R/n).open('a',encoding='utf-8',newline='\n') as file:file.write('\n'+status)
p=R/'route_optimization_handoff_20261020.md';text=p.read_text(encoding='utf-8')
text=text.replace('更新时间：2026-10-20 03:58','更新时间：2026-10-20 04:48')
text=text.replace('## 项目地址和授权',status+'\n## 项目地址和授权')
start=text.index('## 续接顺序');end=text.index('## 监督、额度与Git',start)
next_steps='''## 续接顺序

1. 先查真实quota和native_phase.lock。唯一PDS是上述板级候选MAP；等待终结并检查DDR/PLL时钟、资源、约束匹配及全部输入哈希。严格禁止PnR/位流。
2. 恢复修正的原帧池125MHz完整模型结束后，核对主机解码与快照原始字节，再考虑单文件合入；保留13项备份。当前13项有已复现的失败后恢复问题，不能直接发布。
3. 等待最终无帧池候选的150MHz tile域全帧模型，检查全部3个几何作业服务预算、22809600显示像素、同帧控制/快照及主机原始字节。其他含帧池候选或未修复版本只作实验记录，不能混签。
4. 板级候选MAP和CDC核对合格后，才选择实际板级接入；生成精确最终来源清单和组成验证，不能整目录覆盖主设计。处理域尚无routed/STA或硬件签核，交接中必须保留此限制。
5. 额度到10%停止新增及拥有的任务，保存进度/交接、精确scope提交和推送。每小时汇报；没有创建子智能体。

'''
text=text[:start]+next_steps+text[end:]
p.write_text(text,encoding='utf-8',newline='\n')
print('HOURLY_0448_UPDATED')
