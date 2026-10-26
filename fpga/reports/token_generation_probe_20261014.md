# 内部 token 代次冗余隔离仿真

2026-10-14 21:28起；独立目录 `fpga/build/full_integration_20261013/token_gen_probe_20261014_212845_127584/`。从正在布线的 D=`delay_20261014_171555/source` 复制 bank/pkg/layout/manager/snapshot 原始输入，复用 `ord_20261014_1705` 的公开接口回归。没有修改 live、D/E/G 或其约束，没有全帧模型或硬件动作；候选尚未推广。21:35前仅Icarus；后续另获单位原生综合授权，结果另列于下。

基线 bank SHA256=`37f5830798d3a5ad57987401a862a1221cbb7cbb13278e6d3dca20b714e5131e`；候选=`f445700f24a71e203e31fe20849965ccb15885d4b17fe383e39fc3ecf5f8b1b1`。差分参考只将当前 D module 改名，不是旧 order_id 实现。去除注释/空白后，候选只删除 token_gen 声明、ISSUE写入及 inflight/writes/drain_error 中的 token_gen==generation 比较；公开32位 generation、64位 ticket、next_order、所有外部身份校验、饱和拒绝及 drain fence 保持。更新职责注释说明 token 阻止槽重用的设计前提。代码归纳依据见 `current_map_congestion_review_20261014.md`。

Icarus第二次回归 `sim_20261014_213314_550077/result.json` 实际 passed=true/inputs_intact=true。完整rsp逐拍前后差分明确为 SLOTS=3/TXNS=4：12,057 cycles、246,168 checks；旧实现独立断言 `token_busy -> slot合法 && busy[slot] && token_gen==generation[slot]` 3,828次。计数：365 ISSUE、363 COMPLETE、12次不同token同拍issue/complete、675 CANCEL、19错误drain、18定向步骤、4定向quarantine hold、2代次边界、1票据边界；另有14 reset、484随机隔离、682空洞重用及1,631并发事件。全64位order末值拒绝沿用既有测试。

定向覆盖包括 SEAL仍有写token、CANCEL不清token并阻止新ISSUE、最后COMPLETE当拍不释放、旧generation/stale ticket拒绝、fault等效fabric_ready保持/恢复、联合cold flush/reset、consumer RELEASE与ISSUE互锁及已有读token保持槽、32位generation最后一次使用/耗尽跳过、64位ticket最后一次使用/错误完整ticket拒绝/耗尽不wrap。单位测试的fabric_ready保持代表bank接口隔离，未把它描述为实板故障或完整DDR适配器验证。

baseline/candidate各6项旧回归全部PASS，实际计数相同：

| 用例 | 实际TXNS | checks / cycles | 关键覆盖 |
|---|---:|---:|---|
| frame_manager | 8默认 | 1755 / 1165 | 每池连续100帧、ownership/reset、无效payload X隔离 |
| frame_manager_pressure | 8默认 | 5755 / 3193 | 512帧、1258重叠周期、2664 stall；seed51453990 |
| frame_snapshot_pair | 8默认 | 237 / 480 | 2 pair / 4失败清理 |
| metadata_ram_multiport | 4显式 | 48 / 20 | 四consumer同时读取完整616位descriptor |
| metadata_single_slot | 4显式 | 366 / 236 | 一槽完整616位、四consumer |
| ticket_rollover | 1显式 | 6 | 越32位、截断旧ticket拒绝、64位末值/耗尽 |

为覆盖主板实际 BANK_TXNS=4，保留上述默认8-token测试，另复制前三项为显式TXNS=4，容量填满/排空/poison循环相应使用4项，公开断言不删除；来源/前后SHA记录于 `txns4_fixture_origins.json`。`sim_20261014_213851_547649/result.json` baseline/candidate共6次新增执行全部PASS：manager1747checks/1138cycles，pressure5755/3193，snapshot237/480。新差分的代次/票据饱和定向测试自身也是4-token。两次成功仿真结果分别绑定各自实际输入，未追改旧结果。

首轮 `sim_20261014_213137_395141/result.json` passed=false完整保留。该轮新差分和baseline全部回归通过；candidate manager在elaboration阶段因旧白盒cold-reset poison仍写已删除的token_gen[n]报错，候选RTL未执行。确认该夹具依赖后，只在candidate测试副本删除该无效赋值，仍poison剩余slot/owner载荷，公开断言全部保留并更新注释；`fixture_adaptation.json`记录前后SHA与原因。候选RTL未修改，新目录重新执行全部测试。

`evidence.json`记录全部输入/结果SHA、逻辑差异和原构建完整性；`candidate_changes.diff`便于检查。D/E/G各290项source再次重算匹配，live bank也仍等于原D。仿真证明针对实际覆盖的可达同步状态；本次未运行formal工具。主板 TXNS=4 五池声明冗余为640位，但实际可消除资源以native结果为准。当前 D/E/G继续原来源路由，本候选仅作为后备输入。

## 单位原生综合阶段

21:40在授权后启动 `run_native_synthesis.py`，顺序执行 SLOTS3 baseline/candidate、SLOTS1 baseline/candidate，全部TXNS4。输出隔离到 `native_syn_20261014_214030_192622`，仅compile/ADS SYN，未调用MAP/PnR/bitgen。每项使用相同既有全ABI wrapper：动态32位输入串移写满1078位cmd，动态execute/sample/shift_out观察全部2889位rsp，四consumer及所有descriptor字段没有常量裁剪；base/candidate wrapper字节相同。目标PG2L100H/-6/FBG676，8ns，同 `synthesize -ads -selected_syn_tool_opt 2`。首项发起前Windows实际可用5,226,528KiB；每次发下一项前低于1GiB则停止继续派发，不改变D/E/G进程。

官方只读原路径 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/ADS_Synthesis_User_Guide.pdf`（SHA `9930e586e71fed2faedf239b6af965eda69845f494fd506d2e708cf9f6fed9f0`，印刷p9–10），及同版本PDS User Guide印刷p165 Tcl范例；旧范例其他器件不能冒充本器件验证，实际Tcl在每项输出目录。

四项顺序单位综合已完成，native runner退出0；`native_syn_20261014_214030_192622/result.json` passed=true，各项native_exit=0、errors=[]、inputs_intact=true。源SHA、实际SNR/controlsets SHA及Tcl都保留，D/E/G各290项来源再次匹配；最后live bank也仍等于原D。

| 单位（全部TXNS=4） | baseline LUT / FF / RAM | candidate LUT / FF / RAM | 实际变化 | unique controlsets |
|---|---:|---:|---|---:|
| SLOTS=3 | 6566 / 4996 / 1072 | 6361 / 4867 / 1072 | –205 LUT、–129 FF；RAM不变 | 26→26 |
| SLOTS=1 | 3805 / 5161 / 0 | 3746 / 5033 / 0 | –59 LUT、–128 FF；RAM不变 | 17→17 |

四项APM/DRM均0，原生综合结果不等于整板MAP/PnR资源。baseline/candidate相应wrapper实际字节一致，全部动态ABI保持；差异只有bank的上述内部token_gen逻辑。每项前可用内存为5,226,528 / 4,956,260 / 4,971,608 / 4,968,364 KiB，没有触发低内存停止派发。未据声明640位推导整板可消除FF，也未由单位收益承诺路由成功。没有对本候选启动整板综合/全帧模型或推广live。仿真各阶段精确执行runner按原结果SHA保存到相应输出目录，避免后加TXNS4入口覆盖先前版本证据。
