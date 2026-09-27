# RAW8 双路无画面：诊断候选与证据边界

## 现象和修正后的判断

首个候选 2197404297e4 的 RAW8 启动 ACK 正常，连续 STATUS=0x019F：sensor_ready、PHY/link、commissioned/session 有效，core_fault OR bridge_fault 置位，published=0。网络观察未收到包/完整帧。现有证据把首要排查点放在有效帧发布前，不能仅凭黑屏归因于 RAW8 解码。

用户观察：HDMI 不连接时持续 No Signal；连接后闪烁 No Signal 随后黑屏。单张截图不能代表全过程或证明持续失锁。采集卡重连前720p/1080p请求出现640×960/1280×1440和JPEG错误；仅USB重连后已能解码1920×1080的采集卡自身No Signal图。此样本只证明该采样时刻，不能否认用户观察的后续黑屏；还需连续稳定性检查。

## 实施内容

- 保持原 RAW8 数据、DDR帧池独立读锁、灰度转换与已有TMDS编码不变，不增加测试图替代源或放宽故障保护。
- 增加 STATUS 的故障来源：写入、读仲裁、帧池、网络、读FIFO溢出、GMII桥读/写；写入首次原因区分START/WORD/END、WID/WLAST、最后一字读回栅栏。具体映射同步至 host 启动说明和 MCU 协议规划。
- host 串口 Inspect 增加 raw8_status 解码，旧镜像扩展位为0时仍保留 aggregate fault，不把未知原因显示为正常。兼容性实测见 host/reports/raw8-cold-20260923-first/decoder-compatibility.json。
- 新增 tb_raw8_tmds.sv 与 sim_raw8_tmds.ps1：两完整1080p帧，独立反解生产TMDS符号、检查RAW灰度、RGB通道和HS/VS/DE延迟对齐。不是物理HDMI电气证明。

## 已执行离线验证

- raw8_dual_sim_20260923_161721_045：采集几何/坏帧、启动、帧池、读调度、原生接口故障边界、双路像素检查均通过；2073600像素、1482包经真实host重组逐字节校验。
- raw8_board_sim_20260923_161717_864：原生FIFO、行为HMIC，正常6个摄像头刺激帧、5个HDMI帧、8892包；启动epoch竞态排除第0帧，5网络帧7410包；均通过。未覆盖真实DDR PHY与板外电气。
- raw8_tmds_sim_20260923_161850_551：两帧，4949998个符号/控制检查，每帧2073600像素，通过。
- native_20260923_161717_514：PDS 2022.2-SP6.4 原生编译、综合、布局布线、快慢角STA、同一路由数据库位流导出通过，All Constraints Met。DVP外部pad偏斜仍未签核，不能把内部时序通过当成板外输入已验收。
- 发布诊断候选：fpga/release/raw8_dual_20260923_a43bcf922a4f/，SBIT/SFC各3791112字节，SHA256 A43BCF922A4FA6AD3AEC382409A3E5B57809834171901FECD92D460C33BD3794。270个输入审计、原生RGMII/桥接回归门禁通过。

## 板上操作记录位置

只读预检 fpga/build/raw8_diag_probe_20260923/：PG2L100H ID00602899、Flash ID0B4018；over_temp=1保留，不屏蔽，不宣称已测得温度或热安全。固化操作记录在 fpga/build/raw8_diag_flash_20260923/；是否写入/校验成功以该目录 result.json 与原生完成日志为准，冷启动和视频验收另行记录。

原219740候选和已验证旧摄像头317733恢复镜像均保留，哈希本轮复核一致。官方PDS与reference目录只读；未推送云端、未上传实测视频，未改main或其它工作树。

当前是故障定位版本，不宣称无画面已修复。下一步必须在新镜像重启后读取细分故障码，再针对实际失败合同修改及回归；HDMI要连续观察锁定/黑帧，不能再次用启动瞬间No Signal作全程结论。

本轮固化已完成：所选XT25F128整片擦除、写入91.4秒、原生回读校验31.5秒成功，result.json的native_program_and_verify_passed=true；完成标记存在，JTAG会话与任务服务均关闭。原配置已替换，可重新烧录保留镜像恢复。

## 诊断候选冷启动与第二轮修正

用户确认重启后，host/reports/raw8-diag-cold-20260923/status.json 实测STATUS=0x4100019F：sensor_ready=1、published=0、writer_fault=1、first_error=2；读仲裁、帧池、网络、读队列、GMII桥故障位均为0。PHY ID001CC916、step22、最后MDIO ACK正常。该错误是WORD的active/偏移/数量合同，不是已确认的TMDS解码失败。用户LED观察与故障LED存在差异，以上以CRC校验串口证据记录，暂不据LED推翻故障码。

只读查阅 reference/OV5640双目摄像头资料/芯片数据/OV5640_AF_Imaging_Module_Application_Guide_(DVP_Interface).pdf 第56–57页：3034=18时Bit_div2x=4。原3036=69（105）对应24/3*105/1/2*2/4/2=105MHz，而非注释的84MHz；HTS2500、VTS1120的名义帧率为37.5而非30。修正3036=54（84）得到名义84MHz、30fps。此为寄存器公式核对，不是实测PCLK或帧率，也尚不能认定是本次WORD故障的唯一根因。

新增首个WORD错误的mem_clk域冻结快照，UART capability5/命令06读取actual/expected/count/active，保留所有原故障门禁。增加启动寄存器独立断言、快照粘性与missing START/offset测试、UART长度/epoch/session/无副作用回归。新候选的仿真、STA、Flash与冷启动结果需分别追加，未完成前不称修复通过。

第二轮离线结果：raw8_dual_sim_20260923_170023_533全项通过；raw8_board_sim_20260923_170027_819正常6帧发布/5HDMI/6网络8892包，late_epoch为6发布/5HDMI/5网络7410包，逐字节重组通过；mcu_protocol_20260923_170027_581完整与125MHz两配置通过（5958/2621检查）。host快照字节序固定样例测试通过，PowerShell语法无错误。

native_20260923_170058_974完成PDS编译、综合、PNR、快慢角STA，All Constraints Met，同一路由数据库生成镜像。发布56f6f46dfc0c，SHA256 56F6F46DFC0C75ECF04724B2BF39D8DCCCEA7E37507D57426374DDD3B683CE9C，270输入与仿真源哈希审计通过。只读板卡预检raw8_clock84_probe_20260923再次确认00602899/b4018，over_temp仍1，未屏蔽。固化日志在raw8_clock84_flash_20260923；此处不预判冷启动或真实视频结果。

第二轮固化结果：选定16MiB XT25F128整片擦除13.0秒，写入91.3秒，原生回读校验31.5秒全部成功，完成标记存在，result.json native_program_and_verify_passed=true。JTAG断开并关闭任务创建的服务。新56f6f4配置已替换旧a43bcf配置，保留镜像可重新烧录恢复。等待用户再次彻底断电重启；新镜像的真实帧、网络与HDMI画面尚未验收。未上传实测视频、未改动main、未修改官方参考或系统设置。

## 56f6f4 冷启动复查

用户报告LED0闪烁、LED1/2亮、LED3/4灭后，读取CP2102/COM15：初始RAW8 boot endpoint未commission，生成独立新epoch并获得0x71/RAW8 ACK。CAPS=0x3F，确认包含本轮命令06。两次STATUS均0x0000011F，sensor_ready=1、PHY/link/commission/session有效，所有故障位及writer_first_error清零，但published=0。命令06两次均为无有效快照（version0、valid=false），不能解释为摄像头无像素。PHY ID001CC916、step22、状态302E、无最后MDIO ACK错误。PC ASIX if16为1Gbps、169.254.81.186/16。证据：host/reports/raw8-clock84-cold-20260923/；独立配置：host/config/raw8-clock84-cold-20260923/。

结论：新候选冷启动和通信接口已实测，旧WORD故障本次未复现；仍无完整帧发布，视频未修复验收。当前快照只覆盖WORD故障，不含DVP时钟活动、实际行宽/行数或几何丢帧原因。因此无法仅凭上述状态区分输入停滞、几何不符和帧交接停滞，下一轮需要这些计数/状态的可靠跨域遥测，而非继续猜测HDMI RAW解码或放宽坏帧检查。本轮未再次烧录，也未把离线仿真标为实际视频。
