# FPGA 布线优化设计阶段交接

更新：2026-10-20 05:35（亚洲/上海）。设计文件修改、候选筛选、最终功能仿真与板级MAP/结构审查已完成；**整机布线、routed STA、完整位流和硬件验收未完成**，由用户另行安排智能体。

## 项目与接手入口

- 本地：`D:\XDU\concept\26-FPGA-Pango`。
- 云端：<https://github.com/CaiVegetable0932/26-FPGA-Pango>，分支 `codex/fpga-pds-project`。最终提交以该分支 `git log -1` 核对；此前检查点 `aebdfbca0` 已推送，最终检查点在本交接生成后提交/推送。
- 原方案：`output/FPGA布线效率与拥塞专项优化方案.md`。实现/证据归 `fpga/`、`host/`，未改厂商安装目录。
- 最终选择：15项累计设计修改，DDR/帧池/ISP/网络/显示125MHz，几何/缓存/Gamma/结果writer150MHz。`config/integration/processing_domain.json` 是默认构建入口的实际架构配置。
- 冻结选择：`fpga/build/route_optimization/session_20261019/processing_finalist/sources.json`（308项，含最终测试夹具/配置），`selection.json` 记录资源、期限、来源及限制。修改前备份在同会话 `processing_promotion_20261020/before/`，恢复修复前备份另在 `geometry_recovery_promotion_20261020/`。

## 最终验证

完整帧：`fpga/build/full_integration_20261013/verilator_20261020_044250_609135` PASS，1920×1080，控制提交/同帧快照/实际显示均打开；检查22,809,600个显示像素，3新帧、8重复帧，失败0、下溢0。三个几何作业3,948,091 / 3,972,204 / 3,962,298个DDR周期；最坏比4,166,666.67周期模型预算余194,462.67（4.6671%）。这只是当前独立DDR行为模型/场景，不是任意硬件仲裁的保证。软件运行2343.531秒，预先预算3600秒。

主机：`host/reports/fpga_rgb_vectors_20261020_052259_836952.json` PASS，8888报文、12,441,600图像字节。原始datagrams SHA256 `f42a234194de8b85d182f6e4d1ae089d3f02266d8e1918fb0a027853e5c01669`，descriptors `1f7791da07114603493586ee16181dae243ab13a38b9085d15da53d887666366`，均与原125MHz基线逐字节相同；HDMI硬件身份仍unverified。

最终候选20项回归 `sim_20261020_050821_373307`；可选快照关闭夹具20项 `sim_20261020_052124_365537`；合入后主目录20项 `sim_20261020_052620_282958`；合入后控制/快照小模型 `verilator_20261020_052630_443140` 全部PASS（均位于同full_integration根）。可选实例引用仅增加generate保护，快照启用分支观察/独立断言未改，变换记录 `proc150_fixture_20261020_052157_013140`。

链路断开/取消排空/恢复：`verilator_20261020_051856_347330`（含快照）及 `verilator_20261020_052214_318729`（不含快照）PASS。写CDC四时钟组每组32场景、作业邮箱四组每组82作业、quad CDC八组每组21 tile、共同冷复位7场景通过。六类源/结果完成错误、取消、坏tag及逐帧恢复在同步1组/双时钟3组通过；旧125MHz恢复竞态已修复，未牺牲位精度或代次。

## 区域处置已收敛

| 区域 | 最终处置 |
| --- | --- |
| writer | 保留BRAM/递推基线，合入完整signed乘积与两拍帧入口流水；50语义/范围/取消测试、413798算术检查、3 seed候选STA通过。多2拍/帧、0拍/段；参考A时序失败，不报加速比 |
| unpack/RGB reader | 合入局部捕获；三个seed两侧STA通过，PnR中位44→38秒，改善13.64%，不宣称达到30%或整机同幅收益 |
| DMA | 分组、游标/统计候选未形成稳定合格物理收益，全部不合入；统计only seed7 STALLED，未继续扫seed。保留原native事务、返回标识和排空契约 |
| boot / snapshot-copy | boot原局部捕获回退；snapshot局部捕获37→38秒且线长增加，保留原版 |
| 帧池/广播 | slot-local flags时序失败；16位分块hold失败，单变量d2复核setup仍失败；8位分块2/3 seed通过、seed13 setup−0.135ns，均不合入，完整64位代次/耗尽语义保留 |
| refill/cache/Gamma/APM | 保留位精确算术、本地tag与四bank采样/12个pre Gamma读端口；最终只在tile边界跨域，逐行DDR refill留125MHz，消除逐行CDC往返 |
| 150MHz架构 | 低层读burst两候选超服务预算，不采用；最终tile域完成全帧、故障恢复和板级MAP审查后合入。旧低层adapter仅为冻结闭包一致性保留，未实例化 |
| PHY/IO | DDR IP与原DDR/引脚约束保持原字节。新增sys_pll OUT1、全局buffer、共同冷复位及窄CDC约束；未修改官方PHY |

未开展的DMA浅缓存/LUTRAM等后备研究是后续可选研究，不是本次已选设计的未完成代码，也不得当作已优化成果。所有失败/超时保留原始状态。

## 实际板级MAP、约束与限制

`fpga/build/route_optimization/proc150_board_mapping_20261020_050951_080852`：SYN8m42s、MAP2m21s完整结束。实际MAP LUT41,477 / FF42,053 / APM118 / DRM等效103.5（启动预算50,000 /95,000 /180 /120）。报告18K/36K折算不等于任意物理硬块均可自由组合。

`mapping_validation.json` 校验完整数据库；`processing_mapping_audit.json` 检查实际PLL 125×6/5、真实CLKBUFG、16类非空CDC端点、9组双级链与10个Gray位的直接连接/第二级保留。DMR实际processing_clk fanout8573；保持源寄存器到首次捕获的6ns约束，不放宽处理域内部路径。该审查不等于每条宽总线/双时钟RAM电气图或routed max/hold/MTBF签核。

约束检查0 error、61 critical warning；与旧板级基线61条完全相同，未新增，主要共享DDR引脚与IO drive/slew缺省。不为消警猜测电气参数，接手者需结合真实板卡资料审查。原厂DDR时钟组等例外保留，新增processing_cdc无全域clock-group/false-path。

首次`board_20261020_044551_218517`总预算1200秒TIMEOUT：Compile12m31s完整、SYN保存未完成；只复用完整Compile DB。之后SYN1200秒/MAP600秒独立预算均完成。旧监督脚本把device_map写成dev_map，原`result.json`保留host断言失败；旁证`mapping_validation.json`独立核验两原生阶段退出0、成功日志、DB无锁及哈希，不把超时结果改标PASS。脚本已修正。

## 交给布线智能体

**已准备可接续工程**：`fpga/build/full_integration_20261013/handoff_20261020_053147_229875`，含`flow.pds`、308项源清单、完整`device_map/pango_video_system_map.adf`和`pango_video_system.pcf`，实际305项原生输入与MAP逐项相同。只生成项目，未启动compile/SYN/MAP/PnR/STA或位流。`handoff_preparation.json`与最终归档成员哈希可核验。

当前`fpga/config/implementation_readiness.json`前三项设计/仿真/资源审查true，`whole_design_route_allowed`仍false。最终两次真实CLI拒绝检查证明从新建及resume入口均不能自动整体布线。新智能体获得用户分派、审查上述限制后才更新这个单独门槛；不要删除已有整体停止文件或冒用旧任务停止文件。

接手授权后，可使用下列命令复用MAP进行PnR及min/max STA，**不生成位流**（本轮没有执行）：

```powershell
python fpga/scripts/resume_video_system.py --build fpga/build/full_integration_20261013/handoff_20261020_053147_229875 --stop-after-timing --placement-seed 11 --placement-decongestion 1 --phase-timeout-minutes 60 --pnr-timeout-minutes 60 --dump-congestion --pause-file fpga/build/route_optimization/session_NEXT/stop_requested.json
```

`--stop-after-timing`明确省略bitgen阶段。默认只运行一个PDS；PG2L100H单线程路由按安装版Logos对应参数，固定seed11、7、13有限复现，不自动扫seed。每30秒监控；60分钟上限及方案停滞规则不变。必须核对slow/fast setup/hold、所有CDC的真实6ns路径、第二级普通时序、generated clock与复位、外部DDR/HDMI/RGMII/相机时序；任何未布通/TIMEOUT/STALLED或时序失败均不算完成。

如需重新构建，默认`build_video_system.py --stage dev_map`已自动读取生产processing profile；实际全帧证明输入与最终原生305项逐一绑定。`board_20261020_052640_715990`是默认入口snapshot-only验证，未调用native。

## 本地、云端与监督收尾

初始已有212项tracked修改和大量产物，不属于本轮；清单`session_20261019/initial_git_status.txt`。最终只精确scope暂存，逐文件核对工作树/暂存区SHA，不使用git add .，不增加忽略规则。原生数据库/网表/PCF用带逐成员SHA的ZIP归档，恢复先校验，不覆盖旧失败证据。

账户实测剩余约34%，未触及10%停止线；本次停止原因是用户要求的设计/仿真阶段完成并交接布线，而非额度耗尽。小时报告已发至04:48，05:35提前完成交接；工作期间的30秒quota记录保留。`session_complete.json`通知本轮watcher正常退出；没有拥有的PDS/软件模型继续运行，不创建子智能体。

云端恢复原生大文件：校验`proc150_board_mapping_20261020_050951_080852/native_mapping_0535.zip`及其manifest，解压到该mapping目录，再按handoff工程`restore_native_artifacts.json`核验并复制device_map成员到handoff的device_map目录。已有文件须先核对哈希，不能覆盖不同的运行结果。源码、工程、日志及小型证明直接随Git保存。
