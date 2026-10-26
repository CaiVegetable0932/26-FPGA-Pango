# 缓存 tag 坐标宽度隔离候选

2026-10-14 21:44–22:03。隔离目录为 `fpga/build/full_integration_20261013/cache_tag_probe_20261014_214406_338740/`。baseline 从当前 D=`delay_20261014_171555/source` 完整复制290项；candidate 同样290项，只有 `rtl/geometry/rgb_tile_cache.sv` 和 `rtl/geometry/geometry_rgb_pipeline.sv` 两项变化。未改 live、D/E/G、主板约束或活动任务；没有完整帧模拟、MAP/PnR、位流或实板动作。单位 compile/SYN 在全部原定差分通过后获授权执行。

## 实际实例与参数边界

冻结 D `rtl/board/video_memory_core.sv:7` 默认为1920×1080、PROJECTIVE=1，`:229` 将 PROJECTIVE 传入 processor。`rtl/geometry/geometry_frame_processor.sv:6` META_BITS 默认616，`:37` pipeline 没有覆盖 tile/SET。`geometry_rgb_pipeline.sv:9–10` 默认 SET_BITS=5、TILE_X_BITS=5/Y=3；`:31` 每像素 TAG_BITS=32，`:60–62` 已将合法帧限定为2..4096，`:89` cache 继承这些参数。cache 原 `:12–13` QUEUE_DEPTH=8/FILL_PIXELS=4；实际 `rtl/memory/geometry_tile_refill.sv:87` 通过X左移5/Y左移3形成32×8起点。实际主板使用32×8 tile，不是16×16。冻结 `config/board.json` 指定MES2L676-100HP-MINI、PG2L100H-6IFBG676，并引用已存在的 `reference/盘古100K200K MINI开发板/1_Demo_document/实验例程说明篇/教程1_盘古MINI系列开发板硬件指导手册_V1.3.pdf`；hardware_verified仍false。

candidate cache 新增 MAX_FRAME_WIDTH/HEIGHT，泛型默认32768。位宽为 `max(1,$clog2(ceil(MAX_FRAME/TILE)))`：

| 实例 | X/Y bits |
|---|---:|
| 主板32×8，MAX4096 | 7 / 9 |
| 16×16，MAX4096 | 8 / 8 |
| 8×32，MAX4096 | 9 / 7 |
| 32×8，MAX4097 | 8 / 10 |
| 16×16，默认MAX32768 | 11 / 11 |
| 32×8，MAX13×11 | 1 / 1 |

仅 tag_x/y 及 query_x/y 缩窄，公共请求 requested_x/y 和 fill_tile_x/y 仍12位，完整整数 tx/ty 参与比较。tag_valid 继续屏蔽未初始化载荷；只在完整256像素且成功LAST时发布。runtime start 先检查实例MAX及公共12位请求可表达的4096 tile跨度，拒绝时不改变旧 width/height/enabled/tag上下文。pipeline 显式传MAX4096，原合法判定不改。SET、queue、数据bank容量、请求长度、四路parity、状态机和吞吐未缩减。

默认32768不是对所有历史参数组合正确性的承诺。例如2×128需14位X tag，但旧public请求只有12位；candidate 在该形状允许宽≤8192并拒绝8193以上，避免截断别名，这是一项明确的泛型合同修复。TILE0/8、8/0不满足四parity bank所需的偶数边长，历史未验证；candidate 在仿真elaboration拒绝。MAX必须2..32768、TILE bits必须1..7且和8；合成若忽略simulation fatal，PARAMETERS_VALID仍禁止frame admission。主板已合法≤4096配置不受这些泛型拒绝改变影响。

## 差分与独立参考

`runs/cache_test_results.json` 共54条compile/run命令全部满足预期：14个paired profile、5个非法参数fatal测试、baseline/candidate各4项原1200向量回归。paired每周期比较 in_ready/frame_ready/out_valid/fill_req_valid/fill_ready、错误/拒绝标志和全部统计；有效输出（含背压时保持）比较samples/a/b/mask/tag，public request valid期间比较完整12位tx/ty；另用独立坐标和像素参考检查每个接受输出。原实现未reset的无效payload没有有效数据合同，不将X填充差异误判为功能差异。

14项覆盖：主板5/3，4/4，3/5，FILL1，MAX4095/4096/4097，MAX13×11的单tile最小向量，全部七种有效tile形状1/7..7/1，默认MAX32768的16×16/32×8，以及2×128的public跨度8192。使用1920×1080和最大尺寸的稀疏高坐标，不生成整帧。覆盖合计包括2×2最低尺寸、35×33部分tile、跨tile四邻域、parity/重复、四way/替换/miss、负坐标/mask0/末像素+1fraction、请求/填充/输出背压、busy start拒绝、drain后新frame、early LAST、中途fill_error、fill_error+LAST和overlong实际LAST。四way定向替换在实际5/3和4/4、3/5等有足够坐标的profile执行；MAX13×11只有一列tile，部分极端形状按可用坐标执行较少同set请求，不宣称每个profile都填满四way。新MAX以上或public无法表达尺寸的预期拒绝单独校验，不宣称其与旧泛型接受行为等价。

实际主板paired结果：134个样本，2589个比较周期，29次请求，queue_peak=8、63次热命中II=1检查；2次busy start和6次非法尺寸拒绝。七种有效形状均queue_peak=8/hot_II=63。原测试每项1200向量；baseline/candidate全stdout及以下metrics逐字一致：

| 原回归 | cycles / misses / bus bytes | duplicates / max stall |
|---|---:|---:|
| 16×16 FILL1 | 13754 / 38 / 26208 | 231 / 1277 |
| 16×16 FILL4 | 4620 / 38 / 26208 | 231 / 333 |
| 32×8 FILL4 | 8489 / 84 / 46400 | 231 / 333 |
| 8×32 FILL4 | 4917 / 42 / 37696 | 231 / 333 |

`runs/pipeline_summary.json` passed=true/source_intact=true：PROJECTIVE=1、实际SET5和616位帧身份，32×8/16×16/8×32各运行identity与整数tile−1平移两段128输出前缀，总768个独立RGB/uv/完整frame-tag/LUT-version检查；每周期全部公开控制/统计及valid载荷相等。三项pair_cycles分别1611/1611/1620。覆盖pre/post Gamma identity LUT、宽/高4097拒绝、每段两次busy START同时改变外部系数/投影/尺寸/身份、首样本四tile、request/fill/output hold。每段通过reset结束synthetic owner，没有宣称frame_done或DDR throughput。非单位projective深度、非零畸变、整帧完成与板级故障没有在本次前缀测试新增验证。

## 官方单位综合结果

官方原目录只读：`E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/ADS_Synthesis_User_Guide.pdf`，SHA256=`9930e586e71fed2faedf239b6af965eda69845f494fd506d2e708cf9f6fed9f0`，印刷p9–10说明compile/SYN及SNR产物；同版 `Pango_Design_Suite_User_Guide.pdf` 印刷p165给 `synthesize -ads -selected_syn_tool_opt 2` Tcl例子。使用该安装版pds_shell，目标PG2L100H/-6/FBG676，与冻结D的实际器件匹配；没有照用示例其他器件。

`native_syn_20261014_220124_403952/result.json` passed=true。baseline/candidate各原生退出0、errors=[]、inputs_intact=true，阶段只compile/SYN，同8ns和选项。两份wrapper都让完整256位输入及424位响应经动态32位serial寄存器写入/观察，包含所有数据、尺寸、mask/tag、ready/error、四bank输出和统计；未常量裁剪公开字段。两wrapper唯一实际配置区别是candidate额外传实例MAX4096，与pipeline相同；均TAG32/SET5/QUEUE8/FILL4/TILE5-3。每项前Windows可用物理内存3,718,344 / 3,357,184 KiB，均高于1GiB。

| 单位SNR | LUT | FF | Distributed RAM | APM | DRM | unique controlsets |
|---|---:|---:|---:|---:|---:|---:|
| baseline | 2831 | 2080 | 781 | 0 | 24 | 55 |
| candidate | 2493 | 1962 | 557 | 0 | 24 | 55 |
| 实际差 | −338 | −118 | −224 | 0 | 0 | 0 |

SNR和controlsets实际SHA、完整Tcl、console、source前后SHA均保留。serial外部端口有未加I/O delay的Timing-4086提示，单位SYN不是整板时序签核；本表也不是整板MAP资源。未据此承诺路由成功或位流可用。

## 来源完整性与剩余工作

`probe_manifest.json`记录原D的完整290项SHA；`evidence.json`再次重算baseline/candidate、D/E/G各290项及live两文件。candidate SHA：cache=`04a409b3ef18fb4631f9c388440c8d66fe89d437a446e6d96c2dda28006b9c06`，pipeline=`c62ba0ae3d03e3b7f17ef36b4fd8360e69e1ab230796c147d36f2e9211f76654`；原D/live cache=`a6613e0a8e7e28e82b61836f0b3782cdbfe7dcaa3363d22a61abb01206acd2b6`，pipeline=`b99f4b26878245b00c8dbf18f2500c9cac4c17981b7353f5817321fb681d061c`。源副本与live在全部测试和单位SYN期间无变更。

单位SYN开始时缓存证据50条命令已通过；随后只追加2/6、6/2两形状的4条Icarus命令，源未改。`cache_test_results_at_launch_reconstructed.json`从最终列表前50条按原Windows文本格式重建，SHA与原生启动时已记录的SHA完全一致；没有修改原生result。当前54条及pipeline证据另存，runner、夹具和结果SHA见evidence。

候选可用于下一次独立冻结组合整板输入。仍需该组合真实整板compile/SYN/MAP、完整路由及routed STA、bitgen和实际板功能验证；本报告只确认已执行的隔离功能差分与单位原生综合。
