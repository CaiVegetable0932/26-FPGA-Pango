# Fabric 固定客户端索引仲裁优化（2026-10-21）

## 根据现有网表选择优化点

基线 `build/full_integration_20261013/board_20261021_181119_187360/synthesize/pango_video_system.snr`：整板60041 LUT、59603 FF；core层累计40791 LUT，其中自身逻辑3808；fabric累计7235 LUT，其中自身1866、DMA2170、frame pool合计3199。

同步查看该目录 `pango_video_system_syn.vm`，source_geometry/source_affine/source_camera_version/source_tone_generation 已直接映射为 GTP_DFF_CE/PE，D直接接 admitted_*，每slot共享CE。将这些数组写形式改为显式slot并无网表证据支持明显收益，所以本次没有修改core sidecar。

## 实施变化

只改 `rtl/memory/frame_memory_fabric.sv` 的round-robin组合选取：原实现每bank、每候选按 `(rr+off)%N` 动态读取state/bank/done；现在固定客户端索引，先扫描index>=rr，再扫描index<rr。保持第一个符合条件的客户端、每bank最多一个选择、全部ownership/cancel/verified条件和原有寄存/完成握手边界。未改DDR接口、银行/消费者定义、帧池生命周期、吞吐参数或时钟。

## 已执行回归

- 所有N=1..8、合法rr及eligible mask共3586组选择顺序穷举相同：`build/fabric_static_rr_20261021_190854/order_equivalence.json`。
- 六client真实native-memory-model：Verilator `FRAME_MEMORY_FABRIC_PASS checks=33`，`build/fabric_rr_verilator_20261021_191124/result.json`。
- 真实core HISTORY：`build/full_integration_20261013/verilator_20261021_190917_631033/result.json` PASS；保留实际历史DMA、历史像素、色彩失效、坏帧间隔、关闭释放检查。
- 最新core控制：`build/full_integration_20261013/verilator_20261021_191553_650955/result.json` PASS。
- Windows Icarus fabric编译曾以0xC0000005无诊断退出，失败保留 `sim_20261021_190854_898500`；未将其写成通过。上述Verilator冻结输入回归实际通过。

## 成对原生测量

统一脚本 `scripts/probe_fabric_round_robin.py`：默认仅准备；显式 `--run` 才通过现有route_supervisor共享锁执行生成/SYN，不启动PnR或位流。已准备 `build/fabric_rr_probe_20261021_191534_838556`，其中baseline/current除fabric RTL外共同输入逐字节一致。参数均为generic默认 N=6、BANK_TXNS=8、BOARD_CLIENT_LIMITS=0；8ns、fanout64、resource_sharing=false、禁用IO插入等选项相同。这是隔离单元对照，不能直接等同板级已绑常量参数的节省量。

准备时未启动native；等其他代理正在运行的原生工作结束后再按协调执行：

`python fpga/scripts/probe_fabric_round_robin.py --prepared fpga/build/fabric_rr_probe_20261021_191534_838556 --run`

本报告此时没有新的native资源节省数字；待两侧SYN及哈希闭包完成后以该probe的result.json量化。不得凭代码样式变化承诺减少几千LUT。

## ADS Resource Sharing 官方证据

只读安装资料 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/ADS_Synthesis_User_Guide.pdf`：

- 物理PDF页21（纸面20）：Resource Sharing默认启用，主要合并加法器、减法器、乘法器，优化面积但可能降低时序。
- 物理PDF页52（纸面51）：`synthesize -ads -resource_sharing true/false`，true执行共享、false不执行。
- 同页将Retiming/Pipelining列为独立选项；不能把resource_sharing解释成自动retiming或所有branch-mux都会被合并。
- 在该手册及 `ADS_Language_Support_Reference_Manual.pdf` 未找到官方确认的per-module共享属性。本次未猜测或引入属性。
- `Pango_Design_Suite_User_Guide.pdf` PDF页98的英文Resource Sharing说明属于Synplify配置章节，不扩展为ADS承诺。

全板开启共享应作为同源受控实验，保持功能和约束并重新验证资源与STA；此选项本身不能替代时序签核。本次没有修改官方目录、历史冻结工程或其他native进程。

## 实际探针结局：主动取消，未得到资源对照

队列释放后确实启动该冻结探针：baseline工程生成成功，后续compile仍在Saving design to DB，子进程CPU持续增长。父代理为优先完成最终整板SYN/MAP要求停止本次generic探针。核对父PID78708/子PID74112的完整命令均指向本probe baseline后，仅结束该owned进程树；未写共享regional stop，未碰其他native进程。supervisor正常收尾、锁已释放。

`build/fabric_rr_probe_20261021_191534_838556/result.json`保留passed=false、baseline synthesize阶段返回1/390.641s、inputs_intact=true；`cancellation.json`记录主动停止原因及核对的进程。current隔离组没有启动。没有新的隔离SYN资源节省数字，不能把主动取消包装成通过或综合功能错误。Fabric实际资源应看父代理接续的最终整板同源层级报告；此前功能回归和3586组仲裁顺序等价证据仍有效。
