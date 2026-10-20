# DeepSeek + Claude Code：FPGA 布线启动与长期监控交接

编写时间：2026-10-20，Asia/Shanghai。交给已经配置好 DeepSeek 模型连接的 Claude Code 执行环境使用。本文不依赖某个模型别名、API 网关或 Claude Code 多智能体命令；模型连接由使用者现有环境提供，密钥不得写进项目、日志或 Git。

**执行目标：核验已通过设计与仿真的固定版本，复用完成的 MAP，执行一轮整板布局布线和 min/max STA，持续监控并保存结果。首轮不生成位流、不下载、不烧录。** 本文的编写过程没有启动布线，也没有改变当前布线授权开关。用户将本文作为任务交给接手智能体后，接手者按下述前置检查更新授权记录并执行，不需要重复询问已经分派的布线任务。

## 1. 给接手智能体的启动指令

可将下面这段连同本文件路径直接发给 DeepSeek + Claude Code：

> 你负责执行 `D:\XDU\concept\26-FPGA-Pango\fpga\reports\deepseek_claude_code_routing_handoff_20261020.md` 中的布线与监控任务。先读项目根目录 AGENTS.md 和本交接，再核验固定输入、完整 MAP、进程互斥及就绪记录。通过后按本文开启本次整体布线门槛，复用 MAP 运行 seed 11 的 PnR 和 min/max STA，必须带 `--stop-after-timing`。只允许一个 PDS 执行者，不改冻结源码或时序约束，不生成位流。持续观察日志并每小时汇报，失败、停滞或超时先保存和分析，不自动续时或扫 seed。保存最终进度、接续说明、精确 Git 提交和推送。模型上下文丢失时先恢复运行状态，禁止重复启动已有任务。

## 2. 项目位置、工具和权威资料

| 项目 | 固定位置 / 要求 |
| --- | --- |
| 本地仓库 | `D:\XDU\concept\26-FPGA-Pango` |
| Git 远端 | `https://github.com/CaiVegetable0932/26-FPGA-Pango.git` |
| 工作分支 | `codex/fpga-pds-project` |
| 已验证设计提交 | `a4bc5aae`，15项累计设计修改；后续文档提交不代表新的 RTL 版本 |
| 操作系统 / Shell | Windows，PowerShell；不要照搬 Linux bash 命令 |
| PDS | `E:\PDS_Pangu\PDS_2022.2-SP6.4\bin\pds_shell.exe` |
| PDS 版本 / 器件 | 2022.2-SP6.4 build 146967；Logos2 / PG2L100H / FBG676 / -6 |
| 官方手册，只读 | `E:\PDS_Pangu\PDS_2022.2-SP6.4\doc` |
| 板卡参考，只读使用 | 仓库 `reference/`，核对目标板版本，不以别的器件资料替代 |
| 项目规范 | 根目录 `AGENTS.md`；若当前工作路径存在更深层同名规范，也要读取 |
| 优化方案 | `output/FPGA布线效率与拥塞专项优化方案.md` |
| 设计阶段交接 | `fpga/reports/route_optimization_handoff_20261020.md` |
| 设计阶段完整进度 | `fpga/reports/route_optimization_progress_20261019.md` |

先确认本地目录和分支。不能直接 `git reset --hard`、`git clean`、覆盖拉取或切换分支来“清理环境”。本地原有大量不属于本轮的修改，原始清单在 `fpga/build/route_optimization/session_20261019/initial_git_status.txt`。遇到后续设计提交或源哈希不符，停止启动并定位版本差异，不把旧 MAP 用在新 RTL 上。

## 3. 当前已经完成什么

- 主设计：DDR业务域125MHz；几何、缓存、Gamma与结果writer处理域150MHz。显示的DDR访问侧属于125MHz业务域；HDMI像素/串行、相机、RGMII等保留各自真实时钟，不能把它们统称为125MHz。
- 完整1080p控制/同帧快照/实际显示仿真通过：22,809,600个显示像素，3新帧、8重复帧，失败0、下溢0。三个几何作业3,948,091 / 3,972,204 / 3,962,298个DDR周期，在该行为模型的30fps预算内，最坏余量4.6671%。这不等于硬件吞吐保证。
- 最终主目录20项回归、控制/快照模型、链路断开与恢复、六类完成故障后的恢复和共同冷复位检查通过。主机8888报文、12,441,600图像字节通过，原始快照与125MHz基线逐字节一致。
- 板级 MAP 已完成：LUT 41,477；FF 42,053；APM 118；DRM折算103.5。启动预算分别50,000 / 95,000 / 180 / 120；DRM折算数不能证明物理位置一定可布通。
- 实际PLL、全局时钟、CDC端点及同步链结构检查通过。**本版整板 PnR、routed setup/hold、CDC物理延迟、外部时序和硬件验证尚未完成。**
- 约束检查有61条历史板级/PHY critical warning，与旧基线相同、无新增，涉及共享DDR引脚及部分IO drive/slew缺省；不允许猜测电气参数来消警。结构审查不等于已排除所有约束风险。

核心证据位置（相对仓库根）：

| 证据 | 路径 |
| --- | --- |
| 选定源码308项清单 | `fpga/build/route_optimization/session_20261019/processing_finalist/sources.json` |
| 选择与来源记录 | 同目录 `selection.json` |
| 完整帧仿真 | `fpga/build/full_integration_20261013/verilator_20261020_044250_609135/result.json` |
| 合入后20项回归 | `fpga/build/full_integration_20261013/sim_20261020_052620_282958/result.json` |
| 合入后控制/快照 | `fpga/build/full_integration_20261013/verilator_20261020_052630_443140/result.json` |
| 主机解码 | `host/reports/fpga_rgb_vectors_20261020_052259_836952.json` |
| 实际MAP与结构审查 | `fpga/build/route_optimization/proc150_board_mapping_20261020_050951_080852/` 下 `mapping_validation.json`、`processing_mapping_audit.json` |

注意：该MAP目录的旧 `result.json` 保留了监督脚本输出目录拼写错误导致的host断言失败。`mapping_validation.json` 独立验证两原生阶段均退出0、成功日志、完整无锁DB和SHA；不能删掉旧失败记录。更早 `board_20261020_044551_218517` 是总预算超时任务，不能用其中未保存完整的 SYN DB。

## 4. 必须遵守的项目约束

1. FPGA实现、脚本、仿真、日志和报告分别放 `fpga/rtl`、`fpga/scripts`、`fpga/sim`、`fpga/build`、`fpga/reports`。PC内容归 `host/`，MCU内容归 `mcu/`。`output/`仅放规划，不放实现代码或运行产物；根目录不新增业务脚本或构建目录。
2. 官方安装目录及文档只读。提取手册文字、运行示例、生成索引和日志均写入 `fpga/`。不得复制厂商专有仿真库、许可证或密钥到公开Git。
3. 保持真实1080p30、原始数据、位精度、pre/post Gamma语义、四bank并行采样、帧ID/代次和同帧快照契约。PC不承担实时几何矫正；HDMI硬件帧源身份仍未验证，保持unverified。
4. 不改变DDR PHY、目标器件、封装、速度级、板级引脚或真实时钟以换取“布通”。不得关闭功能、降低频率、切宽度、全域false-path、跳过hold或忽略违规来宣布通过。
5. 当前任务只实施已冻结版本。布线时不编辑其 `source/`、`sources.json`、MAP、PCF、时序约束；分析出的RTL方案只能在独立工作区另建候选，先仿真再进入新的物理轮次。不能覆盖原通过/失败证据。
6. 同一台机器最多一个重型PDS实现任务。PG2L100H按本版手册使用单线程路由器；多个模型不能协同执行同一个路由算法，也不要增加router线程冒充加速。
7. 所有新增/修改代码块要同步注释，说明用途和设计意图。此次不涉及MCU接口改造；不要把旧MCU协议或未验证硬件事实写回项目。
8. Git仅排除现有根目录 `reference/` 与 `PDS/`，不得新增忽略规则。保护原有脏工作区，精确暂存本轮文件；禁止 `git add .`、强推或删除未知锁文件。
9. 只终止本轮拥有且核验身份的PID树，不得按 `pds_shell.exe` / Python进程名批量结束任务。`.git/index.lock`、`native_phase.lock` 均须先确认持有者是否仍在运行，不因时间久就直接删除。
10. 本任务不授权位流生成、JTAG下载或板卡烧录。启动命令必须带 `--stop-after-timing`；该脚本省略此选项时原默认流程会进入bitgen，不能省略。

## 5. 启动前检查和MAP恢复

在PowerShell中执行只读检查：

```powershell
Set-Location -LiteralPath 'D:\XDU\concept\26-FPGA-Pango'
git -c core.fsmonitor=false branch --show-current
git -c core.fsmonitor=false log -3 --oneline
git -c core.fsmonitor=false status --short --untracked-files=no
Get-Command python
python -c "import sys,psutil; print(sys.executable); print(psutil.__version__)"
Test-Path -LiteralPath 'E:\PDS_Pangu\PDS_2022.2-SP6.4\bin\pds_shell.exe'
Get-CimInstance Win32_Process -Filter "name = 'pds_shell.exe'" | Select-Object ProcessId,CreationDate,CommandLine
Get-Item -LiteralPath 'fpga/build/route_optimization/native_phase.lock' -ErrorAction SilentlyContinue
```

若已有PDS或布线driver运行，先核验其归属、启动时间和工程路径，恢复监控，不重复启动。保留当前Git状态到新会话。Python依赖以本机已验证环境为准；不要为了启动任务盲目升级PDS/Python/仿真器。

复用工程为：

`D:\XDU\concept\26-FPGA-Pango\fpga\build\full_integration_20261013\handoff_20261020_053147_229875`

必须核验：

- `flow.pds`、`flow.tcl`、`sources.json`及所有 `source/` 成员SHA。
- `handoff_preparation.json` 的 `prepared=true`、原生输入一致性与数据库SHA；`restore_native_artifacts.json`说明归档恢复映射。
- `device_map/pango_video_system_map.adf` SHA256：`6f71a296eced5942389318ef043689795626f16854cf868983e6c0e31da88474`。
- `device_map/pango_video_system.pcf` SHA256：`6076ff6f14da06bcd4b01755dad9e909e7355e183d2ca5e4f583019965bc1428`。
- `processing_finalist/sources.json`各路径相对`fpga/`，必须与当前选定源码一致；handoff工程自己的清单则相对其`source/`。两份清单用途不同，不混用。

下面的校验不会启动PDS：

```powershell
@'
from pathlib import Path
import hashlib,json
f=Path('fpga')
b=f/'build/full_integration_20261013/handoff_20261020_053147_229875'
def check(root,manifest):
    entries=json.loads(manifest.read_text(encoding='utf-8'))
    bad=[n for n,h in entries.items() if not (root/n).is_file() or hashlib.sha256((root/n).read_bytes()).hexdigest()!=h]
    if bad: raise RuntimeError('Source mismatch: '+repr(bad))
    print('Verified source files:',len(entries))
check(f,f/'build/route_optimization/session_20261019/processing_finalist/sources.json')
check(b/'source',b/'sources.json')
d=json.loads((b/'handoff_preparation.json').read_text())
for name,key in [('pango_video_system_map.adf','map_sha256'),('pango_video_system.pcf','physical_constraints_sha256')]:
    p=b/'device_map'/name
    assert hashlib.sha256(p.read_bytes()).hexdigest()==d[key],name
assert d['prepared'] and d['native_inputs_identical']
print('MAP and PCF verified')
'@ | python -
if ($LASTEXITCODE -ne 0) { throw 'Preflight verification failed' }
```

如果云端克隆后缺少DB，不重新跑整个前端：先校验 `fpga/build/route_optimization/proc150_board_mapping_20261020_050951_080852/native_mapping_0535.zip` 的SHA及同目录 `native_mapping_0535_manifest.json` 中每个成员SHA；按handoff目录 `restore_native_artifacts.json` 恢复。只在上述项目目录内解压，拒绝越界路径；已有不同内容的文件不得覆盖。恢复后再次执行校验。工程内含本机绝对路径，换机器/目录时必须重新生成并核验项目路径，不能直接假定可搬迁执行。

## 6. 建立独立会话、记录授权并启动

**只有用户将本文交给你执行、且第5节校验通过后，执行本节。** 设计阶段已完成，不需要重复询问同一布线授权。若用户只让你阅读或审查文档，就维持开关为false。

创建新会话，不复用或删除旧 `session_20261019` 的停止文件和 `session_complete.json`。保存启动前就绪记录，确认前三项true，再只开启整体布线授权项。该变更不代表时序已通过。

```powershell
$repo = 'D:\XDU\concept\26-FPGA-Pango'
Set-Location -LiteralPath $repo
$session = Join-Path $repo ('fpga/build/route_optimization/deepseek_route_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fffffff'))
New-Item -ItemType Directory -Path $session -ErrorAction Stop | Out-Null
$build = Join-Path $repo 'fpga/build/full_integration_20261013/handoff_20261020_053147_229875'
$gatePath = Join-Path $repo 'fpga/config/implementation_readiness.json'
Copy-Item -LiteralPath $gatePath -Destination (Join-Path $session 'readiness_before.json')
git -c core.fsmonitor=false status --short --untracked-files=no | Set-Content -LiteralPath (Join-Path $session 'git_status_before.txt') -Encoding UTF8
$gate = Get-Content -LiteralPath $gatePath -Raw -Encoding UTF8 | ConvertFrom-Json
if (!$gate.design_complete -or !$gate.selected_source_simulation_passed -or !$gate.resource_and_constraints_reviewed) { throw 'Design gates incomplete' }
$gate.whole_design_route_allowed = $true
$gate.reason = 'User assigned this DeepSeek + Claude Code session to execute the verified MAP through PnR and min/max STA only.'
$gate.updated_at = (Get-Date).ToString('o')
[IO.File]::WriteAllText($gatePath, ($gate | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
$pause = Join-Path $session 'stop_requested.json'
$pythonExe = (Get-Command python -ErrorAction Stop).Source
$runArgs = @('-u','fpga/scripts/resume_video_system.py','--build',$build,
  '--stop-after-timing','--placement-seed','11','--placement-decongestion','1',
  '--phase-timeout-minutes','60','--pnr-timeout-minutes','60','--dump-congestion',
  '--pause-file',$pause)
# 本文固定项目路径没有空格。换到含空格路径时须先正确引用各参数，不直接拼接命令。
$driver = Start-Process -FilePath $pythonExe -ArgumentList $runArgs -WorkingDirectory $repo -WindowStyle Hidden `
  -RedirectStandardOutput (Join-Path $session 'driver_stdout.log') `
  -RedirectStandardError (Join-Path $session 'driver_stderr.log') -PassThru
$record = [ordered]@{session=$session;build=$build;driver_pid=$driver.Id;driver_start_utc=$driver.StartTime.ToUniversalTime().ToString('o');python=$pythonExe;arguments=$runArgs;stop_file=$pause;bitstream_authorized=$false;started_at=(Get-Date).ToString('o')}
[IO.File]::WriteAllText((Join-Path $session 'launch.json'), ($record | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
$session
```

命令固定seed11和decongestion1；其余已验证默认项保持原值。不增加effort、不自动扫seed、不照抄旧实验的macro/planning选项叠加变量。`--phase-timeout-minutes 60` 是**每个原生阶段**的host上限，不是含STA的总耗时保证。首次PnR上限60分钟；若进入STA仍要监控，不能把两个阶段的时间混称为60分钟总预算。

Start-Process启动的是后台driver；它内部调用独立PDS监督器。启动后立即核对driver PID、创建时间、命令行、`native_phase.lock`和新 `resume_*` 证据目录，确认只有一个任务。后台启动不等于Windows服务：模型上下文结束后是否继续运行必须实测核对，注销、关机、休眠或宿主清理进程都可能中断。长跑期间保持机器供电，按用户已有电源安排执行，不擅自修改全局系统设置。

## 7. 长期监控与上下文恢复

本地 `fpga/scripts/route_supervisor.py` 每30秒记录状态，并独立执行停止规则；模型无需每30秒调用工具或消耗一次API。DeepSeek建议每1～5分钟读取最新证据，遇到异常立即处理，每小时向用户汇报。对话工具若有超时，只影响该次等待，不代表PDS失败；先查磁盘和PID，不能再次执行启动命令。

恢复对话时按顺序读取：本文件 → 新会话 `launch.json` → driver PID/创建时间/命令行 → 对应新 `resume_*` 的最新monitor → 该目录 `result.json`（若已产生）。从`launch.json`恢复`$session`/`$build`变量，禁止把历史最新目录误认为本轮；应按启动时间与日志互相确认。

实际日志在handoff工程下面新建的 `resume_YYYYMMDD_HHMMSS_*` 目录中：

- `place_route.log`、`place_route_monitor.jsonl`、`place_route_monitor.policy.json`：PnR日志、每30秒状态及冻结预算。
- `report_timing.log`与对应monitor：进入STA后产生。
- `result.json`：本轮终结结果；在运行期间可能尚不存在。handoff根目录 `result.json` 也可能是上一轮，优先看本轮resume目录。
- `place_route/` 和 `report_timing/pango_video_system.rtr`：原生物理产物与时序报告。
- 新会话 `driver_stdout.log` / `driver_stderr.log`：Python监督与最终异常信息。

只读取少量增量或尾部，避免反复把整份大日志送入模型：

```powershell
# $evidence必须先与本轮launch时间对应确认。
$evidence = (Get-ChildItem -LiteralPath $build -Directory -Filter 'resume_*' | Sort-Object Name | Select-Object -Last 1).FullName
Get-Content -LiteralPath (Join-Path $evidence 'place_route_monitor.jsonl') -Tail 1
Get-Content -LiteralPath (Join-Path $evidence 'place_route.log') -Tail 30
Get-Content -LiteralPath (Join-Path $session 'driver_stderr.log') -Tail 15
```

每次观察持久化到新会话 `observations.jsonl`：时间、driver/native PID与身份、阶段、elapsed、当前轮次、当前/历史最少未布通数、最近窗口改善、每轮CPU时间、日志大小/静默时间、进程CPU/内存、预算和下次动作。原生monitor中已有的字段直接引用，缺失指标写“不可获得”，不可补造。

每小时在 `fpga/reports/` 更新本轮进度，并向用户报告：运行版本/seed、阶段、耗时/上限、未布通数及趋势、是否触发预警、约束/时序异常、下一步、Git保存情况。若Claude Code当前无人值守会话不能自动向用户发消息，至少落盘小时报告，并在可用会话恢复后补发；不要声称已实现自动通知。需要定时唤醒/消息通道时由执行环境另外提供，不能仅靠一句模型提示保证长期在线。

### 停止规则

- PnR硬上限60分钟，48分钟预警；原生 `-action_timeout` 与host监督独立，不因某个工具继续输出就延长。
- 前5轮后，最近5轮窗口最优未布通数改善不足1%，且剩余超过1000，监督器标记STALLED并停止拥有的任务。接近收敛时比例规则不适用，但硬上限仍有效。
- 10分钟无日志触发调查：核对CPU增量、内存、DB/阶段文件变化与进程状态，不能仅凭静默判死锁。
- 用户要求停止、已确认账户额度达到停止线、错误版本/输入漂移或需人工处理的问题，写本会话停止文件。监督器下一次检查会停止自己的原生PID树；**PAUSED不是可以从最后一个路由迭代无损恢复的承诺**。

```powershell
[IO.File]::WriteAllText((Join-Path $session 'stop_requested.json'),
  ('{"reason":"User stop or reviewed terminal condition","requested_at":"' + (Get-Date).ToString('o') + '"}'),
  [Text.UTF8Encoding]::new($false))
```

写停止文件后等待监督器确认终结、核对拥有的子进程退出，再整理证据。不能先结束Python driver而留下PDS孤儿。紧急手动终止也须核验PID创建时间及本轮父子关系，且只操作本轮进程。

### 额度与长时间无人值守

原任务的10%停止线针对**Codex账户额度**；05:35的34%只是历史读数，不能当成DeepSeek API余额或Claude Code套餐用量。旧 `optimization_status.py` 读取Codex会话数据，不能拿来监控DeepSeek。如本次继续采用“账户剩余10%停止”，执行者必须使用实际服务商可读取的额度/预算数据并记录来源、时间及单位；无法读取时明确报告“不可监控”，不能伪造百分比。不要把密钥或完整账单内容送入公共仓库。日志采集与PDS限时机制应独立于模型可用性；模型断连也不能让一轮PDS无限运行。

## 8. 终结与下一轮决策

只有本轮原生PnR结束、STA执行成功、输入SHA未变、`native_exit=0`、无工具错误，且新 `.rtr` 中Design Summary为All Constraints Met并复核slow/fast setup/hold、recovery/removal与约束覆盖后，才记录“本轮内部物理时序通过”。不能只看Python退出、未布通数为0或旧报告。外部IO/CDC/硬件仍按实际验证范围列出未签核项。

TIMEOUT、STALLED、FAILED、ORPHANED、PAUSED均保留原状态、退出码、原始日志、已完成数据库、迭代历史及CongestionNetInfo。旧整板曾运行约50分31秒仍剩37,200个未布通子网；当前60分钟是首轮预算，不是保证布通的预测。

失败后先形成具体诊断和有限下一轮提案。原方案只允许固定seed11/7/13的小样本复现、每轮至多两个结构候选；不得自动无限续时、自动重启同一seed或把失败结果改标通过。重跑必须使用独立证据目录、单一变量、同样约束和预算，保留旧产物。RTL变更需要重新仿真和MAP，不复用旧DB。若要扩展到位流、硬件或改变既定目标，交回用户分派。

可用角色分工：一个执行者独占PDS与就绪门槛；一个分析者只读日志；可选RTL验证者在独立工作区准备候选。所有人共享同一资源预算，只有集成负责人提交或合并，其他角色不能启动第二个PDS或改动当前工程。只有执行环境已支持且用户分派了并行角色时采用多智能体；单模型轮流完成这些角色同样可执行本文。

## 9. 收尾、Git和再次交接

1. 保存本轮最终结果、资源与时序摘要、失败原因/下一步、PID退出证明、输入与产物SHA。更新本轮进度和交接，写明项目绝对路径、分支、版本、session和resume路径、停止文件及尚未完成项。
2. 本轮终结后将当前就绪记录 `whole_design_route_allowed` 恢复false并记录原因，避免下一轮自动启动；保留其他真实设计/仿真状态。不修改冻结工程里的配置副本或历史记录。
3. 只暂存本轮新增/修改文件及已审查的就绪记录，先核对diff。大DB/网表/PCF归档为带逐成员SHA的ZIP，写恢复说明；不要把运行中的可变日志称为已冻结证据，不新增ignore。
4. 使用仓库现有身份创建本地提交并向 `origin/codex/fpga-pds-project` 推送，最终核验远端提交。保留初始无关修改；严禁reset/clean、强推、随意删Git锁或上传密钥/厂商专有库。

正常推送优先使用现有Git连接。该机器此前验证可用的单次网络配置如下；只有本地7897代理仍存在时使用，不写成全局配置，不关闭证书校验：

```powershell
git -c http.proxy=http://127.0.0.1:7897 -c http.sslBackend=schannel -c http.version=HTTP/1.1 -c http.postBuffer=104857600 push origin HEAD:refs/heads/codex/fpga-pds-project
```

交接完成必须明确：是否布通、是否本轮内部STA通过、哪些外部/CDC/硬件问题未签核、是否仍有进程、是否已提交和推送。没有位流或硬件结果就保持未完成，不把设计仿真结论升级为板卡运行结论。
