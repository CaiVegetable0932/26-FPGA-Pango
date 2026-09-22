# 通信候选冷启动故障与修正记录

日期：2026-09-22；分支 `codex/fpga-mcu-praw-protocol`。本轮是合成 TEST 流的以太网联调，不包含摄像头/HDMI，不是 RAW8 摄像头回传验收。

## 已发生的硬件操作

- 用户明确批准本轮 XT25F128 整片擦除、通信候选固化；13:09 开始的原生工具流程擦除约 13 s、写入约 91.1 s、回读校验约 31.5 s，均成功。候选 SHA256 `e51d3cc9c9ee85814fa7525621d9779b5a5679300f6e9933ee6d054dd7da9cbf`。
- 日志：`fpga/build/comms_flash_program_20260922_130918/`。原摄像头恢复镜像 `fpga/build/camera_div2_flash_20260921/Top.sfc` 保留，SHA256 `317733DFC9A6D083971E2E09B203E403B8939E6163B33BD7EAB32667048CFAAC`。
- 用户确认彻底断电重启后，COM15 能打开但 CAPS 请求未收到任何字节；ASIX 以太网链路 Disconnected/0 bps。用户报告 LED0～4 全部常亮、手动按复位后不变，网口指示灯不闪烁。
- 冷启动只读 JTAG：PG2L100H ID `0x00602899`，状态 `0x0817fca0`，done/init_complete=1，pll_lock=0，CRC/ID/auth 错误均为 0。Flash 扫描成功。任务创建的 JTAG 服务已关闭，用户 PDS 窗口未动。
- over_temp=1 原样保留；用户说明温度读取异常。本轮没有屏蔽告警、修改保护、测得实际温度或证明热安全。

## 已确认的实现错误

1. `comms_pll` 原输入 125 MHz、IDIV=1，因此 PFD=125 MHz，但原生成 HDL 的 BANDWIDTH=OPTIMIZED。安装版本 `UG041001_PLL_IP.pdf` 第 33 页要求 GPLL PFD 在 40～450 MHz 区间使用 HIGH。这是一个确定的参数不符合项，与未锁定现象一致；是否是唯一板级根因仍需重烧验证。
2. MINI V1.3 硬件手册第 34～35 页明确 LED 高电平点亮，原顶层却对状态向量取反。逻辑被保持复位时，全部状态为 0，取反恰好使全部 LED 点亮。已改为高有效，不把全亮误判为启动成功。

## 修正与验证边界

- 在 IP 配置源中明确指定 HIGH，由 PDS `ip_generate -ads -disable-syn` 原生再生；0 errors/0 warnings，生成 HDL 已核对 HIGH。不修改官方模型或手工改生成 HDL。
- 参数生成器对明确设置 bandwidth 的配置检查 PFD/带宽匹配，避免旧配置再次静默生成；其它历史 IP 未重新生成，也不宣称已审校。
- `python -B fpga/sim/test_comms_pll_profile.py` 三项通过：参数/输出频率及 native HDL 一致性、旧错误参数拒绝、MINI LED 极性。
- 再次使用原生 GTP_GPLL 的严格 ModelSim 仿真仍出现第 1026 行 NaN 除零；1000 次周期/相位断言通过不覆盖该错误，整体结果仍为 FAIL。未关闭错误检测。此问题不得被改写为仿真全部通过。
- 第一轮修正构建 `native_20260922_132615_887` 被时序门禁拦截：Slow setup -0.342 ns，3 个失败端点，未生成/烧录位流。最差路径从 MCU parser payload，经 256 位重复事件比较、响应码/计数器选择进入应答队列。外部 RGMII setup/hold 仍通过，没有放宽约束。
- 将重复事件相等比较改为 8 组 32 位寄存检查，利用载荷完成到两字节 CRC 校验结束的既有时间，不增加协议响应阶段或改变事件去重语义。寄存器带保留属性，避免重建 256 位长进位链；注释明确 parser 稳定窗口依赖。
- MCU 实际回归 `mcu_protocol_20260922_133058_042`：加速全量 5378 checks/56 responses/3 events 通过，生产 125 MHz 配置 2041 checks/21 responses/3 events 通过，含去重、冲突、CRC、超时及 epoch/session 清理。
- 第二轮 `native_20260922_133113_156` 完成原生工程生成、编译、综合、布局布线、双角时序及位流。gen_bit_stream 再次运行实现后，最终时序报告仍为 All Constraints Met，28 项源码哈希与归档/原生镜像一致。
- 修正候选 `fpga/release/comms_bringup_20260922_a877b63ea309/`，SBIT/SFC 均为 3,791,112 字节，SHA256 `a877b63ea309ad399abd79a937fc50c72f287fbaf3c399427037d84742c4bc31`；最终 timing SHA256 `3a4a7b2568fed3decc7357f599babd0bd3a3307b6e1bb16a56adfadb54cae1f1`。
- 最终 Slow/Fast：内部 setup 0.080/3.035 ns，hold 0.177/0.099 ns；RGMII setup 0.126/0.143 ns，hold 0.103/0.115 ns；recovery 1.923/2.633 ns，removal 0.349/0.204 ns。所有相关端点无违例；外部偏斜/延迟仍是预算，非实测波形。
- 13:38 开始按本轮授权再次固化修正候选，日志 `fpga/build/comms_flash_program_20260922_133840/`：整片擦除 13.0 s、写入 91.1 s、原生回读校验成功，完成标记及 `result.json` 均通过。任务 JTAG 会话/服务已经关闭，65420 无监听。原摄像头恢复文件未修改。
- 已请求用户对新候选再次彻底断电上电，等待 10 秒后确认。当前只确认 Flash 固化/校验，尚未验证修正镜像冷启动或收到 UDP；不能报告链路通过。下一步依次检查 COM15 CAPS、PHY 千兆连接、下发新 epoch 的 TEST 配置，再用 host 检查分片 CRC、完整帧及逐像素合成内容。

## a877 冷启动实测与后续 MDIO 排查

用户报告 LED0 闪烁、LED4 常亮。PC 侧以太网实际恢复 Up/1 Gbps，169.254.81.186 为 Preferred；COM15 CAPS 得到 CRC 合法的启动端点 NACK6，这是启动配置之前的预期应答。随后生成并发送新 TEST epoch，0x70 配置、能力查询、开启 session1 和 STATUS 均得到合法 ACK。记录在 `host/reports/comms_ethernet_20260922/{probe_a877_cold,boot_a877,status_a877}.json`，配置在 `fpga/build/comms_boot_a877_20260922/`。

状态 `0x00010039`：alive、commissioned、session、PHY fault=1；PHY configured/link_ready=0，fault_code=1（MDIO turnaround 无应答）。串口及主时钟路径已经实测可用；PC 的物理千兆协商不等于 FPGA 已成功管理 PHY，也不等于 UDP 完整帧通过。此状态按原有 fail-closed 逻辑不发送视频。

只读复核 MINI 手册第29页，MDC A25、MDIO E21、reset G25 与当前约束一致。参考 MDIO 例程使用地址1；RTL8211F Rev1.4 第16/19/57页说明地址1～7、广播地址0及最大300ns读输出延迟。当前故障码不足以确定失败寄存器或实物 strap 地址，不宣称已经证明地址错误。

新候选增加可选命令05读取96位 PHY 诊断：器件 ID、当前/失败步骤、选定地址、最近原始读值、TA 错误和 PHY 状态。仅能力bit4=1时由host调用；旧端点兼容检查 `status_a877_compat.json` 成功，未向旧镜像发送命令05。初始化仅在首个ID读无应答时只读尝试地址1～7，只有完整ID匹配后才允许定向写配置，禁止广播；后续任何错误仍锁存停发。

离线验证：PHY `phy_20260922_135020_536` 35672 checks/103 transactions，通过地址7发现、禁止错误地址写入、全部地址无应答及既有故障/链路用例；MCU `mcu_protocol_20260922_135035_175` 全量5572 checks/58 responses与125MHz 2235 checks/23 responses通过，含新诊断的身份校验与无事件副作用。新构建 `native_20260922_135105_569` 首轮时序 All Constraints Met，内部Slow setup余量0.479ns；正在生成最终镜像，尚未再次烧录。

## 236d 诊断候选生成记录

`native_20260922_135105_569` 最终位流流程已完成，第二次实现后的12项双角时序摘要和28项源码哈希审计全部通过。新发布目录 `fpga/release/comms_bringup_20260922_236d53fb1f80/`，SBIT/SFC 3,791,112字节，SHA256 `236d53fb1f80a12ee3a07fae20430b2baf62e331117ef84f0bfe74b68491b1a8`；最终时序报告 SHA256 `295620c80e672082900fc149ae0c3c0fd8915b0aebc11a2852548894489bc91d`。外部RGMII时序预算不变；严格原生PLL模型初始化错误仍作为限制保留，不报告全仿真通过。

13:58 开始按本轮授权固化，日志 `fpga/build/comms_flash_program_20260922_135830/`：擦除13.0s、写入91.1s、回读校验31.5s均成功，完成标记和result.json通过。14:01任务JTAG会话/服务已关闭。未执行 SRAM-only 下载，未修改参考资料或系统网络设置；已请求用户冷启动，最终PHY诊断及数据接收结果待验证。

## 236d 冷启动结果与启动窗口修正

用户确认重启、仅LED0闪烁。实测ASIX接口Up/1Gbps；COM15启动配置与查询ACK均CRC合法。但STATUS仍为0x00010039，诊断ID=00000000、step=0、address=7、last_read=FFFF、TA错误=1。30秒接收窗口0包/0帧，不能报告以太网数据链路通过。证据在host/reports/comms_ethernet_20260922的probe_236d_cold、boot_236d、status_236d、receive_236d.json；LED观察与锁存诊断不完全一致，未用观察替代寄存器结果。

进一步只读核对RTL8211F Rev1.4（PDF第37、59～60页，书内第30、52～53页）：§7.17要求硬复位低至少10ms、访问前等待至少50ms；§9.3注6另给出100ms特殊参数配置窗口，结束后全部MDIO寄存器才可访问。旧30ms参数不符合要求；在芯片就绪前扫描全部地址并永久锁存TA故障，是确定的实现缺陷，是否解释全部实物问题仍需新镜像验证。

复位释放后等待改为200ms，不提前写跳过窗口的寄存器，不放宽ID/ACK/读回/千兆门禁。仿真增加独立150ms未就绪不应答模型：phy_20260922_182941_593以旧30ms参数复现7次无应答且无任何写入（2361 checks）；phy_20260922_183020_984以生产200ms参数通过42264 checks/103 transactions/56 reads/47 writes。早先phy_20260922_182853_910的命令行参数被PowerShell合并，实际跑默认200ms，不能当作30ms反例；脚本已修正参数数组，以上两个后续独立运行才作为验收依据。

布局布线后网表还确认MDC输出位于A25、MDIO双向缓冲位于E21，输入路径和三态使能均存在；这只能证明实现连接，不能代替板上电气波形。补充PHY_TX_DELAY=0回归phy_20260922_183250_752亦通过42264 checks，生产板仍使用PHY_TX_DELAY=1。

新构建native_20260922_183020_746完成原生工程、编译、综合、布局布线、双角STA、位流生成。最终28项输入哈希和12项时序摘要审计通过；Slow/Fast内部setup=0.294/3.093ns、hold=0.177/0.100ns，RGMII setup=0.126/0.143ns、hold=0.103/0.115ns，recovery=0.986/1.983ns、removal=0.228/0.116ns。没有放宽约束；异步/低速管脚未约束提示和原生PLL严格仿真初始化错误仍保留，不宣称所有接口电气时序已经实测。

发布目录fpga/release/comms_bringup_20260922_2da7243c6d09；SBIT/SFC各3791112字节，SHA256=2da7243c6d097a292ef79487aa5d2c55a2e32ac09818e99b20c5aa544f3ce4bb；最终timing SHA256=234b214d7934d97bb1dd56dc4d978098392e490c03b20b06eb47a7e94747c1f9。18:33只读预检comms_preburn_probe_20260922_183336确认ID00602899、状态081ffca0（PLL锁定、配置完成、无CRC错误；over_temp=1保留）。18:39按既有授权开始Flash擦除写入，comms_flash_program_20260922_183905；完成与冷启动另行记录。

2da7候选Flash流程已完成：整片擦除13.1s、写入91.3s、回读校验31.5s全部成功；原生完成标记和result.json均确认。任务JTAG服务已停止、65420无监听。当前仅证明Flash内容正确，尚未冷启动验证新PHY初始化或收到UDP完整帧；请求用户彻底断电再上电并等待10秒，随后使用新epoch进行接收测试。旧236d实测失败仍保留，不覆盖为新版本成功。

## 2da7 冷启动：确认MDIO读位错位并修复

用户报告LED0闪烁、LED4亮、网口灯亮。ASIX实测Up/1Gbps、IPv4为169.254.81.186 Preferred；COM15启动配置前NACK6合法，随后新epoch5853146717271418731配置/会话/诊断均ACK合法。STATUS变为0x00020039：fault_code=2，地址1已有TA应答，step=0、last_read=0039、last_ack_error=false，未通过ID检查；30秒UDP接收仍0包0帧。证据host/reports/comms_ethernet_20260922/{probe_2da7_cold,boot_2da7,status_2da7,receive_2da7}.json，不把网口亮灯或启动等待修正称为链路通过。

0039恰为(001C<<1)|1。只读审校RTL8211F Rev1.4 §7.11.2管理帧及§10.6.1时序图，对照MINI厂商mdio_master_driver.v在MDC上升沿读取数据：PHY的TA0在第一TA上升沿后输出，下一上升沿采样；D15在第二TA沿后输出，第一DATA沿采样，以此类推。旧模型晚一个周期才驱动TA0，恰好掩盖了旧驱动在高电平末端错采下一位的缺陷。先只修模型，运行phy_20260922_184726_944，旧驱动精确复现raw=0039/fault_code=2，正常初始化断言FAIL，与实物一致。

驱动修为在clk125产生MDC上升沿的同一时刻，读取两级同步器中已稳定的上一位；仍使用clk125时钟使能，无新fabric时钟。命令输出保持下降沿推进，TA检查和16bit数据宽度不变，最终高半周期结束后再done。保留200ms启动等待及所有故障停发逻辑。修正后300ns输出延迟回归phy_20260922_184805_821通过42264 checks/103事务，包含完整ID001CC916、配置回读及故障用例。日志PHY_FIRST_ID标签下raw实际是初始化结束时最近PHY状态读002C，器件ID由独立id断言核对，不能把002C当器件ID。

原先基于错误位对齐模型的历史PASS仍保留为执行记录，但不能据此证明MDIO正确。补充回归：phy_20260922_184917_642（0ns读输出延迟）、phy_20260922_185051_889（另一TXID策略）均42264 checks通过；phy_20260922_184951_678确认旧30ms窗口仍被拒绝（2361 checks）。新构建native_20260922_184918_194第一轮STA通过，最终位流流程进行中，尚未固化本次采样修正。

只读烧录预检comms_preburn_probe_20260922_185132：ID00602899、状态081ffca0，PLL锁定、done/init_complete有效、无CRC错误，over_temp=1原样记录；未修改保护或系统网络设置。摄像头恢复镜像和已有私有配置工具/Flash列表哈希均与前次一致。

## 6abc 采样修正候选

native_20260922_184918_194最终原生实现完成；28项输入哈希与归档/实现镜像一致，12项慢/快角时序摘要全部通过。内部Slow/Fast setup=0.550/3.388ns、hold=0.179/0.100ns；RGMII setup=0.126/0.143ns、hold=0.103/0.115ns；recovery=1.546/2.451ns、removal=0.250/0.134ns。没有修改RGMII时序预算，异步低速端口提示及严格原生PLL模型初始化错误仍保留，不能报告全部仿真或全部物理接口时序实测通过。

fpga/release/comms_bringup_20260922_6abc5069a8b4内SBIT/SFC各3791112字节，SHA256=6abc5069a8b45b2e895ce50c7467f324515e50382d1a9b1f468b4672fed5cd1a；最终timing SHA256=739981ed800b75e48697bc6c471030ad193ad18aada555fd06f05605cdf0471c。原摄像头恢复文件与工具哈希未变。18:57按本轮授权执行整片擦除、写入及回读校验，日志comms_flash_program_20260922_185741，完成状态另行记录。

6abc候选固化完成：擦除13.0s、写入91.5s、原生回读校验31.5s全部成功，完成标记及result.json均通过。任务JTAG会话/服务已关闭，65420无监听。等待用户彻底断电重启后，再以新epoch读取PHY ID/配置/链路并验证UDP完整帧；目前仅确认Flash固化成功，尚未证明6abc板上网络通过。未烧入SRAM-only镜像，未修改main或其他分支、参考目录和系统网络设置。

## 6abc 冷启动及实际UDP回传通过

用户报告LED0闪烁、LED1/2亮、LED4灭。冷启动后串口查询PHY ID=001CC916、地址1、PHY状态302E；配置和会话完成后STATUS=0000001F，无PHY/源/MAC故障。PC实际接收：10秒298完整帧/29.8FPS，30秒复测891完整帧/29.7FPS，全部逐字节符合1920×1080 TEST模式，无CRC拒绝或像素错配。首轮1帧缺包超时；复测9帧超时含起始半帧，其余8帧为中途缺包，故仅基本链路跑通、尚未无丢帧验收。原始证据和完整边界见host/reports/comms_ethernet_20260922/README.md及对应JSON。接收后串口再次确认ID/状态正常；没有进一步烧录。

当前只是合成TEST流，不是摄像头RAW8/HDMI或真实MCU端验收。板卡仍按本次epoch持续发包，接收器/串口已经关闭；重启后需重新配置，不重放已用epoch。源码、位流及统计准备按既有流程备份到FPGA专属分支，不合入main、不上传实测视频。

## 来源保护（只读）

只读检查安装版本 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/` 及其附带 PLL IP 手册，并对照 `reference/盘古100K200K MINI开发板/` 硬件手册、网口例程；没有写入这些目录。源码、运行日志及修正产物只落在 FPGA/host 开发区。没有保存或上传实测视频。
