# Claude Code + DeepSeek：FPGA布局布线与完整位流交接任务书

日期：2026-10-24。工作目录：`D:\XDU\concept\26-FPGA-Pango`。目标：从已验证的L候选继续布局布线、完成实际资源和时序审查，生成完整离线位流并交付证据。

## 1. 可直接交给目标智能体的启动指令

> 请执行 `output/ClaudeCode_DeepSeek_FPGA布线与完整位流交接_20261024.md`。先阅读仓库AGENTS.md和必读证据，核验最终L候选。完成布局布线和实际min/max时序审查，严格保证最终物理LUT小于46,620，再从同一个已通过时序的PNR数据库生成完整.sbit。保持冻结源码和历史证据完整；失败先定位，再做有对照的修改或重构，不盲目循环。各阶段将状态保存到文件，长期运行期间监控自有进程、日志与收敛。可以并行分析和审查，但同一时刻只运行一个PDS重任务。不下载或烧录硬件。最终报告位流路径、SHA256、资源、时序、源版本和未关闭的板级事项。

本文不依赖特定模型版本、Claude专属MCP或API参数。Claude Code承担本地文件/终端执行与状态保存，DeepSeek承担推理和日志分析。若DeepSeek就是Claude Code背后的唯一模型，“执行/审查”是分阶段职责，不能冒称两个独立模型复核。模型接入沿用已经可用的环境，本任务不修改服务配置或密钥。

**本文件编写阶段没有启动PDS，也没有修改布线或位流授权。** 用户将本任务书交给目标智能体执行后，范围包括布局布线和条件满足后的离线位流生成。原交接中“本轮停止在布线前”描述上一轮边界；执行者须按本文分阶段、有证据地更新live门禁，不能一次全部置true。

## 2. 不可放宽的条件

| 项目 | 要求 |
| --- | --- |
| 器件/工具 | PG2L100H-6、FBG676、顶层`pango_video_system`；PDS 2022.2-SP6.4 build146967 |
| LUT | MAP和最终PR均须整数`<46620`，最多46,619；不以四舍五入百分比代替 |
| 功能 | 保持当前实际启用的MCU/姿态路径和单源1080p30范围；禁止回退到MCU被常量裁掉的假低资源基线 |
| 时序 | 同一实际PNR数据库的min/max分析；setup/hold及适用recovery/removal满足，例外和未约束路径单独审查 |
| 位流 | 实际原生bitgen成功，产生非空完整`pango_video_system.sbit`，记录大小和SHA256 |
| 实物边界 | 不下载、不烧录、不改eFuse；离线生成不等于实板验收 |
| 文件落点 | 脚本、构建、实测和报告在`fpga/`；发布在`fpga/release/`；`output/`只放任务规划 |

“完整位流”指全工程离线配置文件，不是局部模块试验位流。内部物理门禁通过而外部IO证据仍缺时，可以交付**完整工程验证位流**，必须明确`external_timing_verified=false`、`hardware_tested=false`、`programmed=false`，不能称为板级放行版本。禁止伪造外部延迟、放宽时钟或删除真实检查以换取通过。

## 3. 唯一接续基线与必读资料

最终L：`fpga/build/full_integration_20261013/board_postsyn_20261023_221908_913042`。

| 证据 | 当前事实 |
| --- | --- |
| MAP资源 | 46,152/66,600 LUT，69.297297%；距允许上限仅467 LUT |
| MAP数据库 | `device_map/pango_video_system_map.adf` |
| MAP DB SHA256 | `be0434a4c56ecd5db8166306cab36deea0b06652ce8a100c751ffd182fd2e086` |
| 冻结源 | `source/`及`sources.json`，321份 |
| 时序约束 | 179条命令、15个时钟、10条精确SCF异步复位例外 |
| PCF | `device_map/pango_video_system.pcf`，117条端口+3条实例定位 |
| CCR | 1066条、0错误、33条共享配置管脚critical warning、0普通warning；不是无告警 |
| 功能 | 14组同源验证通过；1080p仿真3帧，检查8,294,400显示像素，underflow=0 |
| 物理阶段 | 交接时L没有PLC、完成布线或位流 |

L与父候选K的源、全部9份SYN文件及CCR逐字节相同，仅显式输入SYN DB和SCF重新MAP；不宣称在L重跑Compile/SYN。K完整ADS流程曾静默漏载SCF（169条），J有STA-3015；**不能使用J/K原MAP，也不能重跑完整ADS后覆盖L**。

必读：

1. [仓库AGENTS](../AGENTS.md)、[布线前交接](../fpga/reports/布线前验证与智能体交接_20261023.md)。
2. [交付哈希](../fpga/build/mcu_link_20261023/final_pre_route_delivery.json)、[功能绑定](../fpga/build/mcu_link_20261023/final_source_binding.json)。
3. [179条约束审查](../fpga/build/mcu_link_20261023/camera_reset_L_review_20261024/final_map_constraints.json)、[源/SYN/CCR/PCF继承](../fpga/build/mcu_link_20261023/camera_reset_L_review_20261024/source_synthesis_ccr_pcf_inheritance.json)。
4. [综合时序](../fpga/reports/布线前综合时序审查_20261023.md)、[外部IO](../fpga/reports/外部IO时序约束审查_20261023.md)、[MCU协议](../fpga/reports/MCU_22452f3通信协议兼容性审查_20261023.md)。
5. [live门禁](../fpga/config/implementation_readiness.json)、[接续脚本](../fpga/scripts/resume_video_system.py)、[位流入口](../fpga/scripts/native_bitgen.py)、[资源门禁](../fpga/scripts/implementation_readiness.py)、[约束门禁](../fpga/scripts/constraint_report.py)、[监督器](../fpga/scripts/route_supervisor.py)。

官方目录`E:\PDS_Pangu\PDS_2022.2-SP6.4\doc`全部只读。核对安装版主手册印刷111–118页（物理实现）、152页（Persist Pin），UCE印刷10页（后综合SCF），结合reference中的MINI/PG2L100H板卡资料。本次官方摘录在`fpga/build/handoff_claude_deepseek_20261024/official_excerpt.txt`。操作变化仍须查对应原文和本机help。PG2L100H的router使用官方Logos选项、单线程，不因CPU未占满就判挂起。旧H拥塞建议末尾的SYN DB CLI方案已被实际Flow-0013试验否定，以最新综合时序报告为准。

## 4. 职责、状态与并行限制

- **执行者**唯一负责PDS启动、live门禁、试验参数和实现修改。
- **分析者**可并行读关键路径、拥塞、日志和官方资料，不启动第二个PDS。
- **审查者**核对最终PR资源、时序/数据库绑定、SCF/PCF和位流哈希；单模型时如实标注同一智能体复核。

在`fpga/build/route_handoff_<时间戳>/`保存`status.json`和阶段检查。至少记录：候选绝对路径、源/DB哈希、阶段、自有PID及创建时间、resume目录、原生命令、开始时间、超时、日志尾部、资源/时序状态、下一步和未关闭项。报告在`fpga/reports/`，发布包在`fpga/release/<唯一目录>/`。

上下文压缩、模型切换或重启后，先读状态并核实进程；不得凭记忆重启已有任务。禁止按最近修改时间自动选择候选。共享锁`fpga/build/route_optimization/native_phase.lock`存在时核查所属进程；不得删除活跃锁。仅确认进程已结束后才归档并清理僵死锁，不按进程名批量kill。

## 5. 阶段A：核验并开启布线

```powershell
Set-Location 'D:\XDU\concept\26-FPGA-Pango'
$candidateBuild = 'fpga/build/full_integration_20261013/board_postsyn_20261023_221908_913042'
Get-FileHash "$candidateBuild/device_map/pango_video_system_map.adf" -Algorithm SHA256
Test-Path 'fpga/build/route_optimization/native_phase.lock'
```

逐项核对源清单全部SHA256、固定MAP DB哈希、14组依赖绑定和约束/PCF证据。交付哈希是当时快照，首次更新门禁前保存旧live文件；后续resume会归档并更新根result，不能覆盖旧证据来伪造连续成功。若工作区RTL变化，明确接续冻结L还是建立新候选，禁止混用。

确认`design_complete`、`selected_source_simulation_passed`、`resource_and_constraints_reviewed`三项为true且证据有效。只更新工作区`fpga/config/implementation_readiness.json`：

```text
whole_design_route_allowed = true
user_stop_before_routing = false
regional_physical_checks_allowed = false
bitstream_generation_allowed = false
```

同时记录reason、时间和任务；未验证字段保持false。不要修改冻结`source/config/`，接续脚本读取live门禁。建议用同目录临时文件及原子替换，避免读者持有文件时截断失败。

## 6. 阶段B：布局布线与min/max时序

第一轮按基准执行；以下在同一PowerShell会话中使用阶段A变量：

```powershell
$attemptTag = Get-Date -Format 'yyyyMMdd_HHmmss_fffffff'
$pauseFile = "fpga/build/full_integration_20261013/route_pause_$attemptTag.request"
python -B fpga/scripts/resume_video_system.py --build "$candidateBuild" --stop-after-timing --placement-seed 11 --placement-decongestion 1 --macro-placement Global --planning-before-place --installed-pnr-help fpga/build/full_integration_20261013/handoff_20261020_053147_229875/resume_20261021_161504_599534/installed_pnr_help.log --mode normal --control-chain-length 500 --congestion-iterations 200 --dump-congestion --pnr-timeout-minutes 60 --phase-timeout-minutes 60 --pause-file "$pauseFile"
if ($LASTEXITCODE -ne 0) { throw '布局布线/时序未通过，保留证据并诊断' }
```

该命令先PnR，再对PNR DB执行`report_timing -delay_type min_max -max_path 30 -report_exception TRUE`。保留`--stop-after-timing`，审查后再单独bitgen。首轮不使用`--from-placement`，因为L没有PLC。不得简化为裸DB PnR：现脚本保留RTL/IP注册并加载MAP PCF，DDR固定位置依赖这些上下文。

监督器持锁、约30秒采样，记录自有进程树/CPU/内存。每30–60秒增量检查并保存状态，避免重复读取全量大日志：

- 当前阶段、进程存活、CPU时间和日志增长。
- 实际创建的`resume_<时间戳>/place_route.log`、`place_route_monitor.jsonl`和`report_timing.log`；固定记录该目录。
- 各轮unrouted nets及下降趋势、单轮耗时。PLC估计WNS/TNS只用于诊断。
- `place_route/pango_video_system.prr`、最终`*_pnr.adf`、`report_timing/pango_video_system.rtr`；文件存在不等于完成。
- 原生E、STA-3015、约束加载与端点变化。默认60分钟是各阶段上限，不是成功时长承诺。

需要停止时，在另一终端给**该次保存的pause-file绝对路径**创建空文件，监督器会停止自有树并记录状态。不要重新计算时间戳创建错误路径，每次尝试用不同pause-file。日志安静时先查CPU/子进程，不直接重启。停滞、超时、人为停止分别记录，均不能标为完成。

## 7. 失败诊断与修改边界

| 现象 | 处理 |
| --- | --- |
| PR LUT≥46,620 | 阻止后续放行；查复制、packing及层次资源，修改后重新验证 |
| 广域拥塞但未布通持续下降 | 继续有界当前运行，不因若干轮仍有未布通就判失败 |
| 基准自然失败/超时且证据显示拥塞 | 可做一次decongestion=2、其余不变的对照；比较资源、收敛和时序后决定下一步 |
| setup失败 | 按实际PNR路径logic/net/clock分量决定布局试验或RTL流水/仲裁重构 |
| hold/removal失败 | 核对时钟、真实异步端点与例外传播；禁止屏蔽整个时钟域或DDR IP |
| STA-3015或SCF缺失 | 立即阻止放行；查实际加载链，不以native0或CCR0错误替代 |
| 改RTL/时序约束 | 新候选、新哈希、受影响仿真、Compile/SYN/显式SCF MAP，再做物理验证 |

当前SNR DDR setup最差−1.337ns，路径为DMA `loaded[0][0]→beat_index[0..2]/CE`，13级、逻辑1.948ns、估计线6.683ns；处理域仅+0.378ns。厂商短路径hold仍待物理验证，Fast Corner空表不能算双corner通过。不能通过虚假false-path、降频或删除检查清零。

用户允许为严格70%扩大重构或删组件，但应依据实际证据做必要改动，维持单源视频、MCU真实路径与协议契约。板级已关闭自动AE/AWB/自动tone、自定义LUT和独立C6，三条预设tone仍保留。进一步删tone须同步能力位、返回码、文档和测试；旧估计节省量不能代替新MAP。受影响代码块同步注释。

新ADS候选若再次漏载SCF，使用`fpga/scripts/map_postsyn_candidate.py --build <新综合候选>`生成派生MAP，重新核对完整约束/PCF及测试绑定。设计网表变化时，不能把原十条FSM实例路径直接套用而不复核。

## 8. 阶段C：位流前放行检查

以下是执行者的必需核验步骤，不要求每步重复询问用户：

1. 本次PnR自然完成，native0、无原生错误；PRR有完整routing完成标记，未布通清零；PLC/中断结果不合格。
2. `require_routed_lut_budget`通过：实际CLMA+CLMS LUT整数小于46,620；LUTRAM已包含，不重复加。
3. 本次STA输入当前PNR DB且使用min_max；核对corner、检查类型、负裕量、未约束端点与例外覆盖。未知覆盖不能标为已验收，不能只grep一句汇总。
4. 原生汇总`All Constraints Met.`；真实setup/hold及适用recovery/removal满足。SCF精确例外、其他时钟/例外保留，新增STA-3015为0，禁止手改报告。
5. 冻结源完整、同源功能验证有效；MAP、PCF、PNR、RTR逐项SHA256绑定，记录本次resume目录。
6. 33条共享配置管脚告警保留板级审查。沿用现有`High Voltage`、`Release For USER`配置，不随意改Persist Pin、IO电压、引脚或加密；工具设置不代替实物验收。
7. 外部IO/MCU未关闭项单列。相机直连但仍缺完整DVP保证延迟与板级偏斜；MCU22452f3的INFO/OPEN事件起点、旧IMU声明和时间映射/标定问题不可在FPGA布线任务中猜测规避。

保存审查报告及live门禁旧副本后，置`bitstream_generation_allowed=true`；保持`whole_design_route_allowed=true`及三个就绪字段。硬件、外部时序等状态不随门禁开启自动变true。

## 9. 阶段D：独立生成完整位流

不要为bitgen再运行默认`resume_video_system.py`，它会重新PnR。使用`native_bitgen.generate_from_timed_database`，从已通过时序的同一个PNR DB生成。它检查live授权、约束、PR资源与STA汇总，验证PNR/RTR哈希不变。下列代码只在阶段C全部完成后执行；新候选须将`$candidateBuild`改为实际已验证目录。

```powershell
$env:FPGA_HANDOFF_BUILD = (Resolve-Path $candidateBuild).Path
@'
from pathlib import Path
from datetime import datetime
import hashlib, json, os, re, sys
sys.path.insert(0, str(Path('fpga/scripts').resolve()))
from native_bitgen import generate_from_timed_database

# Reuse the verified PNR checkpoint; do not rerun physical implementation.
run = Path(os.environ['FPGA_HANDOFF_BUILD']).resolve()
evidence = run / ('bitgen_release_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
evidence.mkdir()
stream = run / 'generate_bitstream/pango_video_system.sbit'
if stream.exists():
    raise RuntimeError('Archive and verify the prior bitstream before retrying')
log = evidence / 'bitgen.log'
child = generate_from_timed_database(
    run, 'E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe', log)
text = log.read_text(encoding='utf-8', errors='replace')
if child.returncode or re.search(r'^\s*E:', text, re.M):
    raise RuntimeError('Native bitgen failed; preserve evidence')
if not stream.is_file() or stream.stat().st_size == 0:
    raise RuntimeError('Full native .sbit absent or empty')
checkpoint = json.loads((run / 'bitgen_checkpoint.json').read_text(encoding='utf-8'))
if not checkpoint['checkpoint_intact']:
    raise RuntimeError('PNR database or STA report changed during bitgen')
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
result = dict(
    status='COMPLETE_OFFLINE_BITSTREAM', candidate=str(run),
    bitstream=str(stream), bytes=stream.stat().st_size, sha256=sha(stream),
    routed_database_sha256=sha(run/'place_route/pango_video_system_pnr.adf'),
    timing_report_sha256=sha(run/'report_timing/pango_video_system.rtr'),
    sources_manifest_sha256=sha(run/'sources.json'),
    native_exit=child.returncode, checkpoint_intact=True,
    external_timing_verified=False, hardware_tested=False, programmed=False)
(evidence/'result.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
print(json.dumps(result, indent=2))
'@ | python -B -
if ($LASTEXITCODE -ne 0) { throw '位流生成未完成，检查独立bitgen证据' }
```

该函数不是独立CLI，直接`python fpga/scripts/native_bitgen.py`不会生成。现有监督上限300秒，超时先诊断再决定是否修改有界预算，不绕过门禁。脚本硬条件不能代替阶段C的完整时序覆盖审查。示例保守保留外部/实物false；另有真实验收时在清单引用证据更新，不能推断。

本交付要求.sbit；如另有.bin需求，查安装版官方bitgen选项再生成，禁止改扩展名冒充。

## 10. 发布与完成标准

在`fpga/release/<唯一发布目录>/`复制.sbit及清单，核对复制前后SHA256一致，不覆盖旧发布。大数据库/日志可留原build目录，清单保存可定位路径和哈希。至少交付：

- 位流、字节数、SHA256、器件/工具版本及生成选项。
- MAP/PR LUT整数和百分比、最终FF/DRM/APM等资源表。
- 本次PnR/STA/bitgen命令、退出码、时间、日志；失败/人为停止仍可追溯。
- PNR DB、RTR、PRR、PCF、源清单和功能绑定的哈希；`bitgen_checkpoint.json`和独立bitgen结果。
- setup/hold/recovery/removal与corner覆盖、例外继承、未约束路径处理记录。
- 代码改动、功能取舍、重跑或按哈希复用的测试；未改源码时明确沿用L。
- 外部IO、MCU联调、接线/标定、1080p30吞吐/功耗/HDMI身份未关闭项，`programmed=false`。

同步live状态与交接报告，记录最终候选及位流，不修改历史冻结配置。结束后关闭本次临时route/bitgen许可，保留验证完成事实。无另行用户指令，不自动Git提交/推送或下载硬件。

最终回复回答：布线是否完成、最终LUT、物理时序结论、完整位流路径/哈希、剩余板级事项。任一硬门禁失败，就交付失败证据和具体剩余项，禁止用旧位流、局部位流或伪造报告充数。
