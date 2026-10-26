# 长时路由的轻量只读复核

审查时点：2026-10-14 17:50–17:53；PDS2022.2-SP6.4 Build146967，PG2L100H/-6/FBG676。本次只读文本日志、已完成轮次的CongestionPlot、进程及官方材料；没有修改RTL/约束/live/source/active_work_state，没有启动PDS或仿真，没有停止进程，没有读取写入中的PNR/fail DB或锁。

## 当前实际状态

| 任务 | wrapper / native parent / child PID | 已完成的最新阶段 | 原生子进程累计CPU复采 |
|---|---|---|---|
| A `hybr_b_20261014_143515/resume_20261014_151539_697611` | 37056 / 39764 / 38740 | detailed iteration19：47974/111464未布通，该轮819.218750s；run.log最后追加17:43:37 | 9590.828→9685.813s |
| B `delay_20261014_153410/resume_20261014_160518_945164` | 37424 / 42128 / 11256 | detailed iteration8：66531/110713，该轮1329.109375s；最后追加17:42:17 | 6689.391→6784.188s |
| D `delay_20261014_171555/resume_20261014_174959_687659` | 44168 / 43780 / 42556 | global placement / super clustering；最后读取Design Utilization69% | 142.578→317.734s |

复采间隔约2分钟；子进程命令均明确对应build/device_map输入和自己的place_route.pds。三份Tcl第90行均为decon1 / seed11 / normal / ctrl-chain500 / congest200 / dump TRUE / native timeout0。三次活跃日志未发现Route-4022、Route-0008或Flow-0189。CPU增长表明正在计算，不能单独保证算法收敛；日志数分钟不追加也不足以判定冻结，A/B最新完整单轮已分别约14/22分钟。未生成新的路由成功结论或位流。

D wrapper实际 `--phase-timeout-minutes 0`，脚本第162行将其转换为timeout=None；A/B仍为240分钟，起始时间分别15:15、16:05，外层期限大致为19:15、20:05。原生`-action_timeout 0`不取消wrapper期限。若今后发生外围超时，应独立标记并核对实际子进程是否退出，不能归类为自然拥塞失败。

C `phys_20261014_161729_818241` 的native child42384已不存在；根目录及resume目录均保留termination_note.json，17:49:43记录intentional_priority_stop、native_route_failure=false，替换为D。其最后详细iteration7=68903，该轮1014.40625s。主动停止仅反映资源优先级，不能说明decon2不可布通。

## 官方解释及当前可用证据

安装版《Pango Design Suite User Guide》印刷p117特别将PG2L100H的General/Router归为Logos参数列；p119中Logos的拥塞模式迭代上限默认200。p113/p252说明`-congest_overlap_limit`仅是拥塞模式最大迭代次数，未提供Route-4022的内部提前判停公式。它不是强制完成200轮，也不是全局路由每个分组的统一停止条件。Placement仍使用Logos2列，不应将这一Router特例误套到Bump。

已完成的SRB拥塞图是当前可读取的实际诊断：官方p113–114说明dump选项输出CongestionPlot及CongestionNetInfo，前者显示每轮SRB拥塞，后者记录冲突net；支持载入不同文件、统一颜色上限和SRB搜索。以下是本次对旧完整文件的轻量统计，不是官方归一化拥塞指标：

| 实现/轮次 | 图中最大值 | 正值网格数 | 非负网格值总和 |
|---|---:|---:|---:|
| A10 | 41 | 8865 | 108213 |
| A18 | 32 | 8411 | 73230 |
| B5 | 100 | 9380 | 212330 |
| B7 | 64 | 9248 | 177941 |

同文件格式均为6×6划分、204行、10550个非负有效格；-1哨兵未计入。该区间SRB冲突值下降与日志未布通下降相符。不同实现/不同轮次不能据此单因素归因；这些总和不是net数量、时序slack或布线完成比例，也不能证明唯一瓶颈、预计剩余时间或最终可布通。

## 长期未完成时仍可做的诊断

1. 对同一精确PID/命令做稀疏CPU、PrivateMemory、WorkingSet复采，同时记录日志及完成轮次文件的mtime/size。将CPU变化与新iteration输出合看；低WorkingSet不能当成没有计算（17:53 A/B PrivateMemory均约3.75GB，WorkingSet约0.95/1.03GB）。记录工具自然退出、wrapper timeout、主动停止三种不同结局。避免打开正在写入的DB。
2. 对每个实现自身已经完成的CongestionPlot轮次使用同一颜色标度，观察SRB热点是否迁移及下降；结合对应完整CongestionNetInfo按层级和驱动位置聚合，不把某个最高值或同名记录条数视为唯一原因。官方支持的Open Congestion Plot可只加载这些文本文件；本次没有实际打开GUI。与既有SNR/controlsets、MAP/PCF、静态约束、placement复制/packing日志交叉核对，形成问题位置和约束覆盖证据。
3. 工具流程自然结束后再检查对应.prr、Clock Summary和routed min/max STA。官方p119–121说明PNR结束后生成资源/IO/clock报告，Clock Summary来自对应pnr.adf。长时阶段的PLC零route-delay STA仅可用于逻辑定位；不能冒充routed检查。若另行需要PLC诊断，应在副本和独立输出目录进行，保留同源及“placement estimate”标记；本次未执行任何新诊断工具。

官方p116–117的“Route Constraint Iterate”是按setup slack自动生成/累加优先布线RCF并重新跑PR的功能，具有独立停止条件，不是当前router的详细iteration计数，也不是只读诊断。本次不启用它、不生成优先布线约束、不改变时钟或false-path。

## 实际来源

- 各build的place_route/run.log、对应resume/place_route.tcl和精确Win32_Process命令；CPU取Get-Process复采。C的termination_note.json。
- A CongestionPlot_10.txt、_18.txt；B CongestionPlot_5.txt、_7.txt；只读取已经完成轮次。
- 官方原件只读：`E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Pango_Design_Suite_User_Guide.pdf`，本次SHA256仍为`e2ac3f2ac7bb539cc51fe85cc239ea2249f4ee6790912b67c86cae23a3898ba2`；已提取文本在`fpga/build/full_integration_20261013/reference/`，引用印刷p111、p113–114、p116–121、p252。官方资料未给出内部拥塞提前停止阈值，不能自行编造。
