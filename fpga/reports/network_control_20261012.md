# 07 网络与控制接口优化交付

日期：2026-10-12。依据 `output/FPGA分区优化交接/07_网络与控制接口优化方案.md`，优先级为性能、时序、资源。交付为新业务模块、共享向量、离线验证及隔离内部 PnR；**不是主工程完整集成、实板吞吐、电气或同步精度验收**。没有下载设备或生成放行位流，没有改 MCU 运动驱动、主工程/诊断顶层、全局板级约束及官方参考原件。

## 实现与集成边界

网络入口是 [网络模块契约](../rtl/network/README.md) 和 `raw_network_service`：单路紧凑 S0 RAW8、双包有界缓冲、PRAW V1 全头/载荷 CRC32、非零 UDP 校验和、IPv4、独立 MAC/FCS/前导码/IFG、完整 FCS 校验后才交付的 MAC RX、有限 ARP 重试与控制仲裁。RAW DMA reader 复用 04 的 `dma_byte_unpack`，检查槽的舍入访问范围，跨 beat/行去 padding；取消期间排空已出现的回应，完成及 MAC 停止后才允许释放。源 epoch/frame_id 由采集描述符提供，网络重连不重标。

控制入口是 [控制模块契约](../rtl/control/README.md)：独立 MCU UART、2048 B 有界解析缓存、坏候选首字节丢弃后重新扫描、MCU V2 profile/能力/boot/session/config/sample 验证、只读请求与完全相同的有限重试、完整配置回读握手、EVENT 累计确认、SYNC 四周期流水、32 个完整姿态快照与帧内锁定、内部整实体校验/影子/实际生效、跨域原子计数快照。PC 与 MCU 需使用独立 UART/解析器实例；新模块没有接到现有 PC 配置口或 Web 工作台。

PRAW 与 MCU V2 外部格式没有改变。实体校验器和参数银行是内部端口，**没有新分配 PC 命令号或实体载荷格式**；具体标定字段布局、模型/定点/工作域证明、接收/校验/实际生效回应适配仍须集成冻结。UART 线上仍使用 CRC16，内部实体 CRC32 不替代它。

## 网络性能对照

两个候选采用相同 1920×1080 原始图案、stride2048、每行1920有效字节、16×32 B 最大突发、125 MHz 模型。每次 DDR 请求设置 40..112 个时钟无服务等待，逐 beat 回应及 done ACK，接收侧先完成一次 ARP；像素模式区分每行及非零 DDR padding。发送的每个字节均由独立 host codec/校验和/FCS scoreboard 检查，覆盖全部2,073,600 B和1482包，尾包200 B。

| 候选 | 完整帧周期数 | 模型耗时 | 模型最大完整帧服务率 | 有效 RAW MB/s |
| --- | ---: | ---: | ---: | ---: |
| 单包银行，准备/发送串行 | 4,570,354 | 36.562832 ms | 27.3502 帧/s | 56.7133 |
| 双包银行，准备/发送重叠 | 2,323,469 | 18.587752 ms | 53.7989 帧/s | 111.5573 |

这是单个完整帧的事务模型服务能力。双包候选相对同模型串行基线约1.97倍，具备30帧/s网络目标的局部服务余量；**未证明真实连续1080p30输入、RAW+显示/cache/快照的混合DDR服务、PC慢接收或板载千兆吞吐**。真实源帧率与完整网络帧率仍需分别验收。

缓存峰值：双包占用2（独立短包/最大包重叠测试），每银行2048 B，最大实际应用数据1464 B。每个包头发出前应用 CRC 已计算完毕，MAC开始前有完整包；没有以减小1400 B有效载荷、压缩、补旧像素或无界队列提高数字。

30帧/s预算仍为44,460包/s、62.208 MB/s有效RAW和约543.9024 Mbps线占用，属于格式计算而非实测。未启用快照/重传；集成能力回应必须声明不可用并明确拒绝相关任务。没有宣称60帧/s完整RAW走千兆链路。

性能原始证据：

- 双包最终回归：[result.json](../build/network_control_20261012/regression_20261012_172157_346117/result.json)、[network_result.json](../build/network_control_20261012/regression_20261012_172157_346117/network_result.json)、[完整 Ethernet 字节](../build/network_control_20261012/regression_20261012_172157_346117/wire.hex)、[源哈希](../build/network_control_20261012/regression_20261012_172157_346117/source_hashes.json)。
- 单包同口径对照：[network_result.json](../build/network_control_20261012/regression_20261012_161317_701645/single_bank/network_result.json)、对应目录的 `wire.hex/simulation.log`。
- 确定性源图及共享向量：`fpga/sim/vectors/network_control/source.raw`、[源图格式与SHA-256](../sim/vectors/network_control/source.meta.json)、`manifest.json`、首/跨行/尾PRAW包、MCU固件帧及错误流、奇数/偶数载荷 golden、ARP/FCS golden。均为合成仿真数据，不是实物采集。

## 125 MHz 隔离内部时序及资源

器件 PG2L100H / FBG676 / -6，PDS 2022.2-SP6.4 build146967。两个专用 timing top 用串行夹具装载宽配置，避免把内部总线全部当作物理管脚；保留实际业务、动态描述符和实体数据。结果含夹具资源，不能当成最终整机资源表。

| 最终候选 | Slow setup WNS | Slow hold WHS | Fast hold WHS | LUT | FF | DRM | APM |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| network_timing_top | +0.846 ns | +0.159 ns | 见原始min/max报告 | 2,716 | 3,026 | 1.5 | 0 |
| control_timing_top | +0.229 ns | +0.158 ns | +0.100 ns | 7,558 | 12,913 | 15 | 0 |

两份最终 `report_timing` 均为 `All Constraints Met`，setup/hold TNS为0。没有改变8 ns目标时钟，没有新增 multicycle 或放宽数据路径例外。只对 rst_n 排除异步复位输入；**所有外部IO延迟、电气和真实CDC仍未签核**。standalone timing top 不能下载到板子作为业务位流。

关键修复有可回看失败证据：网络初始 WNS -0.055 ns，最差为帧偏移→包长→IP校验和；在包边界寄存已知1400/尾包长度后最终 +0.846 ns。控制初始组合漂移除法 WNS -51.616 ns；改为两周期保守误差界后 -0.279 ns，继续分级 SYNC 四时刻、解析期限/时间戳提交、STATE 接受判断和姿态RAM读出→时间映射→选择比较，最终 +0.229 ns。收尾另修复切换会话不能批准旧配置、在途EVENT确认匹配冻结目标两种竞争场景，均有专项回归。中间负余量不计为达标。

最终 PDS 原始证据和不可变源码快照：

- [网络结果](../build/network_control_20261012/pds_network_20261012_161515_271304/result.json)、[网络min/max时序](../build/network_control_20261012/pds_network_20261012_161515_271304/report_timing/network_timing_top.rtr)、[网络资源](../build/network_control_20261012/pds_network_20261012_161515_271304/device_map/network_timing_top.dmr)。
- [控制结果](../build/network_control_20261012/pds_control_20261012_172123_018250/result.json)、[控制min/max时序](../build/network_control_20261012/pds_control_20261012_172123_018250/report_timing/control_timing_top.rtr)、[控制资源](../build/network_control_20261012/pds_control_20261012_172123_018250/device_map/control_timing_top.dmr)。
- 各目录的 `source_snapshot/`、`source_hashes.json`、`console.log` 与 post-PnR `.adf` 数据库。较早探索目录 `pds_network/pds_control` 及时间戳中间候选保留；初始直接导出548逻辑IO的试验因器件仅300 IO失败，不是合法资源结果。

network timing top 覆盖 MAC/ARP/仲裁/PRAW/帧发送，不实例化 DDR native adapter/RAW reader；control timing top 覆盖 UART/解析/会话/姿态/参数，不实例化双钟原子快照。RAW reader 和 CDC 的功能仿真通过不代表它们已经联合 PnR/CDC 签核。

## 执行过的回归

最终 Icarus 11 项全部通过（版本12.0 devel，具体版本字符串见每个回归目录 compiler_version.log）：

| 用例 | 已核验范围 |
| --- | --- |
| uart_v2_parser | 固件完整帧/逐字节分片、载荷magic、嵌套合法帧重同步、坏CRC/长度/版本、绝对超时、峰值2048 B与溢出恢复 |
| mcu_readonly_client | profile/能力拒绝与协商、OPEN/完整264B配置、200Hz请求、SYNC四时刻、重复/旧boot状态、两个逐字节相同重试、失败后要求新会话、两个在途EVENT累计确认、配置批准与会话切换竞争；无运动命令 |
| control_services | 坏/旧参数保留最后有效实体、帧中提交不生效、生效源身份与同边沿capture版本、冻结姿态、未同步/过期/无效角降级、来源枚举、满32状态队列 |
| uart_8n1 | 标称125MHz/460800，标称及±2%字节时序模型、假起始/坏停止位、256个TX字节独立回收 |
| ethernet_control | FCS已核验ARP回应、坏FCS拒绝、链路失效、三次有界重试、MDIO TA释放和读写 |
| network_cancel | 包中取消、输入缺服务超时、断链、DMA未排空不释放、释放ACK保持、重连源身份保持 |
| praw_packets | 1/31/1399/1400B载荷、奇偶UDP校验和、完整头CRC、FCS、双银行峰值2、非法CRC预填拒绝 |
| parameter_guard | 整实体CRC、符号/范围、模型不支持拒绝 |
| counter_snapshot_cdc | 不同相位/非谐波时钟50次整组冻结、消费阻塞时快照保持；仅功能CDC模型 |
| raw_dma_reader | 未对齐35B/stride64三行、跨beat/行、非零padding、舍入越槽拒绝、已发读请求的实际取消排空 |
| raw_network | 完整1080p源图→DDR读/去stride→ARP已建立→PRAW/UDP→MAC，全包全字节及IFG检查 |

上位机新增 `StreamDecoder` 与全STATE范围/来源校验，保留归一化XYZ、机械pitch/yaw与null q_wc；未建立实物身份或同步。MCU/流解析测试4项通过；原有transport测试37项中36通过、1项条件跳过，总计40通过、1跳过，包含本机127.0.0.1合成UDP回环和有界乱序/重复/丢包完整性。

控制接收峰值有压力证据；线长、30ms绝对期限和200ms请求期限有回归。SYNC采用带不确定度的偏移保持和保守漂移界，不宣称已做多样本仿射漂移拟合。参数生效等待合法边界（采集与几何各自实例），没有实测生效延迟。控制端到端最坏延迟、真实时钟漂移/误差、舵机反馈年龄与物理带宽仍须实板测量；不把200Hz发布率说成200Hz新反馈。

ModelSim 10.1c 曾完成新增模块编译；运行阶段无法取得Verilog仿真许可证，实际功能结果来自Icarus。沙箱内本地编译器曾报DLL重定位/异常退出，经自动审批在开发区运行后正式编译正常；沙箱内本机UDP测试失败，经同样范围的本机回环运行通过。最终日志/退出码全部保留，不把这些失败记为成功验证。

## 重建命令

```powershell
python fpga/scripts/sim_network_control.py --baseline
python fpga/scripts/build_network_control.py --group network
python fpga/scripts/build_network_control.py --group control
```

仿真脚本可覆盖 Icarus 路径；默认复用本工作区已有便携安装。PDS脚本先做带SHA-256的源码副本、显式指定工程/工作/报告目录，沿用安装工具和现有子进程许可证环境。PDS进程退出成功只表示工具完成，result.json的setup_hold_passed才区分内部时序达标。命令不调用下载器或生成位流。

## 官方资料与标准

只读核对安装版 `E:\PDS_Pangu\PDS_2022.2-SP6.4\doc\ADS_Synthesis_User_Guide.pdf` §5.16（PDF第94页的推断RAM方式）、`Simulation_User_Guide.pdf` §2（PDF第7页的行为/综合后/PnR功能与时序仿真区分）、`Timing_Analyzer_User_Guide.pdf` §4.1（PDF第14页的post-PnR数据库、约束和输出目录）。原始资料未编辑；仅在本开发区 reference 证据子目录渲染相关页面。

匹配MINI硬件指导手册V1.3第28/29页核对 RTL8211F、RGMII与板卡引脚；图中含PG2L200H，板卡兼容说明仍须按PG2L100H实物核对。此次没有推断PHY延时配置、电平或MCU连接脚。

标准头/校验和核对 [RFC 768](https://www.rfc-editor.org/rfc/rfc768)、[RFC 791](https://www.rfc-editor.org/rfc/rfc791)、[RFC 826](https://www.rfc-editor.org/rfc/rfc826)。DF=1、无分片的ID语义依据 [RFC 6864](https://www.rfc-editor.org/rfc/rfc6864)；未通过省略未协商UDP校验和修改协议。

## 下一步集成与未验收项

01 接入真正的RGMII双沿/延时/MDIO三态与速度轮询，建立RXC/发送/DDR及控制跨域握手与真实IO约束。03/04接入槽代次、请求票据、native完成栅栏/取消及混合DDR服务；02/06分别落实按采集/源帧处理边界锁定实体、曝光参考与实际几何映射。PC参数命令/配置实体/读回适配及FPGA MCU独立UART引脚、电平、实物F4/F1与时间映射仍须冻结、测量。

主工程仍保留原骨架，不宣称现有位流已提供业务网口或V2接口。没有真实1080p30输入、整机混合负载、千兆实板吞吐、摄像头/舵机/热稳定性、功耗和同帧HDMI来源验收；HDMI source_frame_id/pairing_status 保持 null/unverified，不从网络到达顺序配对。既有过温之后的上板/下载暂停条件继续有效。
