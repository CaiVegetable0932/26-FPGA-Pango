# FPGA 资源与布线优化（2026-10-07）

## 验收边界

本轮只优化实现效率，不删除 20 点标记、原图/矫正切换、帧边界配置、
灰度矫正或未叠加的网口 RAW8 数据。不得以减少 LUT、布局估算为正或生成
数据库代替最终快慢角 setup/hold/recovery/removal/min-pulse-width 签核。
未执行烧录、冷启动、实际图像和四类帧率测量。

## 优化依据

第十九轮旧源原生布线/独立 STA 完成，仍有 5 个 slow-setup 失败端点：
核心 -0.423 ns / -0.035 ns（写帧回读比较），-0.006 ns（映射结果 RAM）；
DDR 写数据 -0.259 ns / -0.073 ns。所有 hold 表没有失败端点。
该轮采用 native-free 板级 PCF、seed=5、decongestion=6，未加载额外 DDR
叶位置锁。其 result 的默认 ddr_profile=ten 不表示加载了十叶位置锁。
LUT 为 41143、FF 为 50904；CLMA/CLMS 各约 92% 占用，不能仅按 LUT
约 62% 判断布局空间充裕。旧源未获得时序合格位流。

第十五、十七轮额外 DDR 位置候选的原生子进程已主动停止并保全快照；
中止产生的 Flow-0189 不算自然工具崩溃，也没有最终 STA 结论。

## 正式 RTL 改动

### 缓存标签去冗余

`fpga/rtl/geometry/geometry_window_cache.v` 的 stride=2048、直接索引缓存，
槽索引已确定字地址的低 SLOT_BITS，标签只存剩余高位。默认 1024 槽标签
从 23 位缩为 13 位。64 槽折叠哈希及其它 stride 保留完整标签。
对非常规跨三字窗口显式检查所选右端口的槽身份，防止高标签相同却槽不同。
不改变命中/缺失语义、有效位失效规则、DDR 事务或每拍窗口吞吐。

### 写帧回读分组流水线

`fpga/rtl/geometry/geometry_result_stream_writer.v` 将 256 位完整相等比较
拆成八个 32 位并行比较，保存中间结果；只用有效令牌授权结果，数据寄存器
不加 reset/enable。按安装版 ADS 5.1 属性固定这一寄存器边界。
最终确认沿保留“上一个匹配 beat 或与 done 同拍匹配 beat”的原规则。
帧完成发布延后一拍（125 MHz 下 8 ns），像素入队和 DDR AW/W 时序不变。
这里延后的是发布确认，不是新增整帧队列。

原写帧源码冻结在 `fpga/build/writer_fence_pipeline_20261007_125622_690/golden.v`，
SHA256 `AEA9E0A58449562DA2B83DA554ED845F24E3C014FB43277D7629E7F64528D3E6`。
现有三帧/背压/填充及坏回读用例已通过：
`fpga/build/stream_writer_20261007_125651_868`。新增冻结 golden 周期比较已通过：
528 个真实 64×4 小帧、165085 周期，256 个单 bit 错误分别以 split/coincident
两种回读形式全部拒收；多 valid、前好/当前坏 OR、无 valid、native 写错误及
三个 reset 中断场景通过。ready/AW/W/req 逐周期一致，done 恰延后一拍。
证据见同目录 `WRITER_MITER_REPORT.md` 和 `writer_miter_evidence.json`。
该测试没有覆盖发布间隙抢先 start、X/Z 或小 FIFO 满载，不能宣称完整形式证明。

## 新构建与后续

新的 compile/synthesize/dev_map 已于 13:16:59 在
`fpga/build/mini_raw8_geometry/native_20261007_125934_940` 完成，306 项源无漂移。
原生 map/PCF/源哈希/报告已逐字节保全在 `checkpoint_native_free/`。
随后需要
使用该轮冻结输入重新 PNR 和 min/max STA；旧映射不能配新 RTL 发布。
原图和鱼眼 1080p 全板回归已重新启动，用于检查输出与 RAW8 完整字节。
新综合报告为 41635 LUT、51932 FF、69.5 DRM（非 PNR 资源）。同阶段器件映射
正式对照：旧 native14 = 41283 LUT / 50886 FF / 72.5 DRM；新 native20 =
41275 LUT / 50900 FF / 69.5 DRM。两者 APM 都是 103。因此本轮少 8 LUT、
多 14 FF、少 3 DRM。不能将 RTL 表面位宽减少换算成大量 LUT/FF 节省，也不能
将综合、device-map、PNR 的不同统计直接比较。旧网表 tag RAM 的低位仍存在；
此前“低位已经由 ADS 消除”的推测撤回，整体差值不能单独归因于一个模块。

两种重新执行的全板仿真通过：
`geometry_board_20261007_125949_829`（鱼眼）和
`geometry_board_20261007_130003_257`（原图）。各两完整源帧、两结果帧、
2073600 个有效 HDMI 像素及 4147200 个 RAW8 网络字节；cache hits/misses
与基线相同，首结果周期分别 3292832/3281186，仅多一拍。
这是仿真中的数据/吞吐检查，不能替代实板 30 FPS 测量。

只读旧生成网表的模块内 GTP LUT 实例统计发现，marker overlay 为 5786 LUT、
其中 5237 个 LUT6CARRY；这不是芯片总量或独立模块综合报告。正隔离验证
有界算术/共享阈值的等价面积候选，尚未修改正式 overlay。

此外，标签并入镜像 DRM 空余位宽只作为隔离候选验证，尚未合入。
新综合的 tags 实际推断为六个 1K×13 简单双口 GTP_DRM18K，而不是巨量 FF；
并入镜像 RAM 的候选收益需要重测，不以 13K FF 节省宣传。

compact-tag 的现有 15 组窗口回归和新 20 组逐周期对照已通过。后者核对
1673009 周期、42640 个正常窗口、120 个故障轨迹以及高地址别名、第三字
窗口和 slot 重建不变量，见 `cache_tag_compact_20261007_125611_774/COMPACT_HANDOFF.md`。
首次私有 miter 缺少 queued replay 覆盖而失败；保留该日志，修正刺激节奏后
在新目录全量重跑，未修改正式 cache，也未删除周期比较断言。
## 标记叠加与 packed-tag 已合入

隔离标记候选同版本同顶层综合 6133→3877 LUT（-2256/-36.78%），118 FF 不变。
窄位宽共享半径/倒角阈值替代重复的 32 位 unsized 常数加法；复用 dx/dy，
保留完整距离上界检查，避免低位截断引入别名。Q12 取整保留原 modulo-2^16
规则，含负数、半像素和 signed 极值，不改变字形、颜色、优先级及两拍 HDMI 延迟。
2860061 周期新旧 miter、全部 64 种 size、262144 取整刺激、20000 随机周期、
完整 1080p 光栅以及原 242 帧独立字形 oracle 均通过，见
`overlay_area_20261007_131138/REPORT.md`。这是独立面积结果，非全板最终减少量。

候选首轮词法错误的原始失败日志曾被私有 runner 覆盖，不可恢复；精确初版源
和同编译器复现记录已保存且明确标注 reproduction_not_original。最终 PASS
证据在新目录重新验证，未使用该复现记录冒充原始日志或成功结果。

packed-tag 的独立 15case 标量回归、20case 周期/故障对照通过。主代理随后
使用此前已只读核对的 ADS 5.16 及项目成功模板运行 256/269/279 位 RAM 探测，
三者均为 8 DRM36K、TRUE_DUAL_PORT、6 LUT/0 FF；原生报告在
`cache_tag_packed_20261007_131154_460/main_ram_probe/`。未重试子代理被拒的
官方文档提取，也没有写入官方目录。标签合并不增加镜像数据 RAM 数量，消除
六个独立标签 RAM；tag 提前写入但仍在原 done/fill_applied 沿发布 valid，
忙碌窗口不使用早写 tag，queued A 仍须 replay。

上述两份候选已合入正式源码，旧源与只改注释的 cache 功能文本对应关系保存在
`resource_merge_20261007_1325/merge_identity.json`。当前 formal overlay 为 EE323…，
cache 为 0F3CB…（和被测试 68DD… 仅首部用途注释不同），writer 仍为 7356…。
新的完整 compile/synthesize/dev_map 从
`mini_raw8_geometry/native_20261007_132841_590` 开始，正式全板与相关回归正在重跑。
此刻尚无这轮 PNR/STA、SBIT 或硬件结果，不能复用 native20 的映射发布。

MCU 一位错误分类候选虽有独立 +acc 行为证明，但默认优化仿真差异的确切
根因未证实；本轮暂不合入，正式 MCU 源保持 A0110… 基线。

## 合入后当前源回归与综合

合入正式 overlay 与 packed-tag 后，两种全板模式重新通过仿真：
`geometry_board_20261007_132921_116`（fisheye）和
`geometry_board_20261007_132948_738`（original）均完成 2 个源/结果帧、
2073600 个有效 HDMI 像素、2 个网口帧及 4147200 个逐字节匹配的 RAW8 字节。
首次结果分别为 3292832/3281186 周期；这是 DDR 行为模型中的周期，不是
真实板卡帧率、延迟或 1080p30 实测证明。

15case window、20点/字形、几何链路、UART READ 与实时元数据预译码回归
使用当前源重跑通过。`native_20261007_132841_590/regression_request.json`
记录 18 组回归和 ReplyEquivalence；源审计核对 436 条文件记录。旧 view
预译码清单因包含旧 overlay 哈希被拒，已在
`view_predecode_20261007_134214_089` 重新运行并通过，未给旧证据改写哈希。

同阶段完整综合：native20 为 41635 LUT/51932 FF/69.5 DRM/103 APM，
native21 为 39952 LUT/51926 FF/66.5 DRM/103 APM；减少 1683 LUT、6 FF、
3 DRM，APM 不变。面积降低不等同于 DDR 跨时钟路径已闭合，仍需完整
Device Map、原生 PNR 和 slow/fast 全项 STA，未放宽时钟、IO 预算或例外。

Device Map 同阶段最终数据：native20 41275 LUT/50900 FF/69.5 DRM/103 APM；
native21 39592 LUT/50894 FF/66.5 DRM/103 APM（-1683 LUT，约 -4.08%）。
306 个输入哈希均未变化。新旧映射 PCF 仅第一行 PDS 自动时间戳不同，其余
每一行完全一致，包含 113 个板级端口；未新增 DDR 叶节点位置锁或时序例外。
检查点见 `native_20261007_132841_590/checkpoint_native_free/comparison.json`。

`resumed_20261007_134909_088` 正使用此新检查点、seed=5、decongestion=6
进行一轮原生 PNR；完成后独立全项 STA，失败不生成/发布烧录位流。

独立只读网表审查见 `resource_native21_audit_20261007_135754_579/REPORT.md`：
当前 cache 三份 1024×269-bit 镜像各 8 个 DRM36K，共 24 个，全部为
TRUE_DUAL_PORT；原六份独立 13-bit tags 推断已消失，没有新增 latch。
当前全板综合局部 cache=5101 LUT/2276 DFF、overlay=4141 LUT/102 DFF；
这些是 synth 局部统计，不是 map/PNR 后局部数。隔离 overlay 候选为
3877 LUT/118 FF，和全板局部的输入环境、常量传播及优化不同，故不能将
隔离减少 2256 直接当作全板节省，也不能将差额虚构成 cache 开销。

新增只读资源证据 gate `check_geometry_resource_evidence.ps1` 绑定 116 个
有限输入/日志/元数据、三份正式 RTL 与原始测试矩阵；保存结果及 checker
SHA 均需和重算结果严格相符。PS5.1/7 各 30 项正反测试通过；离线 exporter
增加必填 ResourceEquivalence、前检/转换后复检和发布副本绑定，两版本各
10 项集成测试通过。主代理审读实现与测试并重新执行只读证据验证通过；
测试不执行 PDS、Flash 或硬件操作，不构成新的时序/位流成功证明。

## 本轮最终 PNR/STA（14:28）

`resumed_20261007_134909_088` 原生 PNR 14:26:56 完成，耗时 37分46秒；
全部网络布通。独立 min/max 多角 STA 14:28:27 完成，仍为
Some Constraints Violated。306 项输入未改变；未生成 SBIT/SFC、未烧录。

最终布线资源为 39444 LUT/50897 FF/66.5 DRM/103 APM，CLMA=10566/11675、
CLMS=4483/4975，原生整数利用率均为 91%。LUT 降低并未使 CLM 占用降到
同样比例，不能只用 LUT 百分比代表实际放置和布线余量。

唯一有失败端点的汇总域为 slow ddrphy_sysclk→ddrphy_sysclk setup：
WNS=-0.361 ns，TNS=-19.665 ns，142 个失败端点；fast 同域 +2.690 ns。
slow DDR 写到两组 DQ 为 +1.309/+0.149 ns，fast +3.571/+3.039 ns；
DDR 写 hold slow +0.439/+0.442 ns，fast +0.116/+0.050 ns。
DDR 读第1组 setup slow/fast +1.762/+3.832 ns，hold +0.532/+0.114 ns。
RGMII setup +0.126/+0.143 ns，hold +0.103/+0.115 ns；其它域 setup、
全部 hold/recovery/removal/min-pulse-width 无失败端点。以上均为 native STA，
不代表外部 DVP 接口时序或实际帧率已经测量。

前 10 条报告的最差失败路径均为 u_boot/epoch[0] → u_mcu 的 64-bit
epoch_change 进位比较 → pop/space_available → 几何配置影子存储写 CE。
最差到 shadow_storage[190]/CE（[191]同值），共12级，logic=2.020 ns、
route=5.754 ns（74.016%），clock skew=-0.211 ns。max_path=10 没有列出
全部142端点，故不把前10条共同起点扩称为全部端点的证明。

本轮 DDR 跨时钟旧违例已消失，但核心控制路径未闭合、TNS和失败端点数
比上一轮更差；不能因 WNS绝对值略小或资源量下降就宣称稳定。下一步应
精确优化 epoch flush→队列可用→参数写 CE 的长控制依赖，保留同拍 epoch
变更屏蔽与清空语义；缓存 valid 组合共享仅作为隔离面积候选验证，不用
scrub/epoch缓存替代而引入生命周期或握手变化。最终报告及十张角表诊断
记录在本轮 `stage_report.rtr` 与 `final_timing_diagnostic.json`。
