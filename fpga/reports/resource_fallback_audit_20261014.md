# D 集成资源与保持接口的后备审查（2026-10-14）

本次基线为 `fpga/build/full_integration_20261013/delay_20261014_171555`，目标 PG2L100H / FBG676 / -6，PDS 2022.2-SP6.4 Build146967。初始审查阶段只读取该构建已完成的 SYN/MAP、冻结 RTL、官方资料和既有测试；该阶段没有读取正在写入的 PNR 数据库、修改 live/D source或启动/停止PDS。后续根代理另授权的两个payload隔离短差分与四项单位原生SYN测量，见文末两节。

结论：目前没有可凭静态资源表保证改善布线的改动。可以优先验证两个已有有效性屏障后的内部 payload：PC 分页冻结快照 `status_snapshot`、snapshot 服务内部 `retained_geometry`。它们可保留原覆盖时刻和有效性/复位行为，把数据寄存器从异步 reset+CE 改为 clock-only+CE；不能预报 FF/LUT 或 CLM 收益。公开快照状态不能直接解除 reset。正在运行的物理实现应继续，后备验证不抢占它们。

## 实际资源，不把层级相加

SNR 第60–75行报告 SYN 45,941 LUT（68.98%）、43,362 FF（32.55%）、2,929 个 LUT 作 distributed RAM（14.72%）、125 APM（52.08%）、58 DRM（37.42%）、115 IO。MAP 为45,925 LUT、43,351 FF，RAM/APM/DRM/IO不变。以下均来自同一 SNR 的包含子层级统计；父子行不可相加。

| 层级 | LUT | FF | Distributed RAM | APM | DRM | SNR行 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| core | 34,889 | 31,337 | 2,887 | 125 | 38 | 289 |
| core.fabric | 12,328 | 6,619 | 1,546 | 0 | 0 | 291 |
| core.processor | 11,716 | 9,033 | 1,053 | 114 | 31.5 | 317 |
| core.fabric.frames | 6,352 | 3,880 | 601 | 0 | 0 | 293 |
| core.processor.geometry | 7,872 | 6,701 | 909 | 110 | 30.5 | 318 |
| 厂商DDR顶层 | 4,411 | 5,205 | 42 | 0 | 0 | 127 |
| boot | 3,594 | 3,363 | 0 | 0 | 3 | 274 |
| core.network | 3,585 | 3,565 | 0 | 0 | 2.5 | 307 |
| core.fabric.dma | 3,493 | 644 | 945 | 0 | 0 | 292 |
| core.processor.refill | 2,316 | 1,736 | 0 | 2 | 0 | 368 |
| core.snapshot_connected.snapshots | 1,261 | 4,275 | 0 | 0 | 0 | 378 |

D 的五个 pool 分别为2136/790/324、1807/790/179、1146/592/98、630/853/0、633/855/0（LUT/FF/RAM，SNR294–298行）。单槽已经保留共享 FF payload，多槽 immutable metadata 已使用 LUTRAM；当前排序矩阵已经替代每槽64bit排序比较，不能重复计算已实施的收益。

## 实际控制集合与字段归因

SNR第81–114行：735个控制集合；最大单集合1968。这里是同一 CLK/reset/CE组合中的FF数量，不能当作整条 reset net 的总扇出，也不能仅据此认定物理拥塞根因。`pango_video_system_controlsets.txt` 的实际最大组如下。

| 控制集合 | FF | controlsets行 | 核对 |
| --- | ---: | ---: | --- |
| DDR PHY CP(~ddrphy_rst_n) | 1968 | 143 | 厂商IP，保持 |
| DDR PHY C(~ddrphy_rst_n) | 1899 | 144 | 厂商IP，保持 |
| DDR controller CP(~ddrc_rstn) | 1205 | 140 | 厂商IP，保持 |
| boot C(~core_reset_n), CE(N2726) | 1168 | 861 | status_snapshot1159 + snapshot_operation8 + have_snapshot1 |
| snapshots C(~core_reset_n), CE(N492) | 1125 | 860 | geometry_status736 + s1_status389 |
| refill C(~core_reset_n), CE(N23306) | 768 | 858 | row_even768 |
| refill C(~core_reset_n), CE(N23350) | 768 | 859 | row_odd768 |
| snapshots C(~core_reset_n), CE(N73) | 612 | 853 | 其中retained_geometry544；其余不属于该payload |

字段数量通过 D 的 `pango_video_system_syn.vm` 中实际 GTP_DFF 类型、Q、C、CE逐单元核对。首个 status_snapshot 原生FF在第213878行；全部1159为GTP_DFF_CE、C=N146_0、CE=N2726。首个retained_geometry FF在第1158606行；全部544为GTP_DFF_CE、C=N146_0、CE=N73。公开geometry_status736、s1_status389、result_status391同样有独立异步C。逻辑声明宽度与实际FF数不同，不能把1536位声明当1536个已实现FF。

## 第一后备：boot内部status_snapshot

冻结 `source/rtl/control/pc_video_boot.sv:19,81,110–114`：

- 冷复位清 `have_snapshot`、`snapshot_operation`、state、reply、configured。非0页只有have_snapshot=1且operation匹配才读status_snapshot；否则第110行返回错误11，回复payload已在第98行清零。
- page0第113行同一时钟沿完整覆盖1536bit，置have_snapshot并记录operation；该页的即时reply直接取输入状态，完全不读取旧status_snapshot。
- 后续非0页第114行读冻结值。状态/标志的非阻塞更新让首次可读页发生于全宽覆盖之后。没有对该内部payload的其他RTL读用。
- 保留所有公开输出、原valid/op/state reset、原page0写入条件和UART时序，仅把status_snapshot唯一赋值拆成 `always @(posedge clk)`，并以 `rst_n && page0_capture` 写使能，可保持外部协议与延迟。不要同时拆received/reply、删版本范围、缩减计数或改变命令行为。

原 `fpga/sim/tb_pc_runtime_control.sv:62–67,92–100` 已测试冻结页和跨operation拒绝；它没有中途reset后的非0页、冷复位尚未capture时全部operation的非0页、各种忙态随机差分，不能把既有PASS扩展成完整reset等价验证。解除reset不会自动减少1159个FF；期望是把这1159个FF从C+CE集合移出，是否改善打包/布线必须由后备原生SYN/MAP/PnR测量。

## 第二后备：snapshot内部retained_geometry

冻结 `source/rtl/control/video_snapshot_service.sv:23,55,63,75`：只在接受 `pair_request && pair_request_ready` 时全宽保存544bit，之后仅在首张S1 acquisition发布geometry_status时读。真实 `frame_snapshot_pair.sv:41–47,93–109,117–137` 保持同一reset；pair_ready只能在接受请求、双源acquire、身份检查、copy/drain、seal及WAIT_READY之后从EXPORT输出。因此首次合法读前必有对应请求覆盖；忙态不接受新请求，不会覆写在导出的旧几何。

可只把retained_geometry改为 `always @(posedge clk) if(rst_n && pair_request && pair_request_ready)`；公开geometry_status/s1_status/result_status、metadata、状态机、代数计数与所有valid reset继续保留。fabric_ready=0保持原协调器暂停/无效化行为，不能添加本来没有的“flush时清旧报告”行为。后备差分须包含错误、取消、等待超时、冷复位与中途复位，以及新active参数不改旧快照读回。

## 不推荐直接改的部分

- **公开快照status不能直接删reset。** 服务没有独立published-valid输出；PC0x96/0x97 page0在configured后立即接受，并把输入快照状态读回（pc_video_boot113行）。还未产生快照时，既有合同返回零状态。仅去reset会公开X/旧状态。新添遮罩会增加组合逻辑与新控制扇出，需要另一个完整方案，不属于两处内部payload的最小后备。
- refill两个768bit缓冲在`geometry_tile_refill.sv:80,89,110–111,124–126`有coldreset、每请求清零、虚拟底边行清零和按256bit beat局部写；`fill_rgb`在第63–65行有动态24bit抽取。把它换为DRM可能新增读延迟；去清零需证明所有masked尾/边缘/取消路径。当前没有保持现有外部全接口时序的简单RAM模板改写，先不动。
- DMA已按client拆独立payload/mask LUTRAM（ddr_native_dma.v:87–110），支持客户端并发装载和同时响应消费，且VERIFY_WRITES完整逐字节读回。共享存储/删readback/缩队列可能改变吞吐与publication真实性；不能为布线削弱这些功能。
- 几何纯payload长delay LUTRAM已经实施。其余短链和算术中间值仍有多抽头或运算职责，不能把它们全部当延迟存储再计一次收益。
- tickets、generation、next_order拒绝饱和、累计诊断计数保持现有全宽和语义；不以较窄计数或rollover假设减资源。不添加false path、改变时钟周期、关闭时序门禁。

## 当前安装官方与板卡核对

直接只读查阅 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/ADS_Synthesis_User_Guide.pdf`：印刷p19说明Fanout Guide对CLK、同步/异步reset/set、enable无效，故当前fanout_guide64不会把这些CE/reset集合限制到64；p20说明resource sharing可降低面积但可能降低时序、Minimum Control-set Size把小集合部分控制移到D；§5.16 p93–95支持syn_ramstyle=lut_ram/registers/block_ram，并给出无payload reset的时钟写、注册读模板；no_rw_check有RTL/综合不一致风险，不能随意使用；§5.17 p95–96只提供集合优化规则，不保证面积或布线；§5.19 p103–104是shift-register模板，与两个内部hold payload不同。它们都不构成取消有效性/reset职责的授权。

只读查阅匹配`reference/盘古100K200K MINI开发板/1_Demo_document/实验例程说明篇/教程1_盘古MINI系列开发板硬件指导手册_V1.3.pdf`：p6器件PG2L100H(200H)-6IFBG676，p8为单路千兆网及唯一HDMI输出；p11的APM表值740与厂商器件数据手册不一致，容量采用`4_IC_datasheet/FPGA/DS04001_Logos2系列FPGA器件数据手册.pdf` p10以及本次PDS识别的240 APM。该数据手册p10–11说明只有CLMS支持distributed RAM，因此总LUT利用率不是具体CLMA/CLMS打包与路由可行性的证明。

## 冻结证据身份

| 文件（D构建相对路径） | SHA256 |
| --- | --- |
| synthesize/pango_video_system.snr | 1800e36aed8b26f90c600d889bd7dc7e8c2c14a6f688699e79cab7faf4ab5f18 |
| synthesize/pango_video_system_controlsets.txt | 0904a5932412a9666ca57ade6bdd57d32aed5ca5de283aae43142f70e4316ff1 |
| synthesize/pango_video_system_syn.vm | ec4ddaf657ed4647931dd43475fc03e8ef971c51f31e05d7042704d6fd1b8739 |
| source/rtl/control/pc_video_boot.sv | 663a237b8b6a68848da1751744af5717fd610b547bf399e575c27919c354ecb8 |
| source/rtl/control/video_snapshot_service.sv | 0d0e040614d3c90a0154c0c732a771c77148fe791ba15eed404cc9f9042b6639 |
| source/rtl/memory/frame_snapshot_pair.sv | 120ef0e1e1381731ea80da58ec12e943fb70744e682042561845ac03e5b84969 |

## 隔离候选短差分补充

根代理另授权的两个最小候选位于 `fpga/build/full_integration_20261013/reset_payload_20261014_180833_125001`。生成器为 `fpga/scripts/prepare_reset_payload_probe.py`；原模块和端口保持，另生成仅module改名的comparison副本用于同一刺激驱动两实例。未改live或D冻结来源，未启动PDS/整板/全帧模型，未停止任何任务。

| 正式接口候选 | 实际SHA256 | 变化 |
| --- | --- | --- |
| candidate_pc_video_boot.sv | efeaeb88d794eb0889c98b79af10404dfaa74cf74fbc357f4d6ad38ea69a8b85 | 仅内部status_snapshot移出reset、保持page0完整覆盖时刻 |
| candidate_video_snapshot_service.sv | f6c529fa128f595a2ec30e4ef7dfce4f7a9a84217ec05157512919e135184a81 | 仅内部retained_geometry移出reset、保持接受请求时完整覆盖 |

**PC 4态差分实际PASS。** `pc_tb.sv`/`pc_verify.py`/`pc_result.json`及编译运行日志：332,580个周期逐周期比较全部903个外部输出位，无mask，无force，外部任一X/Z均fatal；53完整回复、6完整capture、217,499 UART自然忙周期、3次reset。覆盖0x90/95/96/97冷复位未capture的非0页拒绝、每种operation全部合法页、越界/跨operation拒绝、UARTbusy期间输入状态变化、正常/busy/非法mode、有效/CRC错/非正焦距geometry、正常/busy snapshot请求，以及TRANSMIT和80字节COLLECT中reset后重新boot/非0页拒绝。候选内部status_snapshot冷启动X与全宽capture后不含X均有断言。编译/运行退出0，输入前后SHA完整，comparison与候选唯一差异是模块名。

**Snapshot 4态差分实际PASS。** `snapshot_probe.py`生成`tb_snapshot_payload_equivalence.sv`，真实service/pair/copy/reader RTL加有界响应fixture；351周期、348次每周期全29个输出端口比较、9次请求、29个DMA请求、1个cleanup取消观测、21个输出字节。包含身份不配对、copy读错误触发目的帧cancel、acquire超时、acquire前fabric_ready隔离、busy请求和后台geometry变化、每个544bit实体全部17word变化、3个成功完整双图导出、byte背压、mid-copy joint reset、正在导出时net_cancel并drain、WAIT发表时reset、导出后的旧geometry读回。候选retained_geometry第一次接受请求前内部X有断言，而公开三个status为确知零。每周期全部外部输出包含无效payload仍严格4态比较且X/Z fatal。编译/运行退出0，来源前后SHA完整，comparison与候选只有模块名差异。

首两次snapshot台架编译分别遇到Icarus动态索引struct数组字段断言，以及struct member part-select赋值不支持；保留`*_attempt1/2`结果/日志，改为静态命名的完整packed字段响应，候选未改。最终编译只有两个原版/候选共同的row_bytes常量宽度警告（64到32bits）；未为此修改依赖RTL。

以上是有限刺激的RTL外部等价证据，不是形式穷尽证明：PC串口以12.5Mbaud加速；snapshot使用WIDTH=1、HEIGHT=1的模块级有界协议fixture，未建真实DDR/整板ownership模型；不验证物理reset传播、模拟电气或硬件。所有时钟、外层协议和full-width计数不变。基于D原生网表，两个候选涉及1159+544=1703个当前带异步C的内部payload FF；拆分仅有机会减少这些异步C负载，`rst_n`仍参与同步写使能，可能形成新的CE组合，**不能说已减少控制集合、FF数、LUT数或解决拥塞**。追加单位SYN实测见下节；尚未冻结整板启用这两项或重跑完整功能/报文/恢复模型与MAP/PnR。

## 根代理追加授权的单位原生SYN（18:25–18:28）

四项顺序执行，`native_synthesis_probe.py`及实际执行副本均已保存；目录为上节隔离目录下`native_syn_20261014_182559_316373`。统一PG2L100H-6/FBG676，直接以原模块为top，默认参数未改；所有数据输入与所有输出端口保留动态/可观察，没有常量wrapper或删场景。每对8ns clock和原型reset SYN诊断约束完全同字节，依赖完全同字节，选项均为 `synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2`。关闭IO插入是两项宽端口诊断共同设置，并非真实板卡布线设置。

| 单位top/版本 | LUT | FF | LUT RAM | DRM | APM | controlsets | 最大单组FF |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| pc_video_boot original | 3672 | 3742 | 0 | 3 | 0 | 39 | 1545 |
| pc_video_boot candidate | 3694 | 3742 | 0 | 3 | 0 | 40 | 1536 |
| video_snapshot_service original | 2272 | 5830 | 0 | 0 | 0 | 29 | 1385 |
| video_snapshot_service candidate | 2273 | 5830 | 0 | 0 | 0 | 30 | 1385 |

**结果没有面积节省：PC增加22 LUT、snapshot增加1 LUT，FF/RAM均不变，两者分别增加1控制集合。** 所有四项原生进程自然退出0、E错误为空、latch=0，来源完整；没有dev_map/PnR/bitgen。会话15089自然关闭，没有手动停止任何流程。`collect_native_synthesis_identity.py`另核对每个job全部依赖对照短差分冻结清单、原/候选完整接口声明一致、每对约束/依赖一致、原生报告实际SHA一致，最终`result.json` PASS同时要求source_probe_intact；保留原runner结果`result_native_raw.json`。

实际原生primitive变化：PC单位status_snapshot全1536bit为 `GTP_DFF_CE(C=N296, CE=N2726)` → `GTP_DFF_E(CE=N874)`；have_snapshot1+snapshot_operation8仍为独立异步C的GTP_DFF_CE。原版同集合1545分成候选1536个无C payload FF和9个带C控制FF。snapshot retained_geometry全544bit为 `GTP_DFF_CE(C=N61, CE=N73)` → `GTP_DFF_E(CE=N245)`；公开geometry_status737、s1_status648、result_status648个FF的异步C保持。candidate最大1385组仍来自公开geometry_status+s1_status。

从实际全层级primitive数相加：PC异步C pin负载3696→2160（−1536），CE pin负载3724→3724；snapshot异步C pin负载5827→5283（−544），CE pin负载5806→5806。这是单位综合网表的pin数量变化，不能当作单条net扇出下降值或整板变化。新的CE包含rst_n条件，官方fanout_guide对CE/reset无效，不能据此保证任何最大fanout或打包改善。

单位top的状态字段完全动态，与D整板的常量/死字段裁剪不同：例如PC单位status_snapshot为1536 FF而D实际为1159；snapshot单位公开status保留更多动态字段。未约束的宽数据端口在SYN中报Timing-4086并作组合输入；本测量不提供板级输入到输出时序、min/max STA或实际reset电气结论。没有依据这两个负面积delta创建整板候选，更没有把单位数据加减为整板资源或布线收益。本次未停止或变动任何当前物理实现；如未来考虑仅改善reset打包，仍需独立完整板级证据，不能靠本报告宣称已经解决拥塞。
