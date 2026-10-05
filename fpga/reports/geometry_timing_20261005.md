# FPGA 灰度矫正离线构建报告

本报告记录 2026 年 10 月 5 日在 `codex/fpga-geometry-correction` 分支上，对 `mini_raw8_geometry` 的功能回归和 PDS 构建。目标器件为 PG2L100H-6FBG676，PDS 版本为 2022.2-SP6.4。本轮不连接硬件，不烧录 Flash。

**最终状态：功能仿真、综合、布局、布线与独立多角 min/max STA 均已执行；时序未闭合，未导出位流，不是可上板发布版。** 最新独立 STA 的 setup WNS 为 −2.424 ns，hold 最差为 −0.008 ns。当前无后台 PDS 构建运行。

## 时序修复

前一版最终布线的 125 MHz 建立时间 WNS 为 −4.240 ns，最长路径包含坐标范围检查和级联宽乘法。当前实现将宽乘法拆为带输入寄存器的有符号 16 位分块乘法、部分积寄存器和逐级寄存的平衡加法树。映射器与配置查表计算均使用有效信号等待结果，保持定点取整、无效坐标掩码和输出反压规则。

第一轮仅拆分乘法的综合报告仍显示查表输出经过减法及选择器后进入乘法器的长路径，WNS 为 −1.543 ns。该次运行在布局阶段主动停止，没有生成位流。记录在 `fpga/build/mini_raw8_geometry/native_20261005_103725_182/`；其 `result.json` 明确标为未完成。补上乘法输入寄存器后重新完成所有功能回归，再启动第二轮构建。

未降低时钟频率、添加宽泛 false path 或 multicycle 例外。引脚、原生 DDR/PLL/FIFO IP 和既有板级约束保持不变。

## 已完成的仿真

| 检查 | 当前源码结果 | 证据目录 |
| --- | --- | --- |
| 精确乘法、符号极值、连续输入、空拍、复位清空 | 三种位宽共 10518 个乘积通过 | `fpga/build/geometry_mul_20261005_104725_758/` |
| 鱼眼坐标与数学模型比较 | 305 个坐标通过，最大误差 31 个 Q12 单位，约 0.00757 px | `fpga/build/geometry_chain_20261005_104729_896/` |
| Brown 与旋转坐标比较 | 305 个坐标通过，最大误差 1 个 Q12 单位 | 同上 |
| 参数版本切换与灰度采样写回 | 两帧、512 个像素逐点检查通过 | 同上 |
| UART 参数协议 | 6073 个检查、63 个响应通过 | 同上 |
| 帧池与租约并发 | 通过 | 同上 |
| 全尺寸板级模型 | 两个摄像头源帧、两个网口帧、一个矫正结果，HDMI 2073600 个像素逐点检查通过 | `fpga/build/geometry_board_20261005_104822_986/` |

全尺寸测试使用原生 FIFO 仿真模型、带延迟与反压的内存协议模型、半像素/四分之一像素非恒等变换，检查边界裁切、增强只执行一次、写回完成后才发布结果及 HDMI 无欠载。它不是物理 DDR PHY、真实传感器或采集卡验证。

第一张结果耗时 150687472 个 125 MHz 周期，约 1.20550 秒，倒数约 0.830 帧/秒。这是该仿真场景的结果生成速度，不能当作真实鱼眼参数性能、网口完整帧率或上板实测值。当前版本尚不满足实时 1080p30 矫正要求，HDMI 可以重复显示上一完整结果。

## PDS 构建状态

第二轮目录为 `fpga/build/mini_raw8_geometry/native_20261005_104822_986/`。完成综合及布局后，详细布线在 30 分钟运行时限退出（Flow-0232），未产生新位流。输入哈希未变化，布局/映射数据库保存在 `fpga/build/mini_raw8_geometry/route_checkpoint_20261005_104822/`。

随后通过原生 `pnr -input_db_file ... -input_place_db_file ...` 从布局检查点重新布线。续跑目录为 `fpga/build/mini_raw8_geometry/resumed_20261005_112952_987/`，运行时限为 90 分钟，时钟约束不变。PG2L100H 拒绝通用帮助中的 `number_of_router_thread` 选项（Flow-0182），因此采用器件支持的默认路由器。

该轮在 12:57:18 完成布线，PnR 总耗时 1 小时 27 分 25 秒，路由耗时 4909.17 秒。原生 after-hold-fix 报告明确为 **Some Constraints Violated**：

| 检查 | 域 | 最差裕量 ns | 违例端点 |
| --- | --- | ---: | ---: |
| 慢角 setup | ddrphy_sysclk → ddrphy_sysclk | −2.306 | 1436 |
| 快角 setup | 同上 | +1.434 | 0 |
| 慢角 hold | 同上 | −0.011 | 1 |
| 快角 hold | 同上 | −0.001 | 1 |

证据为该运行下的 `route.log`、`place_route/bak/mini_raw8_geometry.prr` 和 `place_route/mini_raw8_geometry_timing_summary_after_hold_fix.txt`。没有生成位流。

本次编排发生错误：PDS 在 Tcl 结束时已执行 PnR，旧内存中的 PowerShell 脚本却再次调用 `-run pnr`。重复运行被终止，但它已清理首次 PnR 的 ADF；备份只留下报告和文本网表，不能当作可导出位流的数据库。独立最终 STA 因此未执行；上述数值是原生路由后的摘要，不冒充独立 STA。实际启动脚本副本与哈希保留在运行目录，`result.json` 保持失败状态。

续跑脚本已改为只执行一次 PnR，缺少 ADF 直接失败；有 ADF 时立即保存至 `routed_snapshot/` 并记录哈希，再对该副本做独立 min/max STA 及位流导出。新运行 `resumed_20261005_130724_081/` 使用相同已放置检查点，开启原生 performance、多角时序和 hold 优化，运行时限 180 分钟。

该轮 PnR 于 14:44:56 完成，总耗时 1 小时 37 分 32 秒；独立 STA 于 14:45:44 完成。数据库已成功保存，运行前后源码输入哈希一致。独立最终报告为 `report_timing/mini_raw8_geometry.rtr`，结果如下：

| 检查 | 域 | 最差裕量 ns | 违例端点 |
| --- | --- | ---: | ---: |
| 慢角 setup | ddrphy_sysclk → ddrphy_sysclk | −2.424 | 2439 |
| 快角 setup | 同上 | +1.449 | 0 |
| 慢角 hold | 同上 | −0.005 | 1 |
| 快角 hold | 同上 | −0.008 | 1 |

最终布线数据库为该运行下的 `routed_snapshot/mini_raw8_geometry_pnr.adf`，SHA-256：
`1C1F3D98AC72D0047F68A0B21871CD65A03E73ED6A8688178B26104C0105E3B2`。

注意：路由中间的 `timing_summary_after_hold_fix.txt` 数字与最终 STA 有差异；验收以独立最终 STA 为准。构建脚本按设计返回失败，`result.json` 中 timing_constraints_met=false、bitstream_generated=false、source_inputs_unchanged=true。

### 已定位的剩余关键路径

对保存的 ADF 另外执行每组最多 100 条路径的只读 STA，证据在 `fpga/build/geometry_routed_path_audit_20261005/`。该操作不重新布线、不修改约束，完成后数据库哈希复核一致。

- 最差 setup：`u_mcu/u_parser/payload[103]` → `u_core/u_geometry/u_config` 的参数索引解码与读回多级选择 → `u_mcu/pending_payload[200]`，共 9 级逻辑；数据逻辑延迟 1.764 ns、布线延迟 8.062 ns，WNS −2.424 ns。
- 展开的 100 条慢角失败 setup 路径中，58 条终点在 MCU 回复/控制侧，42 条终点在矫正配置侧；后者包含 `shadow_epoch`、`shadow_session` 等寄存器的写使能。这不是只给读回值增加一个寄存器就能确认解决的问题，命令合法性判定与原子写入使能也需要分阶段处理。
- 同一条 hold 路径在两角失败：`u_mcu/pending_payload[155]` → `u_mcu/u_tx/saved_payload[155]`，慢角 −0.005 ns、快角 −0.008 ns。需要审查回复队列到发送缓存的实现，并复验最短延迟，不能忽略小负值。
- 本轮几何乘法流水化通过功能回归，但上述结果说明整个 125 MHz 系统仍未闭合。performance 路由未改善最终最差 setup，因此不把再次盲目换种子作为已完成修复。

后续收敛工作应对命令接收/校验、索引解码、参数读回、配置写入与回复入队明确建立流水握手，同时保留 epoch/session 失效、错误回复、重试及帧边界原子切换语义；复跑协议与板级仿真，再重新综合/布线/STA。以上是剩余工作，不是本轮已实现内容。本轮没有新增 multicycle 或宽泛 false-path 来掩盖违例。

只读 PLC 诊断记录在 `fpga/build/geometry_plc_diagnostic_20261005/`。没有真实布线延迟的 PLC 分析不能替代最终布线 STA，也不能用其正 setup 裕量声明收敛。

备用种子 3 的直接映射数据库布局在 DDR 命令 OSERDES 处报 Place-0006，目录为 `fpga/build/mini_raw8_geometry/seed3_20261005_120104_760/`。该尝试没有生成位流，也没有修改 DDR 引脚或专用 I/O 位置来绕过失败；不影响原布局检查点的独立续跑。

综合使用 20832 LUT（31.28%）、25322 寄存器（19.01%）、29 DRM（18.71%）、43 APM（17.92%），锁存器为 0。此前未流水化版为 78 APM。综合估算最差路径已转为 UART 命令解析；最终判断以布线后的 min/max STA 为准。

## 约束覆盖与功能边界

DDR 与矫正域为 125 MHz，摄像头 PCLK 内部预算为 100 MHz，HDMI 和以太网使用既有生成时钟约束；RGMII 继续使用既有 PHY TXID 与板级预算。约束通过表示满足这些输入条件，不表示外部条件已经物理测量。

OV5640 数据、HREF、VSYNC 当前没有经过实测支持的引脚级输入延迟约束。数据手册的 DVP 行帧时序表及 PCLK 上限不足以给出传感器 pad 到 FPGA pad 的数据/时钟偏斜。因此外部 DVP 建立保持、RGMII PCB 偏斜、物理 HDMI 输出与 MCU 接线仍需板测，不能用工具的内部时序结果代替。

当前集成的是 14 字参数、双缓冲查表、帧边界切换的灰度矫正链路。上位机发送 K/D 与仿射参数，FPGA 计算映射；冷启动默认几何旁路。新增 pitch/roll 和 x/y/z 平面补偿运行时开关尚未完成集成，本次位流不宣称支持；`geometry_ray_normalizer.v` 尚未接入顶层。

网口仍发送增强 Bayer RAW8（RENH/v2），不是原始 S0 或矫正结果；HDMI 使用独立灰度结果池。完整 RGB S1/S2/S3、严格同帧证据和实时吞吐仍未验收。普通 HDMI 采集来源身份继续为 null/unverified。

## 重现命令

在本分支工作目录执行：

```powershell
powershell -File fpga/scripts/sim_geometry_mul.ps1
powershell -File fpga/scripts/sim_geometry_chain.ps1
powershell -File fpga/scripts/sim_geometry_board.ps1
powershell -File fpga/scripts/build_mini_raw8_geometry.ps1 -EmitBitstream
```

对于上述已保存且源码哈希匹配的布局检查点，可执行：

```powershell
powershell -File fpga/scripts/resume_geometry_route.ps1 -Checkpoint fpga/build/mini_raw8_geometry/route_checkpoint_20261005_104822
```

构建脚本仅在新鲜的最终 min/max STA 通过、约束对象可解析、构建输入哈希不变时导出同一个 PnR DB 的位流。以上命令均不进行烧录，不要并行启动两个写同一 implementation 目录的 PDS 构建。

参考资料仅只读访问：安装目录的 `ADS_Synthesis_User_Guide.pdf`（属性章节页 70–71）、`Timing_Analyzer_User_Guide.pdf`（DB 与约束加载章节），以及 reference 中匹配 MINI 的 `DS04001_Logos2系列FPGA器件数据手册.pdf`（页 11）和 `OV5640_DataSheet.pdf`（DVP 章节与表 8-5）。没有向参考目录写入文件。
