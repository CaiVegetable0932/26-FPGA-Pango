> 2026-11-01 GH2异机布线发布分支：本分支根fpga硬件源码为已验证GH2，完整327冻结输入及MAP在fpga/release/gray_GH2_20261101。用户授权外部计算机按GH2外部计算机布线与监控交接_20261101.md启动一次有界PnR+min/max STA；须使用PDS2022.2-SP6.4 build146967、PG2L100H/-6/FBG676。仅portable_gh2.py --audit/--prepare/--run创建并消费目标机新scope，从新MAP重新布局，不输入任何旧PLC，不恢复DE路由迭代。原生180/主机每阶段185分钟及5轮停滞规则，无GUI要求，禁止位流/下载。旧根config中的本机scope已关闭；仓库历史build/报告与下方live=DE描述均为历史，不是本分支的启动指令。精确运行目录从fpga/build/portable_gh2/dispatch.json读取，失败不自动重启；实际签核需完整PRR/routed DB与真实min/max STA。外机原DE任务由用户独立管理，不自动操作。

> 2026-11-01 12:48 GH2的2022验证完成：MAP board_postsyn_20261101_124125_148426原生exit0/300.640秒、外层12:46:46 exit0，独立终审通过。实际37334LUT/41380FF/154APM/75.5DRM/1131distRAM，较DE−258LUT/−580FF/+4DRM/−144distRAM；较H2+123LUT/+3FF。同VM4×72SDP/读所有权FSM与CE19/24/11/15成立，10SCF/CCR33/CDC及全时钟对复核通过；processing估计+.787ns、DDR+.094ns，原hold及53/94未约束诊断仍保留。最终gh2_integration_20261101/final_review_20261101/final_review.json。原native/state的停审保留，不能重启；map_continuation状态为已完成待独立审阅的历史驱动状态，最终证明优先。live310/DE包不变，无PnR/scope/promote/位流/推送；报告GH2组合版2022工具链验证完成_20261101.md。

> 2026-11-01 12:41 GH2回到2022继续：用户选择继续22工具链。实际GH2 VM的1721344合法FSM、4×72SDP/288输出/所有权CE与四组19/24/11/15使能通过，5故障注入拒绝/纯改名正例通过；新证据gh2_integration_20261101/post_syn_review_20261101/review.json。旧审查器中间网名白名单造成停审，原327源/20脚本/旧状态不改。12:41:07仅一次Hidden启动evaluate_gh2_map_only.py --run，MAP15续board_20261101_103105_502401，不重SYN；精确map_continuation_20261101/state.json，wrapper73628仅身份线索。禁止重复启动/改绑定输入。终结用finalize_gh2_map_continuation.py独立审查，无自动PnR/promote/scope/位流/推送；DE包及live保持。

> 2026-11-01 12:22 PDS2025 HDMI兼容性定位：同源最小PG2L100H/-6/FBG676、N21/N22、3.3V/TMDS探针在2022 SYN/MAP exit0、2025.2 build211867 SYN exit1/8错误；无PnR。新版100H目标四份IO规则删除TMDS，旧版支持；MINI手册L5固定3.3V，不能改2.5/LVDS或移植200H配置、覆盖安装库。官方替代/补丁尚未找到，不称修复。可见CIM无PDS、锁释放。问题包fpga/release/packages/PG2L100H_PDS2025_TMDS_reproducer_20261101.zip，CRC/全部SHA通过；报告fpga/reports/PG2L100H_PDS2025_TMDS兼容性定位_20261101.md。保留失败与原设计/DE包；旧GH2 SYN仍待N3905网表语义审核，无自动重跑或MAP/PnR队列。

> 2026-11-01 12:14 PDS2025测试终结：整板gh2_board于12:03:46原生FAILED/exit1（180.484秒，非超时），SYN约束检查32错误，集中8个HDMI口3.3V/TMDS/NONE/drive5与新版GTP电气规则不兼容；无SYN ADF/MAP/PnR。327源完整，可见CIM无PDS/锁释放。外层launch_exit0只是脚本写完状态，不能当成功；看state/native_result。不得直接改为2.5V或删约束绕过，须核对新版原语与板卡。原证据/DE/live保持，勿重跑旧--run。报告PDS2025版GH2测试启动_20261101.md末节。

> 2026-11-01 PDS2025测试授权：用户允许使用E:/PDS_/pango/PDS_2025.2-ads/bin/pds.exe；批处理官方同目录pds_shell.exe实测2025.2 build211867。PG2L100H/-6/FBG676小工程SYN/MAP正常exit0。12:00:40首次启动隔离GH2整板SYN45，工程fpga/build/pds2025_qualification_20261101/gh2_board，state.json精确状态，wrapper70996仅线索；327源同GH2，保留原IP、不导入旧MAP/PLC，禁止重复--run和改活动源。新版本SYN完成后必须实际RAM/FSM/CE与约束审核，尚无自动MAP/PnR/scope/位流/promote。旧2022 GH2已10:59综合正常结束，因N3905谓词审查停审，原证据保留。报告fpga/reports/PDS2025版GH2测试启动_20261101.md。

> 2026-11-01 10:31 GH2原生启动：新完整1080p10:29:40通过3新5重复/16588800像素/0欠流与排空旧帧；功能证明b2b3e35a78c0532e479799a5d4bbf165d4f588234012b566b76ab17bb775390e。10:30:55首次Hidden启动一次SYN45→实际RAM/FSM/CE门禁→MAP15，精确SYN board_20261101_103105_502401，动态gh2_integration_20261101/native/state.json，wrapper24464/driver15384仅线索。native_dispatch_claim已消费，禁止重复--run或改327源/20绑定脚本/功能证据；未知网表停审，不重SYN。无自动PnR/promote/scope/位流/推送，DE/live保持不变。详情GH2组合优化实施与验证_20261101.md末节。

> 2026-11-01 GH2新授权：用户确认外机十小时日志暂不能同步，要求先按可能方向更新。已精确组合G参数bank与H2 owned-read/CDC形成独立gh2_integration_20261101/candidate，327源SHA65f8ad8e8fa86b5169c15d3ec3b0549a6ba938ce0544099515c1d3f1d564333f，相对DE仅3文件。新完整1080p于10:17:54启动，精确verilator_20261101_101757_763943，状态gh2_integration_20261101/full_video/state.json，wrapper63444仅线索；不重复运行或改活动源。旧G/H2专项按精确依赖复用，新视频须重新通过后才一次SYN45→实际RAM/FSM及CE门禁→MAP15；未知停审，不借父版证明。主设计/外机DE包不变，无自动PnR/promote/scope/位流/推送。旧de-g已删除，不视为新组合验证。报告fpga/reports/GH2组合优化实施与验证_20261101.md。

> 2026-11-01 H2验证终结：MAP board_postsyn_20261101_100252_983428于10:06:58外层退出0，原生240.578秒exit0，锁释放/CIM无PDS。功能、新1080p、327源、真实4×72SDP及跨层FSM、SYN/MAP与独立终审完成；最终write_cdc_owned_read_20261031/final_review_20261101/final_review.json。资源37211LUT/41377FF/154APM/75.5DRM/1131distRAM，较DE−381LUT/−583FF/+4DRM/−144distRAM。processing估计+.790ns、DDR+.083ns（DE+.094）；原有DDR hold/53输入94输出未约束诊断保留，SYN fanout告警842→862次单列，MAP告警同DE、10SCF/CCR33一致。无routed DB/真实STA，不称布通。G独立未组合，H2未promote/PnR/scope；310项live和DE ZIP原哈希不变。旧SYN_GATE_NEEDS_REVIEW及MAP待审状态保留，勿重跑。报告fpga/reports/H2结果写CDC优化验证完成_20261101.md；本轮完成并结束de-g跟进。

> 2026-11-01 10:02 H2继续MAP：实际跨层谓词守卫及1721344种合法状态/输入转移审核通过，3故障注入均拒绝；证明范围为FSM编码和RAM读所有权，不冒充整DDR仲裁等价。原SYN/门禁停审记录保留。10:02:49独立一次MAP15续原SYN，状态write_cdc_owned_read_20261031/map_continuation_20261101/state.json，wrapper62764仅线索，勿重SYN/MAP或改活动输入。真实证据见post_syn_review/fsm_semantics_review.json及DE长时停滞后优化实施_20261101.md末节。尚未PnR/promote，外机DE不变。

> 2026-11-01 09:46 H2综合终结：board_20261101_092202_938635原生exit0零错误、327源一致、CCR33、锁释放/CIM无PDS。外层SYN_GATE_NEEDS_REVIEW/exit1是网表门禁停审，勿重SYN或--run。post_syn_review/topology_review.json证明4×72SDP、288输出、无word0/read_q FF、双域时钟及CE码2/3；尚未完成跨层FSM语义，N254/N588等谓词被移到parent/fabric，叶级审查不能放行。无MAP。详情DE长时停滞后优化实施_20261101.md末节，de-g已改为有界语义审核；真证明通过才续一次MAP15，不改冻结源/外机DE、不自动PnR/promote。

> 2026-11-01 09:27继续DE优化：用户反馈外机DE十小时未布通6600～7800往返，要求继续基于DE优化；不操作外机任务或交付包。H2新视频已于昨晚22:55通过，本次复核538case/3199beat/180立即复用、3新5重复/16588800像素/0欠流及327源，修复审核脚本CRLF/LF误判，冻结源不变。09:21:58首次启动H2 SYN45，精确board_20261101_092202_938635，write_cdc_owned_read_20261031/native/state.json，wrapper45912/driver28324仅身份线索。禁止重启/改活动输入。门禁新增强制FSM语义独立审核停点，不能凭位名认定编码；audit_h2_fsm_semantics.py已用旧单元真实VM及3故障注入验证，实际H2整板尚待。SYN后须真实RAM拓扑及FSM两证明通过，才可独立延续一次MAP15，不重SYN，不自动PnR/promote。G保持独立已验证候选，未形成G+H2。报告fpga/reports/DE长时停滞后优化实施_20261101.md；de-g已绑定新任务有界跟进。

> 2026-10-31 22:55 H修正：H1板级SYN因旧read_q约束对象消失而失败，无MAP；单元原生探针证明4个72位SDP DRM，但CEB恒1，官方RAM资料不允许据“无效输出不消费”忽略同址跨时钟读写。H1不签核。独立H2仅在M_LOAD/M_SEND持有完整事务时读RAM，327冻结源仅dma_write_cdc和processing_cdc两文件不同（清单9f25508ac4ad4bff29c1d30cc1a42121b92431024dec325e6b3cb6d1d7cda80f）；后者只移除已失效read_q两条命令，其余原样。538场景/3199beat/180次立即复用及所有权断言通过，新1080p精确verilator_20261031_224825_336708仍验证中。仅新视频与功能审查通过后可一次SYN45/MAP15；evaluate_h2_candidate.py强制真实整板RAM/CE所有权网表审查通过才进入MAP，未知编码停审，禁止用单元探针替代。H2状态write_cdc_owned_read_20261031/full_video/state.json；未启动H2原生。G已验证、外机DE包和live均不变。de-g已更新为H2有界跟进。

> 2026-10-31 22:36结构优化：G已22:26正常完成SYN/MAP（board_postsyn_20261031_222445_610722），37606LUT/41965FF/154APM/71.5DRM/1275distRAM，较DE+14LUT/+5FF；processing综合setup+.787ns。实际SYN四组CE已拆19/24/11/15支，CE最大32；reference一支含其它消费端总34，上游bank内最大62，不能称全局fanout≤32。10SCF/CCR33与CDC通过，未PnR。H单读口结果写CDC候选完成538场景3199beat及新完整1080p（verilator_20261031_222305_281121，3新5重复/16588800像素/0欠流），以DE为父只改dma_write_cdc。H已22:33:22一次启动SYN45/MAP15，精确write_cdc_single_read_20261031/native/state.json，SYN board_20261031_223325_197644；wrapper11028/driver14400仅线索。不可改H327冻结源、driver或重复启动。DE包用户已交外机，本机保持不变；G/H尚未组合或提升live。参数模板route_parameter_trials_20261031只离线，保留chain256及同MAP seed11单变量，pin cost300/decon2保持。de-g已转H每10分钟有界核验，H结构/CDC与原生评估完成后删除。总览fpga/reports/G与H结构优化及布线参数进展_20261031.md。

> 2026-10-31 22:17最新进展与授权：DE已22:03:41原生90分钟超时，第106轮剩11329/99073，无routed DB/STA，锁释放且scope关闭。327源/全部scope输入完整，DE包fpga/release/packages/gray_DE_portable_20261031.zip于22:12完成离线audit/ZIP CRC/全部SHA，SHA=faa660291636078e76e18fb3cd152cf11495793627a2bbd18cc8b5e8bbf49b83；交接fpga/reports/DE终结后异机布线交接_20261031.md。用户确认已交外部电脑长时布线，要求本机继续设计/参数优化；禁止改该包及其工具副本。G已22:14一次启动SYN/MAP（不是PnR），精确状态parameter_ce_20261031/G_integration/native/state.json，SYN board_20261031_221413_864314，MAP动态读取；wrapper35460/driver22892仅身份线索。G327冻结源、driver保持不变，不重启。后续独立候选及参数模板不得并入active/live或生成新scope；G实际CE复制须审网表。de-g改为每10分钟有界核验G，完成后删除，不再重复DE打包。

> 2026-10-31 21:46准备收尾：G新完整1080p已通过（verilator_20261031_213226_828962，3新5重复/16588800像素/0欠流，排空与旧帧保持通过）；327源与功能门禁复核通过，live bank仍是DE。报告fpga/reports/G参数使能局部化整机功能验证_20261031.md。G未SYN/MAP。DE在21:41完成80轮剩13284/99073仍运行，活动327源及scope复核一致。移机工具21项、终结门禁12项离线测试通过；真实包未生成。定时跟进de-g已创建，22:08首次核查，实际DE退出后先审计/封装交付，再评估G；不得拿日历时间当终结证据，不得重复启动或复用scope。

> 2026-10-31 21:39后续授权与准备：用户要求继续设计/参数优化，DE达上限结束后释放供另一台电脑布线。保持当前DE不变。G参数CE32已完成双宽度80048次及reference/UART专项，新完整1080p见parameter_ce_20261031/G_integration/state.json（verilator_20261031_213226_828962），当时仍运行。独立portable_de/resume_portable_de/portable_de_readiness工具21项离线测试通过，仅准备，不曾启动新PDS或scope。终结入口audit_de_terminal.py、package_de_portable.py --package须见实际退出及锁释放后才封装；计划ZIP fpga/release/packages/gray_DE_portable_20261031.zip，产物未生成前不得称已释放。PLC重路由不恢复中断迭代；提供baseline链长500与chain256单变量试验，180/185分钟及既有停滞规则，256收益未证明。先完成DE封装，再可用evaluate_g_candidate.py --run做独立SYN/MAP（功能证明与release_review门禁），不自动promote/PnR/位流/下载。若DE实际布通先审真实min/max STA并交付，不为等G耽误。详情fpga/reports/DE终结交付与G验证计划_20261031.md。

> 2026-10-31 21:15优化与状态：DE仍正常详细布线，约42分钟完成第49轮，剩18207/99073；尚无routed DB/STA。21:14核查327冻结源完整、310项live硬件匹配DE，禁止改活动输入。另在fpga/experiments/parameter_ce_20261031完成G参数bank使能局部化候选（shadow写入/active提交syn_maxfan=32，零新增周期）；512/544两宽度共80048次四态比较通过，但未SYN/MAP/PnR、未合入live、无自动native队列或新scope。官方属性不适用于异步复位，未改复位。DE若先布通应优先交付，不等待实验。报告fpga/reports/参数使能局部化候选与DE进展_20261031.md。

> 2026-10-31 DE物理验证已启动：用户审查优化目标后明确要求“启动验证”。唯一新工程gray_DE_verified_pnr_20261031_203121于20:33启动，精确resume_20261031_203306_116606，指针fpga/build/DE_optimization_20261031/route_handoff.json。327源/DE MAP/约束/脚本哈希与独立预审通过，从DE MAP重新布局，未输入旧PLC。原生90分钟/主机每阶段95分钟，复用既有停滞规则，布通后自动min/max STA，禁止位流/下载；无GUI要求。worker62060、native父66464/子63376仅身份线索，须结合创建时间/命令核对。启动时首次GP布局，未布通。不要再次prepare/launch，不改活动冻结源，不并入boot F。后台监督器每30秒记录，未创建Codex定时唤醒。交接fpga/reports/DE版布线启动与监控_20261031.md。下方“未启动”均为历史阶段。

> 2026-10-31 DE优化完成并提升主设计：BE布线已于18:35原生超时（第33轮剩27728/100693），无routed DB/STA，scope关闭，18:40审核自动任务已删除。用户随后要求继续优化。DE只将BE solver替换为D本地mount直读实现，保留E reader及CDC修正；功能证明、SYN/MAP和独立约束/网表核验通过。MAP为board_postsyn_20261031_201436_865573，37592 LUT/41960 FF/154 APM/71.5 DRM/1275分布式RAM，相对BE减少327 LUT/297 FF、增加16分布式RAM，processing综合setup+0.790ns、DDR+0.094ns不退化。新增板级灰度UART及solver→geometry集成通过；完整1080p证明按全部已例化视频RTL不变复用，不能声称视频顶层覆盖solver。20:19按精确验证字节提升live solver，310硬件源匹配DE，记录fpga/build/DE_optimization_20261031/promotion.json；冻结327源及原生状态在同目录candidate和native/state.json。DDR hold仍需真实PnR min/max STA，验证完成当时未建立新scope、未启动PnR/位流。不得将旧PREPARED记录当作待启动任务。boot页选择局部化F在独立实验完成板级/通用协议仿真及复核，尚无native收益证据，未合入主设计。详情fpga/reports/DE组合优化验证_20261031.md、boot页选择局部化候选F_20261031.md。下方BE及C/D未合入记录均为历史阶段。

> 2026-10-31 外部布线交接（历史启动前快照）：用户要求提交选定设计并交接，明确“不要求使用图形化审批”。已选BE＋CDC修正，准备唯一gray_BE_verified_pnr_20261031_165200，90分钟原生/95分钟主机，仅一次PnR及min/max STA，无位流/下载；当时PREPARED_NOT_LAUNCHED。交接fpga/reports/当前组合版外部布线监控交接_20261031.md，精确指针fpga/build/verification_20261031/route_handoff.json。外部智能体用launch_verified_be_route.py默认预检、--launch一次启动；不要重跑prepare、复用旧scope或擅自并入C/D。当前仅选定已完成整机验证的集成候选，未声称物理最优。旧GUI审批要求被本次用户指令取消。

> 2026-10-31 当前组合验证完成：BE＋精确CDC修正的专项、完整1080p、SYN/MAP和独立约束核验完成。最终MAP为board_postsyn_20261031_163922_756965：37919 LUT/42257 FF/154 APM/71.5 DRM，相对已提交基线MAP减少356 LUT/375 FF；processing综合setup+0.790ns。327项冻结源与当前RTL/约束对应，10条SCF已加载，CCR零错误、33条既有share-pin诊断。reader网表确认256位尾mask及动态长度逻辑消除；camera ready_sync/active→paused_meta首跳6ns datapath-only/hold例外已生效，后级不豁免。最终候选reader_full_chunks_20261031/BE_cdc_verified_candidate，验证汇总verification_20261031/final_summary.json，报告fpga/reports/当前灰度组合版验证完成_20261031.md。B/C/D及最终组合队列均已结束，旧等待器已被替代；C/D仅独立实验、未合入。DDR残余hold估计仍需实际PnR min/max STA，验证完成当时无PnR scope、位流或下载，不把综合正余量称为全芯片时序通过。下方记录为历史阶段，不再据旧pending状态启动任务。

> 2026-10-31 退化定位与reader优化：gray_committed原生180分钟超时，第13轮剩46652/101887；详细布局线长较旧轮+5.71%，同第12轮CPU为18.57倍。旧130位/新66位refill FIFO实际均映射16×34，缩宽未减少物理存储。新E利用RAW1920字节整32B行去除尾mask/动态长度，专项450000检查及完整2073600字节网络通过；已并入工作区B，组合冻结为reader_full_chunks_20261031/BE_working_candidate。组合完整1080p verilator_20261031_151216_378724通过（3新5重复/16588800像素/0欠流、旧帧排空保护、全部源哈希一致），组合物理签核尚待。B单项SYN/MAP通过：MAP38063 LUT/42288 FF，processing综合setup+0.785ns，10条SCF/CCR核验通过；基线实际MAP为38275/42632，42645 FF是SYN口径。C完整视频也通过。B/C/D串行状态gray_candidates_native_20261031/run_1510/state.json；E等待队列仅E_after_queue_v2有效，等待上述队列和完整证明，失败即停。新候选无PnR scope，不自动PnR/位流/下载；不改旧云端交付冻结输入。详情fpga/reports/布线效率退化定位与新候选优化_20261031.md。

> 2026-10-31 B候选完整1080p回归完成：verilator_20261031_120804_113491通过，3新帧/5重复/16588800像素/0欠流，排空旧帧保持通过，94项视频源与B匹配；该视频顶层不例化solver，solver由161例差分和UART/几何专项证明。B状态FUNCTIONAL_AND_FULL_VIDEO_PASSED_NATIVE_PENDING；C/D仅实验专项通过，均未SYN/MAP/PnR。活动PnR327项冻结源及MAP/SYN输入未变。

> 2026-10-31 用户要求保持当前PnR设计不变并继续优化，允许多智能体并行。本轮B在工作区复用solver work为结果bank；161例对A/提交版差分、UART/几何集成通过，完整1080p见 pose_resultbank_20261031/candidate_120422/full_video_state.json。C packer清零裁剪与D本地mount直读仅在独立实验中，专项通过，未并入live RTL。三项都无SYN/MAP及新route_scope，不触碰活动gray_committed_pnr冻结源。总览：fpga/reports/并行结构优化进展与候选清单_20261031.md。

> 2026-10-31 后续候选：已在提交dc056b275之后将 raw_pose_solver 的MM_COPY改为9位one-hot逐系数复制（成功求解+40周期）。126例逐位差分、9位置复位、原始姿态/UART及几何集成通过；完整1080p与SYN/MAP尚待，禁止把当前活动PnR结果签核此候选。冻结 candidate_1153，报告 fpga/reports/姿态矩阵复制局部化候选与验证_20261031.md。候选native评估须等当前PnR释放锁；本候选无route_scope。

> 2026-10-31 新授权：用户要求先提交、交接布线监控再更新设计。基线已提交 dc056b275；独立冻结工程 gray_committed_pnr_20261031_114430 使用当前38275 LUT MAP，原生180/主机185分钟，仅一次PnR+min/max STA，禁止位流/下载。后续solver候选不得改动冻结源。交接见 fpga/reports/已提交灰度版布线监控交接_20261031.md。

> 2026-10-31 灰度 refill CDC 验证完成：8组专项、完整1080p、SYN/MAP通过，MAP为 `board_postsyn_20261031_015805_334340`。资源38275 LUT/42645 FF/154 APM/71.5 DRM，相对上一版仅−1 LUT/−5 FF；processing综合setup仍+0.790ns，不能据此宣称拥塞改善或布通。结果见 `fpga/reports/灰度填充CDC验证完成与资源对比_20261031.md`，未建立新route_scope，不自动PnR/位流/下载。

> 2026-10-31 超时后优化：gray_optimized_pnr_20261030_234014 于01:13原生超时，第39轮剩21369条未布通，未进入STA。当前新增固定灰度 refill CDC 压缩（内部quad96→32，FIFO130→66），8组专项通过；完整1080p→SYN/MAP验证见 `fpga/build/gray_refill_cdc_20261031/pipeline/state.json`。旧MAP不证明新源码；新布线/位流门禁关闭，验证和对比完成后再评估。

> 2026-10-31 条件续跑授权：用户允许“若有希望收敛，则可以延长时限”。接近原预算前评估最近 3～5 轮改善、单轮耗时、CPU/净清除和剩余规模，再决定有界追加；不无限延长。当前运行的 action_timeout 已提交，supervisor 无动态预算入口；改磁盘 policy/Tcl 不会使当前时限改变。未核实原地调整能力时保持现有进程，结束后保留证据，再评估受支持的检查点继续或转入优化；从 PLC 重启布线不等于续接未完成路由迭代。后台跟进已同步此授权。

> 2026-10-30 最新授权覆盖：用户明确要求“继续，完成设计优化，完成后启动布线”，此前全局布线前停止边界已被本次指令替代。选用已验证灰度单通道/排空共享矩阵版本（38276 LUT）；窄任务邮箱候选因资源和综合时序退化不并入。仅授权一次有界 PnR 及后续 min/max STA，禁止自动位流/下载。工程与监控见 `fpga/build/full_integration_20261013/gray_optimized_pnr_20261030_234014`。

> 2026-10-30 灰度单通道优化修订：固定灰度板级内部 cache bank 为 8 bit、四邻域为 32 bit、双线性插值为 1 通道，结果扩展为 R=G=B；DDR RGB888/refill/HDMI 接口不变，保留参数排空和完整旧帧显示保护。7 组定向及完整 1080p 行为仿真已通过；新 SYN/MAP 由 `build_gray_to_map.py` 运行并自动停在全局布线之前。用户明确要求本轮不进入全局布线，禁止自动 PnR/位流；动态监控见 `fpga/build/gray_datapath_20261030/pre_route_handoff_2045/state.json`，不能用旧资源报告证明本修订物理通过。

> 2026-10-30 最新布线目标：用户取消 60%/70% 等人工 LUT 占用率上限，允许使用 PG2L100H 全部 66600 LUT，以实际布通优先；可增加局部复制和流水寄存器。非关键路径只有在 RTL 采样节奏/握手支持且经核验后才放宽时序；不得直接把低频使用等同于多周期。长时间稳定性/长时老化测试不作为本轮前置条件，帧所有权、DDR 写完成、旧帧显示保护、FIFO CDC 和复位释放保持正确。旧冻结产物的历史门限记录保留，但不得再据此否决新构建。

> 2026-10-30 参数排空与旧帧保持修订：板级启用 `STOP_TO_UPDATE=1`。几何矩阵、参考或 ON/OFF 更新排队后，暂停 DDR 侧新源帧接纳，完成并释放全部旧 SRC 作业，再在下一次源帧接纳边界应用新参数。PC-only 无历史路径用一份运行矩阵替代三份按 SRC 槽保存的矩阵；显示结果仍按槽/代次持有，HDMI 持续重复最后完整旧帧，直到新完整结果在显示帧边界接替。切换不复位 DDR/HDMI，不撤销摄像头就绪（避免重新预热）；堵塞中残帧按现有取消/排空机制丢弃。A7 接纳/排队、A8 源帧应用、kind 10 显示确认仍为不同阶段。该修订必须重新验证，`b511dedfc` 的 SYN/MAP/PnR 仅证明旧冻结源码。

> 2026-10-30 固定灰度修订（覆盖下文旧颜色/亮度调节描述）：当前板级移除手动曝光/增益调试、ISP颜色/白平衡/CCM配置及可选Gamma。RAW8先去马赛克，再用 `(77R+150G+29B+128)>>8` 转灰度；固定曲线在0～192保持原值，193～255执行 `192+((x-192+1)>>1)`，最大输出224。它是分段线性高光压缩，不是幂函数Gamma，也不宣称实拍最优。灰度仍采用RGB888容器，R=G=B；原始S0 RAW8网络证据、DDR帧步长和HDMI接口不变。A0 capability bit6宣告此固定配置，kind 1/2/3/7及旧0x92调节被撤下；kind 9/10/13和原始pitch/yaw解算保留。新源码须重新验证SYN/MAP/PnR/STA，旧资源和布线报告不能证明本修订已物理通过。

# 项目工作约定

## 2026-10-29 原始双角度 FPGA 解算覆盖说明

当前 PC 通过既有 UART A7 原样提供 pitch/yaw 毫度整数和归一化 XYZ；FPGA 的 pose_sincos/raw_pose_solver 完成三角函数、安装坐标变换与完整 Q26 矩阵解算。A0 bit5 宣告原始姿态能力，kind 13 上传静态标定，A8 回读解算排队与源帧应用状态。保留 PROJECTIVE=1、SOURCE_GAMMA=1、PC_ONLY_CONTROL=1，不新增 MCU—FPGA UART。仅支持固定光心 rotation_only；XYZ 必须等于参考值，未标定位置不得当作物理平移。用户尚无安装标定，示例 verified=false。先前 PC 实时求矩阵的方案已被本修订替代；历史报告仍只证明历史源码。

## 2026-10-26 FPGA 精简配置覆盖说明

按本次用户指令，当前板级 FPGA 改为 PC 动态控制配置：移除 MCU 自动姿态、独立 MCU UART 协议/时间映射/姿态模型及 kind 8/12；撤销运动诊断 kind 11 和已不可用的 kind 6 配置/清历史入口。保留 PC 几何、参考矩阵、仿射开关与手动图像控制。普通图像配置回读采用 capability bit 3 宣告的 schema 2 摘要，不返回完整 body；PC 不把本地草稿当作板端回读。后文 MCU V2 约定仍用于 MCU 端及旧版归档，不能据此宣称当前 FPGA 仍接入 MCU 姿态。当前新配置的布线和实板状态以实际报告为准。

## 开发内容的落点

- `fpga/`：FPGA 本体实现，包括 RTL、IP、约束、PDS 工程、算法参考模型、仿真、配置、构建脚本、构建结果、报告及位流发布。
- `mcu/`：云台、电机、光照等设备端实现，包括 MCU 固件、外设驱动、设备端通信、配置、固件测试、板级调试数据与报告及固件发布。
- `host/`：上位机实现，包括 PC 界面、通信客户端、设备控制、图像采集、质量与性能测评、测试自动化、配置、采集数据、报告及软件发布。
- `output/`：仅放规划类材料，包括需求、设计方案、开发计划、接口设计和验收方案。不得在这里创建实现代码、可执行脚本、工程文件、构建产物或实测数据与报告。
- 所有项目实现及其产物必须直接在 `fpga/`、`mcu/` 或 `host/` 中创建和修改；不要先输出到 `output/` 再让用户复制，也不要在根目录新增 RTL、固件、模型或构建输出目录。
- 根目录 `docs/` 仅用于仓库管理说明；根目录 `scripts/` 仅用于仓库级管理（现有 Git 备份脚本）。业务构建、仿真、烧录、测试脚本分别放到三个开发区自己的 `scripts/`。
- 跨 FPGA、MCU 和上位机的接口设计可放 `output/`；各端实现分别归属对应开发区，接口改动应同步维护相关代码和测试。FPGA 算法参考模型归 `fpga/model/`，PC 测试控制、采集及测评代码归 `host/src/`，采集证据归 `host/data/`，测评报告归 `host/reports/`。

## 代码注释约定

- 后续所有代码新增或修改，都必须为新增或受影响的代码块添加或同步更新注释，说明该代码块的用途、职责及必要的设计意图；此要求适用于 FPGA、MCU、上位机代码及相关脚本。
- 注释以模块、函数或功能块为单位，重点解释用途与关键逻辑，不要求逐行复述代码。
- 修改实现逻辑时必须同步维护相关注释，确保注释与代码一致，不保留过时或误导性的说明。

## PDS 官方参考目录（只读）

- 官方参考目录为 `E:\PDS_Pangu\PDS_2022.2-SP6.4\doc`，作为本项目后续开发的官方文档与示例参考来源；该目录及其全部子目录、文件均只读。
- 不得在原目录内编辑、删除、重命名、移动或覆盖任何内容，也不得向其中写入新文件、提取文本、索引、日志、仿真结果或构建产物。运行示例或工具时，必须将工作目录及输出路径设在对应开发区，避免工具自动改写官方资料。
- 后续涉及 PDS 工程配置、Tcl/命令行、IP、仿真、约束、时序分析、下载或调试的开发，必须查阅该目录中与当前安装版本对应的官方资料，并结合 `reference/` 中匹配目标板卡的资料核对，不凭其他平台或版本的用法推断。
- 如需修改或运行官方示例，应先将示例及必要依赖复制到 `fpga/`、`mcu/` 或 `host/` 对应开发区，仅修改副本；PDS/FPGA 示例及其构建脚本、日志和产物归 `fpga/`。在副本或相关说明中记录官方原始路径、PDS 版本与所做修改。
- 官方示例仅作为参考，使用前仍需核对 PG2L100H 目标器件、封装、板卡版本、引脚、时钟及 IP 依赖；不得把其他平台的示例运行结果当成本项目已完成的验证。

## 当前视频与测评基线

- 单路 OV5640 RAW8 DVP → FPGA；S0 原图通过板载千兆网输出，FPGA 基础 ISP 后的 S1 经矫正得到 S2/S3，结果通过唯一板载 HDMI 输出。PC 不转发主视频、不执行实时几何矫正。
- 跨端接口权威说明为 [RAW8 千兆网与 HDMI 双路回传方案](output/OV5640_RAW8千兆网与HDMI双路回传方案.md)。更新数据格式、帧池、网络报文或配对方式时，同步主设计、output/host 和整机测评文档。
- S0 的 PC 基础可视化不能冒充 FPGA S1；2026-10-21 已按交接撤销板端 S1/结果同源快照；严格像素精度目前依赖 RTL/离线参考，不声称实板同源精度验收。HDMI 帧源身份未验证时保持 null/unverified，不按软件到达顺序推断。
- 真实1080p30、未压缩原始数据、网络完整帧率与FPGA结果帧率分别验收。本次范围只保留真实1080p30，不新增60FPS或第二源扩展。
- 原始证据保存.raw/.rgb及元数据，PNG等只能作为派生可视化。功耗、吞吐和来源证明均需真实测量，不把方案预算列为实测结果。

## 保持现有约定

- 2026-10-21 MCU 开发基线同步为 `origin/codex/mcu-test-system` 的 `1db773613f18823d1aca31d210625932657b6fd4`（旧导入基线 `adf340927`）：F4 汇聚 XYZ 步数估计，F1 的 pitch/yaw 改用舵机编码器位置反馈闭环，不再编译或调用 MPU6050 融合。外层 version=2、profile=0x4D32 和报文长度不变；GET_INFO 不宣称 IMU，GET_CONFIG 角轴 state_source=2，STATE angle_source 每轴1、双轴有效为0x05，pose_status=3。按 `output/MCU_POSE_V2接口实现补充.md` 的当前修订开发；物理中心、轴向、相机外参及时间映射尚未验收。本机修正和实际软件验证见 `mcu/reports/编码器角度闭环同步记录_20261021.md`。旧 MCU_POSE_V1、pitch/roll、XYZ 微米、全系统 STOP 约定已撤销。
- XYZ 为归一化坐标（满行程 100000000），不是已标定物理长度；yaw 为机械相对角，不是绝对航向。F4/F1 型号是云端工程目标，实物板卡、引脚、电平、安装、行程及时间映射仍须验收。MCU→FPGA 独立回传，PC 不逐包转发；FPGA V2 字节接口已接入核心姿态路径，但板级物理UART、时钟误差与标定仍未放行；PC 完整设备客户端尚未集成，不把云端软件测试当作本机或实板验证。后续接入方向见 `output/MCU_POSE_V2云端同步实施计划.md`。

- 当前 FPGA 平台依据 `output/PG2L100H_1080p畸变矫正详细设计方案.md`；测试系统依据 `output/可控光照箱与上位机测评详细实施方案.md`。MCU 型号等未确定事项不得自行写成已确认事实。
- 旧规划中省略开发区前缀的实现路径，以本文件和三个开发区 README 的目录规则为准。
- Git 只排除根目录 `reference/` 和 `PDS/`，不要擅自增加其他忽略目录。三个开发区内的源码及产物均遵循现有提交、推送流程。
- 保留原始参考资料；实际使用的源码和依赖复制到对应开发区，记录来源，避免正式工程依赖被忽略目录。
- 本次目录骨架不代表实现、仿真、综合或硬件验证已经完成。只报告实际执行的验证结果。
