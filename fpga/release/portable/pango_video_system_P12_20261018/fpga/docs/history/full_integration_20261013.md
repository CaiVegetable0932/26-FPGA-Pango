# FPGA 完整集成工作记录（进行中）

当前目标是把优化后的 FPGA 模块连接到 MINI PG2L100H 的实际原生 DDR、相机、HDMI 和网络端口，并完成综合、布局布线与位流。用户已明确本轮忽略其他设备接线；MCU 外部接线不作为阻塞条件。**目前没有完成全部功能的位流，不得将旧集成骨架或本轮中间工程称为完整交付。**

## 已执行的连接与验证

- `ov5640_integrated_startup`：先读 0x56/0x40 身份，再完成模拟初始化、历史 RAW tap 3 配置核对、固定曝光及 stream-on 读回。SCCB 模型验证 362 次写、210 次读；错误身份时零写入。
- `frame_memory_fabric`：5 帧池、7 客户端、合法地址/代次/所有权和完整 masked write readback。取消读保留存储帧；写取消使部分帧失效。已验证错误、取消、背压、7 客户端争用和旧代次拒绝。
- `camera_frame_cdc`：两条独立有界 RAW8 队列，以及独立起始/结束握手。测试正常帧、RAW 队列单独满、短行及尚未释放时的后续帧，后续帧不能覆盖原上下文。
- `video_frame_scheduler` / `video_memory_core`：真实 RAW8 → FPGA ISP → 校验后的 S1 → cache 回填/几何 → 校验后的结果。35×33 常量 RAW 的全部 3,465 个结果字节与源身份一致；截断下一帧取消排空且不发布。
- `frame_writer_buffer`：有界像素/坐标 RAM，将源/几何流水与写请求/校验停顿解耦。几何三帧测试从 10,726 个模型周期降到 8,691；这是小帧模型数据，不是实板帧率。
- `projective_ray_stepper`：已将透视除法接入几何路径，保留 S(40,26) 分子。512 像素测试覆盖非恒定分母、背压和负深度；与独立整数除法相比，归一化射线误差不超过 2 LSB。
- `pc_video_boot`：使用现有 PC 专用 V1 / 0x71 启动实体，与已撤销的 MCU_POSE_V1 无关。真实串口模型核对启动、42 字节 ACK 及 CRC；重复启动不能覆盖 epoch/地址。运行期未支持命令明确返回错误。
- `gmii_receive_cdc` / `display_frame_cdc`：验证整包跨独立/停钟域、满 bank/接收错误整帧丢弃、原子显示 offer/release 和延迟 ACK。

默认网络与相机配置来自 `reference/`、现有板级约束及历史提交 `c8c7206e7cac338b7d5778a9edf278031a1418d2`，只读原资料。原生 PDS 资料文本及来源 SHA 保存在 `fpga/build/full_integration_20261013/reference/`。相机模式和镜头系数仍是参考候选，未经本轮实板/光学确认。

## 已完成或失败的 PDS 记录

- 单元帧池综合：`pds_20261013_144934_696493`，28,457 LUT、13,257 FF、0 APM、0 latch；收窄动态客户端索引后消除了先前的 80 个无必要乘法器。单元的 25,708 个抽象 I/O 不代表板级引脚。
- 板级编译：`board_20261013_152142_951026`，原生 compile 成功、源快照完整；不是综合/布线/位流成功。
- 第一次板级时序流程：`board_20261013_153355_716057`，compile 完成，综合前因三个层级通配端点未匹配而停止，**失败**。已依据安装版本 UCE §2.4.1 加入 hierarchical 匹配，并将显示 urgent 改为真实 running/full 寄存器来源；不删除相关 CDC 约束。
- 修正后的原生总体流程 `board_20261013_160011_497946` 因 ADS 不支持 `for(integer k...)` 的语法而在 parse 阶段失败。已把透视模块循环变量移到模块声明，不改算法；需重新执行总体构建。
- 1920×1080 实际像素量主链路 RTL 仿真 `sim_20261013_154429_578462` 达到 1200 秒运行上限，**未通过/未完成**。这不能证明服务期限或排除状态机卡住，需要保留模型进度并改进仿真效率后继续诊断。

## 尚未完成的范围

当前板级顶层 `pango_video_system.sv` 已连接单路 RAW8、S1、镜头/透视逆映射、结果、HDMI 与 S0 网络，但运行期参数/LUT 控制、同源 S1/结果快照导出、MCU V2 姿态到经校准几何映射仍未完成。参数实体及 LUT 要按源帧保留，不能靠实例化未连通模块宣称实现。机械 yaw 不作为图像 roll；无 MCU 样本明确降级。

125 MHz 原生 DDR 域的模型/混合吞吐、实际 1080p30、输入峰值及最大 DDR 无服务时间尚需证明。外部 DVP/RGMII/HDMI 电气延时、本机 JTAG 连接、温度、功耗、实板帧身份和光学精度均未在本轮验证。本轮没有烧录操作，也没有把旧候选位流重命名为完整工程。

集成网络取消恢复回归 `sim_20261013_160721_837583` 通过：链路中断时读事务排空并释放 RAW 引用，恢复后再完成下一帧。修复了旧 `reader_failed` 跨帧保留而阻止新 frame_ready 的问题。

板级构建 `board_20261013_161055_954675` 原生综合成功：34,713 LUT、28,262 FF、99 APM、50.5 DRM、0 latch、115 个实际 I/O。PnR 因 `Place-0089 REGION_CLOCK` 停止，尚未布线成功。正在分离原生区域 serializer 时钟与同源全局像素业务时钟，保留两者相关数据路径 STA；不得以综合资源报告宣称布线/位流完成。该快照尚未包含随后 64 位 ticket 修正。

64 位 ticket 回归 `sim_20261013_162936_098683` 通过：跨越 32 位边界、截断旧完成拒绝、64 位终值不回绕，并回归帧池及真实视频主链路。命令/响应内部布局由 `generate_frame_manager_layout.py` 统一再生成；UART/PRAW 格式没有改变。

## 2026-10-13 18:30 更新（仍在实施）

主板顶层现在连接真实 RAW8/S1、透视与镜头单次逆采样、历史 RGB 曲线 pre/post 模式、统计、RAW 网络、HDMI、PC 模式/几何实体控制，以及同源 S1/结果独立快照复制/导出。PC 的几何提交校验全 17 个定点系数、版本、ID、CRC32；源槽保存系数，待处理旧帧不读取新活动总线。PC 回读活动几何、两幅快照描述符及快照保留的旧几何实体；串口模式实体仍按源边界提交。MCU 物理接线按用户最新范围暂忽略，元数据 pose_status=1（无样本），未实现经实测外参的运动补偿或把机械 yaw 当作 roll。增强是用户选择的固定参考曲线，不宣称已实现自动 Gamma 或光学标定。

实际验证：

- `sim_20261013_173833_894765` 与 `sim_20261013_173457_967850`：运行期模式及串口状态通过。
- `verilator_20261013_174439_155102`：1920×1080 三帧增强切换通过；每帧检查 6,220,800 RGB 字节，几何模型 3,796,975 周期，125 MHz 约 30.376 ms。
- `sim_20261013_180925_364223`：真实串口模型 12 个回复，CRC/忙态/零焦距负例及几何实体提交通过。修复了纯常量 `always @*` 空敏感列表的测试缺陷，改为明确生成式连续边界连接。
- `sim_20261013_180322_204315`：退休流水、帧池/ticket64 与快照回归通过。退休选择和 64 位 payload 分开注册，adapter done 仍等帧池 ACK。
- `sim_20261013_180553_789311`：PCLK epoch 本域捕获、像素 offer 本域捕获及 DMA CDC 回归通过，约束只改到实际捕获寄存器，不扩大时序豁免。
- `sim_20261013_182139_614002`：快照与旧/新几何参数按帧保持的小帧混合回归通过。
- `verilator_20261013_181309_675572`：真实 1080p 字节量的一组快照和三帧增强混合回归通过，338 ms 模型时长；它不是持续实际 30fps 验收。原 300 ms 仿真上限的 `verilator_20261013_180400_480341` 超时，保留为失败；两幅 12.4 MB 复制/网络导出加三帧超过原上限，600 ms 重跑完成。
- 主机 `host/reports/fpga_rgb_vectors_20261013_182248_215664.json`：真实主机 PRAW 解码器检查 8,888 个合成 RGB 快照报文，CRC、身份、字段、全部 12,441,600 字节与有序覆盖通过。所有数据明确为合成仿真，未采集相机图像。

PDS：`board_20261013_173511_529954` 原生综合 37,809 LUT/105 APM，布局布线 15 分钟超时，失败；根据报告修复 rr_complete→issue/ticket 长组合链与两个实际 bundled-data 捕获遗漏。`board_20261013_180554_739832` 含动态几何/快照的原生整体综合已完成，52,849 LUT（79.35%）、46,415 FF（34.85%）、123 APM、58 DRM、0 latch、115 实际 I/O。该冻结源早于后续快照元数据读回/参数边界更新，不能作为最新发布位流。仍需新鲜完整快照的 native PnR/min_max、相关时钟/CDC/源哈希检查和 bitgen。**当前没有本轮完整位流，没有烧录，没有实板验收。**

## 19:50 精确透视与时序收敛更新

`board_20261013_183255_306115` 的综合 DDR WNS=-3.156 ns，实际最差为 seed ROM→mr0 宽乘法，尚不能交付位流。以原生 25×18 APM 输入界限拆分整数乘法，32×32 使用 3 级，40×48 使用 4 级；完整数据与标签共用 CE，不以截断减小时序路径。随后将归一化的舍入/移位控制、最终倒数指数恢复分开寄存，总共26级且II=1。

新增全 signed40 正深度范围黄金检查，原 Q26 指数恢复在大深度下出现 23/-10 LSB 误差（`sim_20261013_194013_939697` 失败）。增加8个倒数小数位到 U(48,34)，保留完整88-bit numerator product，输出移位40恢复 S(24,20)；合法范围的倒数量化对输出贡献≤0.25 LSB。4096 个深度/符号/舍入边界与背压测试及非恒定透视512像素均通过；Python模型、测试与向量已同步。

`math_20261013_194420_759783` 原生算术单元综合：125 MHz 目标，估计 Fmax179.9532 MHz、setup裕量2.443 ns。它是带抽象注册I/O的逻辑诊断，不是完整板级PnR或外部IO签核。完整实际顶层新构建为 `board_20261013_194832_288274`，正在执行受保存min/max报告门槛保护的bitgen流程，尚无位流成功结论。

全帧 `verilator_20261013_191251_145122`（前一24级、Q26冻结源）通过，三帧/独立快照和旧几何参数保留，末帧3,809,428周期≈30.475424ms（理想DDR），host独立解码8888包、12,441,600RGB字节和两条完整描述符通过。最终Q34/26级仍要单独完成同源完整帧回归及总体STA，不能外推。

17条运行期串口命令在冻结RTL上通过：活动/旧快照几何、两图描述符的跨页读回、交错命令拒绝、忙态、CRC与焦距负例；host记录 `fpga_rgb_vectors_20261013_184159_902830.json`。RAW/ARP/PRAW/串口兼容性回归 `regression_20261013_183553_744229` 全11项通过。仍未烧录或采集实际图像；自动Gamma/动态LUT上传、MCU外参补偿和独立按键等整机目标不能写成已验收事实。


## 21:38 板级时序与资源优化更新（仍未完成位流）

`verilator_20261013_202330_998813` 已通过完整1920×1080三帧、独立同源快照和旧/新参数保持，末帧3,943,093周期≈31.544744ms（125MHz、理想DDR）。主机 `fpga_rgb_vectors_20261013_203628_440420.json` 独立检查8888包/12,441,600 RGB字节及描述符通过；它对应新增 admission 寄存级后的冻结RTL，并非随后地址/解包优化的验证。

`board_20261013_203613_606045` 综合54,105 LUT、51,149 FF、126 APM、58 DRM、115实际IO、0 latch。原生最差 DDR setup=-2.055ns，实际路径是 geometry.expected 别名维度寄存器→refill源跨度乘法→范围检查→state。保留 SYN/MAP 检查点和失败结果，终止该旧源布局任务，不能发布旧文件。

本轮调整：源跨度在独立VALIDATE/SPAN级检查、行地址递推；保留完整64位越界验证和17位tile_x，不接受高位截断的非法图块。帧池将停机门控移至最终响应/寄存器更新，避免故障经过release/issue组合链。两个实际板级网络 reader 使用验证过的32字节对齐行模式，替代不必要的512-bit移位拼接；通用非对齐实现保留。图块/处理器/核心快照控制 `sim_20261013_213115_632423` 通过（早于最后的等价 last_row_index 表达式调整）；帧池/ticket/core `sim_20261013_211856_379457` 通过。

DMA三随机种子 `fpga/build/ddr_dma/20261013_213812_063/results.json` 全8场景×3通过，含对齐/非对齐独立字节黄金检查、partial tail、随机stall及取消排空。此前脚本单参数数组及测试诊断层级错误的日志保留为失败，修正后重跑通过。`sim_20261013_212555_668172` 同时开启link-loss与control的非兼容刺激超时；两个刺激各自保留display/重复使用帧身份，不能组合，入口已明确拒绝该配置并分开回归。

构建脚本修正：PDS在Tcl解析阶段执行普通文件读取，之前在flow.tcl内插入读取未来.rtr的门槛产生Flow-0163；19:50所述“受门槛保护”并未实际成立，相关构建全部保留为失败。现在先完成native min/max，再在Python门槛后，以安装版本官方help支持的 gen_bit_stream -force_to_run -input_db_file 对同一PNR数据库生成文件；此标志只跳过独立工程的流程状态，不跳过STA。数据库和报告生成前后SHA256相等才接受。以旧骨架STA已通过的数据库离线验证该官方调用成功，并未把探针生成的旧骨架当作新完整位流。直接STA探针同样在原约束下All Constraints Met。官方资料目录未修改。

最新冻结板级构建为 `board_20261013_213812_212509`，同源完整帧回归为 `verilator_20261013_213813_114594`，均仍在执行。需要新源完整回归/原生总体min_max/bitgen均通过后才能打包；目前仍没有本轮可交付完整视频位流，没有烧录或实板验收。


### 21:50 新冻结源验证结果

`verilator_20261013_213813_114594` 完整1080p三帧、disabled/pre/post、同源RGB快照与旧/新几何参数保持通过；6,220,800目标RGB字节全部检查，末帧3,959,558周期≈31.676464ms（理想125MHzDDR），346ms合成时间。与 `board_20261013_213812_212509` 共有的70份RTL SHA256全部一致。host `fpga_rgb_vectors_20261013_215038_876276.json` 独立确认8888包、两图12,441,600字节、CRC、stage/identity、两条描述符和快照保留的旧几何通过；未采集或转发实物视频。

在该板级实际冻结源上的 `sim_20261013_214259_704896` 帧池/图块/核心RAW断链恢复均通过。`regression_20261013_214148_484006` 全11项网络/串口/参数回归通过。尚待native总体PnR与min/max，并无新可交付位流或烧录结论。


## 22:55–23:04 确认流水与仲裁/原生恢复更新（未完成位流）

新增G_TAG在DST allocation前锁存128位同源身份比较；银行token接受的client/token/ticket先寄存再送客户端，退休银行commit后撤销COMPLETE，下一拍才ACK持有的native done。对应 `sim_20261013_222056_914348` 帧池/票据/核心快照控制通过。`verilator_20261013_222334_274700` 完整1080p三帧/同源快照/旧新参数通过，末帧4,059,183周期≈32.473464ms（理想DDR），363ms合成时间。host `fpga_rgb_vectors_20261013_224448_818729.json` 8888包、12,441,600字节及描述符/旧几何独立解码通过；仍不是实物验收。

`board_20261013_222334_491811` SYN/MAP原生退出0，49,182 LUT（73.85%）、51,083 FF、125 APM、58 DRM、115 IO、0 latch。DDR估计setup=-1.224ns，实际 rr[0]→native DMA beat_index CE。随后把每客户端的loaded/beats比较放在本地常量索引上，轮询只旋转一位eligible向量，并明确client索引宽度；不增加事务延迟。`fpga/build/ddr_dma/20261013_225043_335/results.json` 混合请求/公平配额/取消/背压等8场景×3种子通过。

原控制链长度4过于限制控制网络共享，按安装User Guide参数默认表恢复CE/RS chain=500；时钟8ns、min/max报告和发布门槛保持。`board_20261013_213812_212509` 前一版本详细布线60分钟超时（Flow-0232），有错误且无总体STA、无可发布位流。其结果 native_exit=0 不能抵消E错误，发布脚本拒绝该运行。

独立PnR恢复 `resume_20261013_225349_932154` 因新建项目遗漏DDR IDF上下文，PHY SERDES固定放置Place-0006失败；保存为失败。恢复脚本已重用原flow.tcl的全部RTL/IP注册及约束顺序（仅去除compile以后任务），再以官方force_to_run/input_db_file读取已有map，不重新综合。新的恢复仍待验证。单独bitgen直接PNR数据库的方法已在旧STA通过图像上离线验证成功，不受此PnR IP上下文问题影响；不会将旧探针图像作为新集成位流。

最新RR整理冻结源 `board_20261013_225542_747633` 与完整帧模型 `verilator_20261013_225544_544769` 正在执行；共有RTL需精确哈希匹配后绑定结果。没有新发布包，没有烧录。

## 2026-10-14 继续布线：已定位详细布线拥塞

最新冻结源 `board_20261013_225542_747633` 的 SYN/MAP 已完成；与 `verilator_20261013_225544_544769` 的70份共同RTL逐份SHA256相同。完整1920×1080三帧、快照与运行期控制回归通过，末帧4,059,183周期（125MHz理想DDR下32.473464ms）；主机 `host/reports/fpga_rgb_vectors_20261013_231044_580319.json` 对该确切模型的8888包、12,441,600RGB字节、同源身份、两条描述符及旧几何实体独立解码通过。以上全部为合成仿真，未进行硬件验收。

补充更正上节恢复依赖结论：仅恢复RTL/IP注册前缀仍不能固定DDR PHY。独立输入map数据库时还必须加入 `device_map/pango_video_system.pcf`；原生项目模式自动消费该物理约束，独立动作不会。加入生成PCF后DDR固定站点与布局成功。此依赖不改变板卡引脚或时序要求。

`resume_20261014_002837_578583` 从完成的放置数据库恢复、允许本机180分钟，原生实际运行106分钟后以 `Route-4022: Routing failed as its congestion`、`Route-0008: Design cannot be routed` 失败，并非超时。全局布线未布通数收敛到0；详细布线114350个子网络仍有74186个未布通，迭代7累计耗时明显增长。失败物理报告使用47699 LUT、51105 FF、125 APM、58 DRM、115 IO，CLMA10207/11675与CLMS4352/4975均约88%。LUT占用不足以证明可布通；当前没有可用的新PNR数据库、总体STA或新位流。

依据安装版本 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Pango_Design_Suite_User_Guide.pdf` 印刷页111–118及原生pnr help，新增恢复参数与拥塞诊断：Placement Decongestion可选0..9，主要资源超过70%时官方建议0..4；新seed只作用于新布局；Dump Router Congestion Plot输出逐轮冲突节点/网络。新运行 `resume_20261014_105446_177143` 从同一map重新布局（decongestion2、seed11、normal、control chain500、拥塞诊断开启），不再复用原拥塞plc。先保存原失败DB及物理报告，再运行新尝试。8ns业务时钟、CDC范围、min/max签核与位流生成门槛保持。**仍未生成新的可下载集成位流，未烧录。**

## 2026-10-14 11:23 新候选冻结与验证记录

帧池metadata/order与token slot/gen/owner拆到仅时钟写入的数据块；有效所有权与generation/ticket饱和隔离状态保留原复位。metadata只有完整allocation后有效，immutable字段仅分配时写，capture_last/errors使用原seal/cancel/error优先级。新增台架在联合冷复位已清除DDR工作后，保持ready高及命令、注入无效payload=X，验证空闲输出和首次allocation/issue/acquire。`frame_manager/sim_20261014_111151_879` manager/pressure/mini三项通过。

中间冻结 `board_20261014_110305_536073` SYN实际46990 LUT（70.56%）、50380 FF、125 APM、58 DRM、115 IO、0 latch；异步复位且有CE的FF从旧33075降至27649，控制组数742，不能简单声称控制组总数减少。`verilator_20261014_110305_171238` 完整1080p三帧、快照与控制通过，末帧4,014,191周期（理想DDR、125MHz下32.113528ms），70份共同RTL与该board哈希一致。`host/reports/fpga_rgb_vectors_20261014_111810_897717.json` 同一模型的8888包/12,441,600RGB字节与完整描述符独立解码通过。该快照还未包含后续快照错误清理和算术块拆分，不用于最终发布。

独立原快照台架发现EXPORT错误清理停滞：导出S1读取出错后S1仍被NETWORK持有，第二幅图的pending claim未取消。完全同一台架使用旧冻结board225542帧池也超时；诊断metadata无X，state=EXPORT，错误S1 occupied=1/ready=0、第二图仍ready。证据在 `frame_manager/snapshot_reset_audit_20261014_110756_398`，原失败保留。修复只在occupied且ready=0的银行判失效，正常已释放第一图occupied=0不会取消第二图；进入原ABORT/CLEANUP仍保护已接受的NETWORK引用。service停止获取已取消第二图，WAIT无已接受读时明确release，ACTIVE仍走原读排空后release。`frame_manager/sim_20261014_111630_663` 原all四项全通过：manager1755、pressure5755、snapshot237checks/2pairs/4failures、mini144；快照错误台架未绕过或改写。

数值流水原无reset值的payload留在async块，compile日志Sdm-2014明确生成hold feedback mux。将perspective/lens的payload移到posedge-only的rst_n&&advance块，保留valid/ok及公开坐标的异步复位、共同advance、所有溢出优先级、级数与完整精度。seed_rom只有256项，初始化循环原266次，现明确256；未把没有原生日志支持的越界写说成工具已经报错。`sim_20261014_112208_408631` 透视完整合法域、非恒定projective及frameprocessor三项通过。实际新增资源收益仍待新SYN测量。

当前最终候选冻结为 `board_20261014_112317_150547`，同源完整模型 `verilator_20261014_112317_303788` 和独立网络丢链回归已启动。旧board225542的seed11/decon2仍仅作物理拥塞诊断；所有后续发布必须绑定包含上述修复的确切新快照、总体min/max通过与同数据库位流。没有新可交付位流，没有烧录，所有模型结果仍是合成数据。

### PG2L100H 参数列与拥塞证据补充

初读平台参数表时漏读了印刷页117的专属脚注，曾将“普通Logos2无congest_overlap_limit选项”误用到本器件。原文明确“PG2L100H是单线程布线器件，它的general，router选项与Logos的选项一致”。印刷页118 Logos列的Max iterations in congest mode默认200；因此脚本下一次PnR明确使用200，之前20不是该器件官方默认。当前已启动的诊断尝试不为此打断；恢复脚本记录确切显式参数。正式资料SHA256与reference提取登记一致，官方目录未修改。

诊断尝试 `CongestionNetInfo/CNI_2` 含84648条冲突记录、67926个唯一网络，不能等同未布通subnet数。帧池管理层10181条（12.03%）、几何层14867条（17.56%），峰值记录是banks0.pool/N767=218。管理层只有描述符/所有权/代次/票据，没有像素存储，但大量自动N名无法区分reset/enable/data；不能由命名猜测“拥塞主要是复位”。诊断用于评价已实施的帧池与流水数据控制改良，不作为新位流已完成的证据。

### 最终候选模型通过、SYN完成（2026-10-14）

`board_20261014_112317_150547` 原生SYN实际46499 LUT（69.82%）、50386 FF、125 APM、58 DRM、115 IO、0 latch；compile Sdm-2014从1283降至966条，减少317条不是317个bit，不能按告警数推算寄存器节省。与 `verilator_20261014_112317_303788` 70份共同RTL全部同SHA256。该最终模型完整1080p三帧/同源快照/参数控制通过，4,014,191周期、362ms合成时间、683.068秒墙钟。主机 `host/reports/fpga_rgb_vectors_20261014_113851_335576.json` 精确绑定该模型的8888包、12,441,600字节和描述符通过。`sim_20261014_112317_317471` 帧fabric/ticket/core网络丢链恢复三项通过。

旧源seed11诊断在完成CNI_2热点定位后主动终止，仅停止命令行路径匹配该旧board的PDS PID31856/29000，保留原日志、plc和拥塞数据；非零退出4294967295记录在 `resume_20261014_105446_177143/termination_note.json`，不能把此主动终止说成新一次Route-0008完成结论。最新候选SYN/MAP进程未停止。新位流仍取决于其自身PnR/min_max/bitgen通过；目前没有新可下载位流。


### 2026-10-14 12:35 布线状态与独立估计诊断

最终候选 resume_20261014_114346_235148 完成放置并进入详细路由：global routing最后unrouted=0，详细iteration3剩余82375、总115236 subnets，原生进程仍计算。全局路由清零不代表完成详细布线，当前没有PNR签核数据库或新位流。

独立PLC诊断 placement_timing_diag_20261014_115943_459599 使用只读复制的plc/pcf，native_exit=0，但2324条报告路径中2322条数据route delay为0。setup估计+2.675ns不能作为布线裕量；DDR removal=-2.642ns、DQS gate hold=-0.843ns也仍是未布线估计，待最终STA核对。memory_armed到直接PHY复位端点的假释放边沿已按源码/网表证明为不可达，证据在build/full_integration_20261013/reset_removal_audit_20261014_123500.md；未修改RTL/FDC或扩大false path。

PCF115个端口对应115个唯一pad，71个DDR端口与MINI V1.3资料匹配。CCR的61项Critical包括33项shared pin位置提示与28项缺失DRIVE/SLEW提示；没有重复pad错误，仍不能据此宣称全部外部电气属性或IO时序已验证。发布将保留CCR和原约束。


### 12:50 位流配置审计和发布门槛补充

安装版官方PDS guide的Persist Pin默认Release For USER；当前115IO中G25/N21分别落L4/L5，官方p149说明两bank均使用时SCBV无效。独立审计 bitgen_config_pin_audit_20261014_124449_986253 保存原始MINI映射单元格和官方页码；High Voltage不能据此宣称外部3.3V或DDR1.5V电气已验收。

发布脚本新增对实际generate_bitstream/bgr.db（XML）的器件/顶层/共享引脚/CRC/DRM设置校验，以及.bgr安装版本和最终routed DB/新输出路径核对；归档实际配置与日志，并在manifest保存原生配置表。用旧同版本probe验证XML格式解析成功，同时新pango_video_system身份门槛拒绝旧pango_video_top，未对旧产物执行发布，也未生成新位流。

原生详细路由完成iteration4：未布通80578/115236，iteration CPU1041.421875秒；主进程继续。中间CNI3的81269条冲突记录/66052唯一net与未布通subnet是不同统计，frame_manager9204条按层级归类约11.3%，不能作为路由签核。


### 13:15 隔离存储/报文后备优化结果

frame_metadata_ram_probe_20261014_122916_925816 的原始与候选帧管理/压力/快照回归，以及新增四consumer跨槽读取+并行SEAL/ALLOC全616bit对照均通过。整frame_manager_bench在baseline compile/DFF-inference真实1800秒超时，没有SYN资源对照；未把该限制说成candidate RAM推断失败。改用相同SLOTS3/TXNS4/full616/fourconsumer/8ns的singlebank台架，baseline原生7115LUT/6570FF/0Distributed RAM，candidate6660LUT/5184FF/1072Distributed RAM，native均exit0、无E。仅单元实际改善，尚无整板资源/布线结论；准备隔离整板MAP测量，不改live/frozen。

praw_payload_probe_20261014_125132_853 将无reset packet payload写者拆到clock-only。原始与候选tiny golden/network取消/完整1080p双bank和单bank全部通过，报文字节与周期完全相同；reset/flush差分12845周期通过。单位SYN原始1289LUT/1309FF/1DRM/20controlsets，候选1290LUT/1309FF/1DRM/20controlsets，maxfanout均491，Sdm-2014从676到0。因没有资源/控制组收益，保持此项仅为隔离诊断，不推广live。初collector误将#Install中的E:盘符当错误，保存原collector与初结果后按行首原生E格式修正，没有重跑或隐去原记录。


### 13:24 最终112317候选本轮原生路由失败

resume_20261014_114346_235148 以Route-4022拥塞/Route-0008不可布通失败，不是超时。详细iteration5仍79655/115236，该轮CPU2204秒；detailed routing3672.77秒、total routing3945.88秒。失败后的原生物理统计CLMA11081/11675（95%）、CLMS4772/4975（96%），46054LUT/50437FF/125APM/58DRM/2200DistributedRAM/115IO。不能由SYN LUT69.82%推断物理可布通。原生还在保存失败数据库/锁，暂让进程自然退出，保留plc/prr/CNI/fail_pnr，不进入STA/bitgen。

RAM候选已从有效短路径frame_metadata_ram_probe_20261014_122916_925816/b_131632继续实际整板compile/SYN/MAP，冻结290文件完整、只有framepool差异。相同源的完整1080p/control/snapshot模型verilator_20261014_131925_145919已启动。首次更长路径副本FileSystem-0003保留；文件存在，短副本确实越过该读取与RAM推断，不能把路径失败当作RTL或RAM算法失败。当前仍没有新位流。


### 13:32 RAM整板同源完整模型通过

verilator_20261014_131925_145919 基于b_131632/source的完整1080p/control/snapshot回归通过，6220800目标RGB字节/good3/processed3，geometry4014191周期与112317模型一致；362ms合成时间、686.283s wall。host fpga_rgb_vectors_20261014_133220_915180 验证8888报文/12441600字节/描述符，两个bin SHA也与基线一致。root重新核对native290份冻结文件与model全部文件未变化，70份共同RTL全部同SHA。没有实板测试。

旧主87843自然exit1，snapshot_intact=true，停止在place_route门槛，未调用STA/bitgen。官方参数短报告placement_options_audit_20261014_133116_664626建议新MAP先decon1/seed11保留default packing；两旧轮RTL/seed也变了，不能单归因decon3。新RAM MAP结果仍待完成，当前没有新位流。


### 14:19 单槽后备模型通过，但原生多槽RAM回退FF

s1ff_b_20261014_140019 的完整模型verilator_20261014_140424_086719 full/control/snapshot通过，3good/3processed/6220800目标字节/4014191geometry cycles；host fpga_rgb_vectors_20261014_141859_967677 解码8888包/12441600字节与描述符通过，两个bin SHA与原版一致；70份共有RTL和实际290冻结文件均重新校验intact。仍是362ms合成模型，wall799.350秒，不是实板帧率。

实际SYN46009LUT/50344FF/2200DistributedRAM/125APM/58DRM/control742；frame_manager所有五bank metadata RAM全0，原型多槽RAM也被回退FF。它是功能等价的all-FF资源结果，不能称为已经实现多槽RAM+单槽FF混合。源保持冻结并继续MAP；另隔离修正直接动态RAM读边界，先用单位SLOTS3/SLOTS1及全部既有台架确认，不动live或两套已运行PnR。


### 14:40 直接读混合存储候选冻结

hybr_20261014_142347 的原3台架/四consumer多读口/单槽全部两份通过。原生单位SLOTS3保留1072RAM：6660LUT/5184FF→6655LUT/5184FF；SLOTS1确实移除全部RAM：5272LUT/4699FF/1072RAM→3805LUT/5161FF/0RAM，controls16→17。单位结果不能外推整板，源SHA2885a5979bdf5d60f444cc82ec340d7e65e39da768109dc4bc2a3e6f2a860f71。新完整frozen290文件hybr_b_20261014_143515保持唯一framepool差异，正在compile/SYN/dev_map；同源完整模型verilator_20261014_143950_084390已启动。未发第四个PnR，现有原版/RAM两轮仍在实际详细路由；未生成位流。


### 15:18 混合存储整板验证完成并进入布线

hybr_b_20261014_143515 原生MAP通过：46154 LUT、48021 FF、2801 distributed RAM、125 APM、58 DRM、115 IO；相对原版减少337 LUT和2354 FF，增加601 RAM。多槽池324/179/98个metadata RAM，两个单槽池为0。完整1080p/control/snapshot模型verilator_20261014_143950_084390与host/reports/fpga_rgb_vectors_20261014_150059_378477.json均通过；网络恢复sim_20261014_150242_422914三项通过。

15:14进程清单已无前两轮PDS/Python，统一会话也失效。日志分别停在详细iteration5/79384及iteration6/73979，未出现原生完成结论，记录为中断而非路由失败。保留全部证据，不重复运行旧候选。混合版本resume_20261014_151539_697611已启动新布局布线，decon1/seed11/normal/ctrl500/congestion200，时钟与约束不变。尚无新位流或实板验证。


### 15:36 同网表布局对照与数据延迟线优化

混合存储同MAP副本phys_20261014_151852_531451已启动decon0/seed11，与hybr_b_143515的decon1保持同一MAP SHA bb497969aeec0b86820ec1f25e0440fce297b584fd23883d3f364e9d69f6edc8、PCF及290份源。两轮尚在布局，未生成位流。

单独添加syn_srlstyle属性（含packed vector形式）实际没有RAM收益，保留原记录而不推广。改用官方ADS §5.16显式LUT RAM、不同读写地址和注册输出，保持原来的accepted-advance延迟及有效位刷新合同。透视单元4142FF→1747FF，LUT1533→1595，56RAM；9988次随机停顿/复位差分和4096点全深度精度通过。镜头单元2901FF→1194FF，LUT1679→1760，72RAM，9939次差分通过。两者APM不变；这些是单元测量，尚不是整板收益或布线结果。

冻结delay_20261014_152919仅加透视RAM，delay_20261014_153410再加镜头RAM；两份正在原生compile/SYN/MAP和各自同源完整1080p/control/snapshot验证，现有布局任务未改源或约束。镜头单元台架显式32位标签，正式源恢复原通用默认192位；板级实例仍显式使用32位。


### 15:49 两份延迟线版本完整模型及报文通过

delay_152919与delay_153410各自完整1080p/control/snapshot模型均通过：3good/3processed、6220800检查字节、4014191 geometry cycles、362ms合成时间；墙钟721.456秒与770.077秒。对应主机报告154309_635210和154849_807880均通过8888包/12441600字节，两个bin SHA与先前基线完全相同。重新核对两份native290源与model实际文件均intact、70共同文件同SHA。组合版本sim_153554_333469六项几何/所有权/票据/断链恢复回归通过。原生整板MAP尚未结束，无新位流、无硬件验收。


### 16:05 组合优化MAP完成，正式RTL同步并启动PnR

两份delay候选均native_exit=0、errors=[]、snapshot_intact=true。组合delay_20261014_153410映射完成，耗时1439.096秒；其已验证的frame_pool_bank、perspective_divide、lens_inverse_map三文件按SHA校验后同步到正式fpga/rtl，未覆盖其他独立修改。具体新旧SHA在该build/promoted_source.json。

组合版本新PnR resume_20261014_160518_945164 已启动，保持8ns、原始IP与引脚/时钟约束，decon1/seed11/normal/control500/congestion200，后续只在真实routed min/max通过后生成位流。当前未生成新位流，未烧录；原混合版本decon1/decon0两轮继续详细布线。


### 同MAP decon0对照主动结束

2026-10-14T16:10:01.765922+08:00：decon0详细iteration3未布通79019/108935，CPU795.75秒；同MAP decon1同轮75550/111464、CPU63.1875秒，当前已进到iteration8/62357。为集中资源给较快基线和delay_153410组合版，核对PID12316、父PID39312及精确build命令行后，仅结束对照子进程。保存termination_note.json；此为主动结束，不能称为原生路由失败，也不能断言decon0最终无法布通。


### 组合网表 decon2 独立对照

2026-10-14T16:18:18.603797+08:00：phys_20261014_161729_818241/resume_20261014_161747_780579 使用与delay_153410完全相同的MAP、PCF及290份源，只把decon1改为2，保持seed11和其他参数。MAP SHA28bf22ff10a8ff38c56f3147a7e70c98f711adf90000ad29fd82840095c648af。尚无原生路由结论。


## 2026-10-14 17:50 相对顺序矩阵整板候选进入物理实现

`delay_20261014_171555` 仅改变冻结 `frame_pool_bank.sv` 的内部先后顺序表示；64 位 next_order 耗尽围栏、票据、代次、完整描述符和消费者规则保持原值。单位差分为 12013 周期/234303 检查，覆盖低号槽复用、并发、隔离及饱和边界；一槽资源不变。详见 `frame_order_matrix_probe_20261014.md`。

整板 SYN 45941 LUT/43362 FF/2929 distributed RAM；MAP 45925 LUT/43351 FF/2929 distributed RAM/125 APM/58 DRM/115 IO。相对双几何延时优化版本减少 566 LUT、577 FF。完整模型 `verilator_20261014_171627_099539` 与上位机校验 `fpga_rgb_vectors_20261014_172833_401973.json` 通过；3 帧、6220800 检查字节、4014191 几何周期，以及 8888 包/12441600 字节同源 RGB 快照通过，生成字节与此前版本一致。全部 290 个 native/71 个 model 输入及 70 个共同 RTL 的实际 SHA 核验通过。模型仍为合成输入，非硬件测量。

为该版本提供布线资源，精确核验 PID42384/parent42912 后有意停止 `phys_20261014_161729_818241` 的 decongestion=2 比较任务；记录和此前 PLC/CNI 保留，返回的 Flow-0189 是人为停止结果，不能认定为原生拥塞失败。A/B 两个现有布线任务继续。新版本从 MAP 开始 decongestion=1/seed11/normal/control500/congestion200/dump，native 和 host 时间上限均为 0；保持全部约束，必须原生 PnR、直接 min/max STA 通过后才生成位流。目前新版本只开始布局，无新位流、无烧录。


### 17:57 相对顺序矩阵正式源及恢复回归

`sim_20261014_175002_330425` 的 fabric（28 checks）、64 位 ticket rollover（6 checks）及 NETWORK_TEST=1 的 core（3465 byte/3 good/2 processed）均通过；会话51686自然退出0。B/D全部290份源及62份共享回归RTL实际SHA intact，见 `frame_order_D_recovery_review_20261014.md`。经live旧SHA2885a597和候选SHA37f58307双重guard后，将D的frame_pool_bank逐字节同步到正式RTL，不修改任何正在运行的冻结源。完整模型和报文校验已通过，原生仍在物理实现，未生成位流、未烧录。


### 18:14 新相对顺序矩阵版本完成布局

`delay_20261014_171555` 原生布局完成，耗时1119.11秒，开始Routing；实际路由图90971 nets。布局估计WNS=-461ps/TNS=-13019ps，仅为此阶段估计，非routed min/max签核。没有新位流。长期路由观测脚本 `fpga/scripts/observe_video_routes.py` 只读取进程/日志并在本构建根目录保存观察序列，不修改原生源、约束或数据库。


### 18:31 复位 payload 后备审查结果（不推广）

只读层级审查找到 boot status_snapshot 与 snapshot retained_geometry 两处内部、有效性保护的数据寄存器；隔离的 PC 外部全接口差分332580周期/903位，以及 snapshot348次全29输出检查通过，覆盖冷启动X保护、中途复位、页/operation切换、快照失败/取消/旧几何和背压。正式源与D冻结源未变。

原生单位 compile/SYN 四项均exit0/E0，比较保留全部动态端口、8ns、相同设置并禁止诊断I/O插入，未执行MAP/PnR。PC原版3672LUT/3742FF→3694/3742，controlsets39→40；snapshot2272LUT/5830FF→2273/5830，controlsets29→30。单位计数与整板常量裁剪不同。内部异步C负载确实解除，但没有面积收益，控制集合增加，不能推断路由更容易。因此不推广、不发新整板构建；证据见 `resource_fallback_audit_20261014.md` 及 `reset_payload_20261014_180833_125001`。当前A/B/D实际路由继续。


### 19:18 早期hybrid对比host超时及同MAP种子比较

`hybr_b_20261014_143515/resume_20261014_151539_697611` 外层 subprocess 在14400秒抛TimeoutExpired，wrapper native_exit=null/native_runs=[]，输入完整。精确只读HANDLE观察捕获 child38740 在19:15:39.847243退出、原生子退出码0；该码不证明route完成：没有PNR数据库，日志仍只到detailed25=45223/111464，E=[]，前后290份实际源SHA全部匹配。因此归类host timeout/route incomplete，不是Route4022，也不是成功；日志、PLC和观察JSON全部保留。B原生任务和无限host的D继续。观察器session由创建代理持有，root不能直接poll该session，但可读取原始JSON；没有重新启动观察器或停止任务。

在确认A parent/child均不存在后，复制D已完成的MAP+PCF到`phys_20261014_191736_199955`并开始独立种子比较，session70888；只改变gplace seed11→官方默认7，其余decon1/normal/control500/congestion200/dump/native0/host0相同。全部290冻结源和两checkpoint SHA复制一致，同一D完整模型的70RTL实际SHA匹配。没有重新综合或改变任何时钟/协议，未生成新位流。


### 19:33 旧组合版本原生拥塞失败与最新扩展参数比较

delay_20261014_153410 原生自然退出1，W:Route4022拥塞/E:Route0008不可布通，并非host超时；detailed11=61744/110713，该轮CPU2254.28125s，detailed9821.42s/total routing10042.37s，完整动作3h20m32s。失败资源CLMA10380/11675（89%）、CLMS4421/4975（89%）、45838LUT/44046FF/2929RAM/125APM/58DRM/115IO；保留fail_pnr/PLC/prr/CNI/Plot及真实子退出码1/源哈希证据。未进入STA或bitgen，不能代表最新排序优化版的结果。

确认B父/子已结束后，由最新D同一MAP/PCF和290源复制phys_20261014_192840_623962，session38508/resume_20261014_192900_158156。只改变decongestion1→2，其余seed11/normal/control500/congestion200/dump/native0/host0相同，实际70共同RTL与已通过D完整模型同SHA。D原配置及同MAP seed7比较继续，不改RTL/约束、不重综合、无新位流。首次归档shell调用的自动批准审查超时，未执行；授权本地状态记录的重试已成功，没有批准阻塞。


### 20:45 独立物理试验优先级及官方复制开关

同MAP第三轮：D76703/109660、CPU43.8125s；seed7比较72887/108895、55s；decon2比较79185/111671、646.828125s。系统总物理内存32814300KiB、空闲1574048KiB。为保留三个独立试验而不增加内存负担，在精确PID59352/parent58512/工程路径guard及保存termination_note后有意停止decon2比较；Flow0189由该动作产生，不能称原生失败或证明永不可布通。PLC/CNI/Plot/全部源保留。

新的phys_20261014_204447_217557/resume_20261014_204520_067611、session95391复制同一D290源及MAP/PCF，实际70共同RTL与D已通过完整模型同SHA；只设置官方PDS指南112/118及安装版help支持的-dc_duplication FALSE，其余decon1/seed11/normal/500/200/native0/host0不变。关闭复制可能令时序变差，必须实际PnR+minmax通过，不保证改善。主配置和seed7继续，未新增第四个PnR、未改RTL或约束。


### 21:23 PC 配套源码冻结与离线重验

发布审查发现此前 host 验证 JSON 仅绑定输入向量，发布脚本取 live host 文件不能证明其与历史 PASS 相同。保留旧证据，新入口先冻结验证脚本及八个导入模块，再由 `-I -B` 独立 worker 从冻结目录实际解码，记录九项 SHA、实际脚本/模块路径及前后完整性。

`host/reports/fpga_rgb_vectors_20261014_212339_734188.json` 实际 PASS：8888 包、12441600 字节、两同源描述符；两份输入 SHA 与 D 原通过向量完全相同。正式配套快照位于该 JSON 的 `companion_snapshot_directory`。发布检查仅读取已验证快照，拒绝旧未绑定报告、错误源码 SHA 和 live 导入路径；目录解压使用命令也已离线验证。详见 `package_usage_host_binding_review_20261014.md` 与 `package_companion_source_gate_20261014.json`。没有连接硬件、改变 FPGA 模型或生成发布包。

21:27:41 实际日志：D iteration21 未布通50858/109660；seed7 iteration15 为49030/108895；关闭复制 iteration8 为63283/109815。三组原生进程仍运行、E=[]，尚无正常 routed DB、routed STA 或新位流。完整当前观察保存在 `route_observations.jsonl`，未将迭代计数视为完成比例或剩余时间。另有 token 代次冗余与缓存坐标宽度两个隔离后备仿真，尚未推广或获得整板原生资源/布线增益证明。


### 22:49 完整组合 H 进入以时序为优先的物理实现

用户最新要求是优先完成、时序优先、无需最优解；随后明确本轮只生成完整位流，不烧录。因此结束新增优化探索及烧录准备工作，交付门禁仍为完整功能回归、真实原生 PnR、同数据库直接 min/max 时序通过和位流生成。

`delay_20261014_220546_195131` 在 D 的290份冻结输入上只改三个RTL文件：bank去除经不变量证明冗余的内部token_gen存储/比较；cache按既有合法尺寸存储完整tile坐标；pipeline向cache传入已存在的4096尺寸上限。公开完整descriptor、generation/ticket饱和围栏、cache数据容量和队列、控制/吞吐合同保持。泛型未证实尺寸的新增拒绝范围在 `cache_tag_probe_20261014.md` 明示，不泛称所有旧参数等价。

隔离单位与差分结果见 `token_generation_probe_20261014.md`、`cache_tag_independent_review_20261014.md`、`cache_tag_probe_20261014.md`。H完整模型 `verilator_20261014_220624_520952` 实际PASS：3good/3processed、6220800检查字节、4014191geometry cycles；362ms合成时间、实际墙钟817.610秒/CPU796.219秒。控制、同源快照通过；冻结PC worker报告 `host/reports/fpga_rgb_vectors_20261014_222741_700621.json` PASS8888包/12441600字节，两输入bin SHA仍与D完全相同。恢复回归 `sim_20261014_221314_020623` 的fabric、64位ticket、geometry与NETWORK_TEST=1 core全部PASS，源前后完整；见 `combined_H_recovery_review_20261014.md`。

H原生 compile/SYN/MAP实际退出0、E=[]、全部290源和原D源完整，耗时1463.136秒。SYN44815LUT/42589FF/2705distributed RAM/125APM/58DRM/115IO/controlsets735；MAP44804LUT/42578FF/2705RAM/125APM/58DRM/115IO，相对D减少1121LUT、773FF、224RAM。实际模型71源、70共同RTL同SHA，验证后按live旧SHAguard将三文件同步到正式RTL；证据 `combined_board_evidence.json` 与 `promoted_source.json`。未改任何运行中的旧冻结源。

为集中资源给已验证的完整低资源候选，按实际子进程-action/MAP/project、父PID、创建时间及再次CommandLine guard主动结束D42556和G75720；所有290输入前后完整、日志/检查点保留。各 `termination_note.json` 记录原因，随后Flow0189由主动结束产生，不能列为原生拥塞失败。只保留已有E种子7作为后备。

H主流程 `resume_20261014_224919_013384`（session88445）从新MAP/PCF开始：Performance mode、decon1、seed7、control500、congestion200、默认复制、native0/host0。这是当前完成流程，不新增其他对照；全部原有时钟/引脚/CDC约束保持，直接routed min/max通过才生成位流。此时尚无新 `.sbit`、无硬件操作或发布包，实际1080p30及外部电气/来源仍需后续实板验证。

### 2026-10-15 04:40 H 原生拥塞失败与必要 Normal 模式修复

H 的 Performance 流程自然退出1，报告 W:Route-4022 与 E:Route-0008，并非超时或人为停止。详细布线第18轮为53894/107570，单轮CPU2016.390625秒，detailed18752.14秒/total routing18986.39秒。失败物理资源CLMA10007/11675（86%）、CLMS4352/4975（88%）、44094 LUT/42617 FF/2705 distributed RAM/125 APM/58 DRM/115 IO；日志、PLC、fail_pnr及拥塞诊断保留。全部290项输入SHA完整，未进入routed STA或bitgen。

本安装版官方指南印刷p109、p117–118支持Normal默认模式兼顾性能与速度，Performance用时最长。失败后为继续完成既定任务，隔离复制相同H网表及PCF到 `phys_20261015_044005_158952`，只把整个PnR的mode改为normal，保持decon1/seed7/control500/congest200/默认复制/native0/host0和全部原约束；从MAP重新布局，不复用失败PLC。该动作是必要布线修复，不降低最终时序门槛，也不保证布通。来源记录见 `mapped_copy.json` 与 `source_identity.json`：290 native源完整、70共同RTL与已通过H模型实际SHA一致；MAP SHA `dac93bf064ba699122b071f48dc74fe8400e07d0871e835fa0119810a534e131`，PCF SHA `f865a484fccfb5c509e40d53dadc2b427d7edd82ea618a3158145a2e3358b11a`。

新的 `resume_20261015_044030_445561`（session83860）已启动。使用原H模型 `verilator_20261014_220624_520952` 及冻结主机验证 `fpga_rgb_vectors_20261014_222741_700621.json`，不重新修改RTL或重复相同功能测试。E备用路线仍运行，最近第48轮37206/108895。当前无新位流、无发布包；本轮只生成位流，不操作烧录器。

### 2026-10-15 06:10 重复布局路线主动停止与种子11替代修复

I的实际执行命令确为Normal，项目无Performance覆盖。92条布局校验、wirelength、WNS/TNS和复制位置与已失败H相同，最终detailed checksum `2C997FC944D59862`，布局估计WNS/TNS为-333/-4002；详细布线0..8的未连接计数也逐轮相同。PLC容器SHA不同，不能认定整个数据库语义相同，官方资料也没有证明模式在何阶段必须分叉，因此I最终结果仍未知。

按完成优先的资源决策，保存两处 `termination_note.json` 后，逐项核验子进程42460/parent90464、实际exe、完整action/MAP/project命令及创建时间，再立即重复身份检查后主动停止。290项来源前后完整，PLC/拥塞/日志均保留；随后Flow0189由该停止产生，不能列为自然拥塞失败。首次计数保护使用PowerShell属性枚举Count产生拒绝，未记录终止或停止；核对实际290项无SHA差异后，改用显式数组计数保护并完成精确停止。

官方指南p115–116说明布局种子提供不同初始位置；同安装版已接受PG2L100H种子11。隔离复制相同H源/MAP/PCF到 `phys_20261015_060945_294286`，从MAP开始单一替代修复，只将I的seed7改为11，保持Normal/decon1/control500/congest200/默认复制/native0/host0与全部约束。`resume_20261015_061001_096453`（session26845）已启动，实际290项输入、70共同模型RTL及MAP/PCF SHA完整一致。使用同一H完整模型和冻结host报告，不改RTL或重复相同功能测试。E继续，最近第53轮36548/108895。新路线不保证布通，最终仍须PnR、同数据库routed min/max及原生位流生成通过；本轮无烧录、无新位流或发布包。

06:38实际观察：J原生命令采用seed11/normal，布局完成并开始路由。最终detailed placement wirelength1842000/checksum `E32D1E7DDA9DEB31`，与H/I的1971882/`2C997FC944D59862`不同，确认该替代修复产生不同布局；不能因此推断布通。布局估计WNS=-273ps/TNS=-8484ps，total placement1234.45秒，仅为布局估计，尚无routed STA或位流。E最近第55轮36248/108895，仍运行。


## 2026-10-15 DMA BRAM route repair / bitstream-only scope

Completed candidate `delay_20261015_111425_510321` compile/SYN/MAP with native exit 0, no E errors and all 290 source hashes intact (1330.769 seconds). MAP: 43,867 LUT / 42,536 FF / 1,809 distributed RAM / 125 APM / 86 DRM / 115 IO. Compared with H MAP: -937 LUT, -42 FF, -896 distributed RAM, +28 DRM. SYN: 43,874 LUT / 42,547 FF; controlsets remain 735.

The exact DMA source was promoted after checking the original live SHA and tested candidate SHA. Full 1080p/control/snapshot model `verilator_20261015_110249_115579`, six recovery regressions, 18 original/candidate burst regressions and frozen host decode `host/reports/fpga_rgb_vectors_20261015_111930_213424.json` passed. Last modeled geometry frame: 4,072,757 cycles at 125MHz = 32.582056ms; this is not measured hardware throughput.

Primary native PnR started at 11:36 in `resume_20261015_113643_076635`, Normal / seed11 / decon1 / control-chain500 / congest200, preserving every clock and I/O constraint. `complete_video_after_map.py` then requires actual routed min/max success before bitgen and strict source-bound packaging. J `phys_20261015_060945_294286` remains the sole backup. E was deliberately stopped at 11:30 with exact process-identity and before/after source guards; its Flow-0189 is a consequence of that stop, not a natural route failure.

No new routed timing pass or bitstream yet. No programming or programming preparation. Detailed evidence: `fpga/reports/route_efficiency_diagnosis_20261015.md`.


## 2026-10-15 12:17 route-only congestion-cost repair

K completed placement in 1160.92s; final detailed-placement wirelength 2,128,716, checksum 461BCEA49DA7CD60. Global routing took 100.52s; detailed routing contains 106,286 subnets. K0/1/2/3 left 81,540 / 78,172 / 74,883 / 72,185 subnets, with CPU 34.59375 / 39.125 / 66.5 / 356.03125s. J at the same first four rounds left 83,430 / 80,563 / 77,405 / 74,672, CPU 34.5625 / 35.171875 / 37.640625 / 42.984375s. Thus the BRAM change reduced resources but did not demonstrate early route acceleration. No eventual convergence or failure is inferred.

K was deliberately stopped at 12:15:54 after exact executable/parent/command/creation and all 290 before/after SHA guards. Its Flow-0189 and driver exit1 result from this stop. All evidence and the completed PLC remain preserved.

L `phys_20261015_121417_911429` copies the exact K290/MAP/PCF and completed PLC, SHA `ceeac3f728848fb736296eb221d848236792a7e22d6afce4232e2674179cc5d8`. Resume `resume_20261015_121627_645743` explicitly passes `-input_place_db_file` and `-pin_cost_increasing_speed 600`. The official installed guide p113/p252 and native help document this integer congestion-pin cost (default300); 600 is a task-selected repair value, not a vendor-recommended optimum. PDS accepted the native command and directly started routing, with exactly K's 89,621 nets, initial slack -2581 and TNS -50574. No new global placement occurred. The command's default seed7 does not describe the reused seed11 placement; source placement provenance is recorded separately.

Timing weight, clocks, constraints, functional RTL, model and host evidence are unchanged. `resume_video_system.py` now accepts an optional explicit pin cost; omission preserves existing behavior. `route_and_package.py` in L continues through strict routed min/max, bitgen and packaging only after success. J remains the only backup. This is not a new RTL optimization sweep. No new bitstream or hardware action.
