# 2026-09-24 OV5640 RAW8 高两位噪声定位与 FPGA 显示修正

## 实测定位

- 当前已冷启动镜像 `9b6f725b154a` 的网口原始帧 f7407 保存于 `host/data/web-hardware_unverified-20260924T112514Z-a0760e0a/e7523612131053524654_f7407_t1_d945242450/image.raw`；原始 1920×1080 RAW8 不覆盖。
- bit6、bit7 的相邻像素相关性均约 0，跨相邻帧相关性也约 0；bit2～bit5 的跨帧相关性分别约 0.76、0.88、0.91、0.94。隔离最高两位后，字节横向相邻相关性约 0.832，实物轮廓清楚。派生审校图 `low6_diagnostic_derived.png` 保存在同目录；它不是原始证据。
- 本地只读资料 `reference/盘古100K200K MINI开发板/4_IC_datasheet/OV5640/OV5640_DataSheet.pdf` 第 134 页定义 `0x4745=02` 为调试用 `{D[1:0],D[9:2]}` 数据重排；同目录 `DOUBLE-DVP-OV5640-1113.pdf` 将 CAM1_D7…D0 对应到传感器的高八位 D9…D2。模块应用指南第 5 页也说明 8-bit 输出用 D[9:2]。因此重排使传感器低两位进入板端最高两位，与噪声实测吻合。此为故障定位，不排除剩余的 PCLK 采样/曝光问题。
- 更早 `0x4745=00` 实测 RAW 帧 f44832 的整体横向相邻相关性约 0.729，虽偏暗且有独立行问题，但明显不是当前高两位随机覆盖。当前修正恢复 `0x4745=00`，保留 `0x501F=03` ISP RAW 裁切候选。

## 实现边界

- 网口 S0 仍是未经 FPGA 增强的原始 RAW8，维持原始证据与跨端协议。HDMI 读取同一帧池的独立支路，在 FPGA 像素时钟域做同 Bayer 相位 `x,x-2,x-4` 三点中值去孤点，以及固定单调暗部对比度映射；无帧缓冲或额外帧时延。
- 固定映射的黑点为 2，16 处提升到 140，74 处达到 255；此前更窄的肩部会使旧镜像实测亮场约四分之一像素饱和，因此本候选扩大亮部余量。这只是调试显示曲线，不代表自动曝光、颜色 ISP 或几何校正验收；不能由离线增强图宣称新镜像实拍通过。
- 单模块 `raw8_display_enhance` 仿真见 `fpga/build/raw8_display_enhance_20260924/simulation-v2.log`；RAW8 全量回归见 `fpga/build/raw8_dual_sim_20260924_202059_614/`；板级六帧及晚期帧回归见 `fpga/build/raw8_board_sim_20260924_202059_913/`，均已通过。板级仿真严格比对 HDMI 增强样本与网口原样本，但不代替真实 PHY/摄像头/HDMI 验证。PDS 时序、固化和实拍状态以各自完成记录为准。

## 2026-09-25 原生实现与上板状态

- PDS 2022.2-SP6.4 原生 seed=1 布线及位流见 `fpga/build/mini_raw8_dual/native_20260925_131713_449/`，全部约束通过；ETH125→PHY_SAMPLE 慢/快角 setup 最小余量为 0.137/0.052 ns，hold 为 0.103/0.106 ns，四组各覆盖五个端点。源文件与位流审计通过，发布目录 `fpga/release/raw8_dual_20260925_1faa0de4549e/` 含 SBIT/SFC；此前镜像未删除。
- 早期 JTAG 探测曾返回空 `CableList`，Windows 同时短暂出现 USB 端口重置错误 43；随后同一拓展坞端口重新枚举为 FTDI 双通道设备，PDS 识别 `USB Cable II`、PG2L100H ID `0x00602899` 以及 XT25F128 JEDEC `0x0B4018`。这说明此前不能归咎于拓展坞本身。
- 已按本轮授权整片擦除 XT25F128、写入 `raw8_dual_20260925_1faa0de4549e` 并完成原生 Flash 回读校验；`flash-program.log` 含 erase/program/verify 成功和 `CAMERA_FLASH_ERASE_PROGRAM_VERIFY_COMPLETED`，无 `E:`。外围日志检查脚本一度因期望错误的文字格式返回失败，但不影响上述 PDS 原生命令的成功，不应因此重复擦写。
- 用户已彻底断电冷启动。串口 RAW8 配置 ACK 和诊断见 `host/reports/raw8-enhance-cold-20260925/`：摄像头 ready、1920×1080、帧已发布，无 HDMI 下溢或聚合故障。网口完整帧 1649/55 秒，接收期约 29.98 fps；原始证据见 `host/data/hardware_unverified-20260925T060254Z-b4e4db7a/`。旧镜像 RAW bit6/7 同色相位相邻相关性约 0，新镜像约 0.886/0.98，整字节相关性升到 0.998，证实调试位序造成的高位随机噪声消失。
- Hagibis 1920×1080p30 采集见 `host/data/hdmi_diag_20260925_140627_888639/`：初帧是采集卡锁定过程的 No Signal，2.5 秒抽帧已有同场景的灰度图。仍无 FPGA HDMI 帧源身份回传，不能宣称逐帧配对。亮场原始 S0 有 20.33% 像素值 255，已烧录的增强曲线把 74 以上全部截白，使 HDMI 抽帧约 55.27% 像素接近白色；所以双路跑通不等于显示质量合格。
- 后续保留高光曲线候选将黑点设为 16、80 处提升至 96、208 处回到原值，208 以上保持原值。用上述原始帧离线预测，白色像素比例约 20.33%，不再人为扩大到 53%。该预测不是新镜像实拍；需重新仿真、PDS 实现、另一次获准烧录和冷启动验证。
- 保高光候选已完成 `fpga/build/raw8_dual_sim_20260925_141350_861/` 与 `fpga/build/raw8_board_sim_20260925_141604_901/` 回归，PDS 原生 seed=1 报告 `fpga/build/mini_raw8_dual/native_20260925_141630_147/` 全部约束满足。272 项源哈希审计通过；发布目录 `fpga/release/raw8_dual_20260925_7219d93c2e79/` 的 SFC 已在用户本次单独授权后整片擦写并由 PDS 原生回读校验成功，旧镜像保留。仍需用户彻底断电冷启动；冷启动确认前不得进行新镜像板测。
- 用户已对 `7219d93c2e79` 新镜像彻底断电冷启动。串口证据 `host/reports/raw8-highlight-cold-20260925/`：RAW8 boot ACK、sensor ready、frame published、1080 行/1920 像素每行、HDMI 无下溢、无聚合管线故障。网口证据 `host/reports/hardware_unverified-20260925T070922Z-35715285/receiver.json`：12 秒内 359 个完整帧，接收窗口约 29.92 fps，四帧原始 RAW8 已归档。抽样原始帧 f4521 灰度派生图在对应 `host/data/` 目录，原始帧饱和比例 20.02%、同相位相邻相关性 0.9979。
- Hagibis HDMI 3 秒采集与 2.5 秒抽帧见 `host/data/hdmi_diag_20260925_151003_448280/`。新 HDMI 近白像素比例 20.30%、均值 129.38，对比旧镜像相近场景的 55.27%、均值 234.47；这是实拍画面统计，表明人工高光截断大幅减少。镜头场景含强亮光，原始 RAW8 自身约 20% 已饱和，FPGA 显示映射无法恢复被传感器截断的细节。网口与 HDMI 并非硬件标记的同帧，HDMI 帧源身份仍为 null/unverified；用户审校和遮挡来源确认尚未完成。

## 2026-09-25 增亮与对比度候选

- 用户要求继续提高亮度、增强对比度。固定 FPGA HDMI 曲线采用输入码 24/80/144 → 输出码 0/112/192，144 以上逐渐压缩但 254→254、255→255；同 Bayer 相位三点中值仍保留，网口 S0 不改。每个改动代码块的用途和设计意图已同步注释。
- 对已归档的实拍 RAW8 f4521 做离线同算法预测：当前镜像 HDMI 映射均值约 129.36、标准差约 78.08、中位数 105、近白约 20.32%；候选预计均值约 140.20、标准差约 79.54、中位数 124、近白约 20.57%。这是拟烧录候选的预测，不是新位流实拍。
- 256 输入码值单模块测试和 RAW8 双路回归见 `fpga/build/raw8_dual_sim_20260925_153310_472/`，板级六帧及晚期会话回归见 `fpga/build/raw8_board_sim_20260925_153309_850/`，均通过。PDS 全约束时序及后续固化仍待完成；未获本轮明确授权前，不整片擦写 Flash。
- PDS 2022.2-SP6.4 原生实现 `fpga/build/mini_raw8_dual/native_20260925_153401_689/` 已全约束通过，272 项源输入及已测仿真审计通过。位流 SHA-256 为 `6a28c5c343459cd9901a9152c8330b6a0c468d8b113a4d3299c5cf492cd54034`；离线 SFC 发布备份在 `fpga/release/raw8_dual_20260925_6a28c5c34345/`。新候选尚未烧录、冷启动或实拍，板上仍运行上一版 `7219d93c2e79`；等待本轮单独擦写授权。
- 用户随后明确授权本候选再次整片擦写。只读 JTAG 复核 PG2L100H ID `0x00602899`、XT25F128 ID `0x0B4018`，然后整片擦除、编程并通过 PDS 原生 Flash 回读校验，`fpga/release/raw8_dual_20260925_6a28c5c34345/flash-program.log` 含完整成功标记且无 `E:`。上句的“尚未烧录”是当时状态；现已烧录，但仍需用户彻底断电冷启动，确认之前不得进行新镜像板测。

## 2026-09-25 增亮候选冷启动后实测

- 用户已确认整机彻底断电并重新上电，本节测试均在确认之后进行。LED0 闪烁、LED4 熄灭；串口 RAW8 Boot ACK 与 `host/reports/raw8-contrast-cold-20260925/inspect.json` 显示 sensor ready、已发布帧、1080 行/每行 1920 像素，未见 HDMI 下溢或帧池、写入、网口聚合故障。LED4 熄灭不能单独判为链路故障。
- 网口接收仍约 30 个完整帧每秒，原始证据保存在 `host/data/web-hardware_unverified-20260925T120412Z-b3816ac2/`；接收网页 `http://127.0.0.1:8766/` 处于 live。首尾抽查六帧 RAW8 的均值稳定在 18.95～18.99、中位数 14、95 分位数 46，约 77.5% 像素码值不高于 24，并非启动瞬态。当前拍摄场景与此前亮场是否相同尚待用户确认，不能直接将两次亮度差归因于固件。
- HDMI 采集文件及 2.5 秒派生审校帧保存在 `host/data/hdmi_diag_20260925_200448_161489/`。本次 HDMI 帧亮度均值约 6.42、中位数 0、纯黑像素约 75.38%；该结果与增强曲线将输入码 24 以下映射为 0 的设计一致，说明此曲线在当前低亮度场景下明显丢失暗部。不能以旧版亮场 HDMI 均值 129.38 和本次不同场景均值 6.42 宣称增亮效果已通过或失败；仍需同场景复测。
- 摄像头启动表 `fpga/rtl/raw8_dual/ov5640_raw8_profile.v` 当前明确使用固定 768 行曝光和 2 倍增益，关闭自动曝光/增益；因此低照度环境不会由传感器自动提亮。此配置与 HDMI 黑点 24 共同构成本次暗画面的合理解释，但在确认镜头所对场景及照明前，不能排除实际曝光/增益读回异常。
- 网口数据仍是 S0 原始 RAW8；HDMI 帧源身份没有硬件标记，保持 `null/unverified`，不能宣称逐帧配对。现有证据只确认两路有活动视频及本次暗部压黑，未确认图像质量达到验收要求。

## 2026-09-25 自适应暗场增强候选（离线）

- 针对用户反馈的画面过暗，HDMI 支路保留三点同 Bayer 相位中值和既有亮场保高光曲线；新增暗场单调映射：输入码 8/16/32/64/128 分别对应输出码 0/32/144/208/240，255 保持 255。每 64 个已接受像素采样一次，仅在收齐接近完整帧（至少 30000 个样本）后于下一帧边界按均值低于 64 切换曲线；短帧维持上次模式。该处理不修改网口 S0，也不宣称完整 ISP 或 HDMI/S0 逐帧配对。
- 已存暗场原始帧 `host/data/web-hardware_unverified-20260925T120412Z-b3816ac2/e14743987320236454502_f6361_t1_d945242450/image.raw` 的同算法离线预测见同目录 `adaptive_lowlight_predicted_derived.png`：原始均值约 19.02，经中值及暗场映射后预测均值约 52.47、95 分位 172、零值约 6%。这只是用旧位流原始证据得到的预测图，不能标为新固件实拍。
- 单模块明暗两曲线全部 256 码值、单调性、帧边界切换和短帧保持，以及单帧双路逐字节回归见 `fpga/build/raw8_dual_sim_20260925_202248_860/`，均通过；六帧原生 FIFO/三时钟板级回归及晚期 epoch 见 `fpga/build/raw8_board_sim_20260925_202515_113/`，均通过。上述仿真不代替真实传感器/HDMI/DDR PHY 板测。
- 本机 PDS 2022.2-SP6.4 曾因构建脚本以 UTF-8 BOM 写回原生 `.pds` 而报首行 `Flow-0130`；已确认首字节 `EF BB BF` 并修复脚本为无 BOM 写回，仅规范化实现目录字段。重跑后的原生项目已正常解析及综合；最终时序、位流和固化状态以完成的构建记录为准，当前板卡仍是 `6a28c5c34345` 旧镜像。
- PDS 原生 seed=1 构建 `fpga/build/mini_raw8_dual/native_20260925_202959_483/` 已完成布局布线和位流；时序报告 `Design Summary: All Constraints Met`，ETH125→PHY_SAMPLE 慢/快角 setup/hold 四组余量为 0.137/0.103/0.052/0.106 ns，四组各覆盖五个端点。发布审计检查 272 项构建输入哈希、六帧/晚期 epoch、原生 RGMII 时钟及 GMII CDC 证据，均通过。审计器已严格兼容 Windows PowerShell 5.1 的 UTF-16 日志和 JSON 编码，不放宽错误或时序门槛。
- 离线发布 `fpga/release/raw8_dual_20260925_9cc979fe6822/` 包含 PDS 原生 SBIT 及 XT25F128 SFC，两者 SHA-256 均为 `9cc979fe6822258bd31eca208ce1e0b012db31b9342622c121737d31603d6af5`；`manifest.json` 的 `programmed/flash_verified/cold_boot_verified` 均为 false。此候选尚未烧录、冷启动或实拍，板上仍运行旧镜像；上板需新一次明确授权整片擦写、回读，并按用户约定先彻底断电冷启动再测试。
- 用户随后单独授权本候选整片擦除 XT25F128。首次只读 JTAG 扫描时烧录器 USB 端口重置失败，`CableList` 为空，未执行擦除；用户拔插烧录器后，Windows 将 FTDI 双通道枚举为 OK。复测 `fpga/build/raw8_flash_probe_20260925_205409/` 确认 PG2L100H ID `0x00602899`、外部 Flash 扫描成功；PDS 状态位 `over_temp=1` 仍原样存在，未屏蔽，也不将其当作真实温度测量。
- 已按该次授权整片擦除、写入 `9cc979fe6822` SFC，并经 PDS 原生 `cfg_jtag_flash_verify` 回读校验成功。完整日志为 `fpga/build/raw8_flash_program_20260925_205526/program.log`，副本为本发布目录 `flash-program.log`；erase/program/verify 成功标记齐全，无 `E:`，JTAG 会话正常断开。上句“尚未烧录”是发布时状态；现 `programmed/flash_verified=true`、`cold_boot_verified=false`。**收到用户彻底断电冷启动确认前，不执行新镜像板上测试。**

## 2026-09-25 自适应候选冷启动后板测与修正方向

- 用户已确认彻底断电冷启动，因此 `9cc979fe6822` 发布清单的 `cold_boot_verified=true`。本次新 epoch `10812969957108644638` 的配置位于 `host/config/raw8-adaptive-cold-20260925/`，串口 Boot ACK/Inspect 证据位于 `host/reports/raw8-adaptive-cold-20260925/`：sensor ready、frame published、每行 1920 像素/1080 行，HDMI 无下溢，帧池/DDR 写入/网口无故障。
- 网口完整帧约 29.6 fps；原始帧保存于 `host/data/web-hardware_unverified-20260925T130843Z-00b0ac5d/`。样本 RAW8 均值约 66.2、中位数 37、约 75% 像素不高于 64，但顶部直射灯条已使约 13% 像素在传感器处饱和为 255。归档结束后连续网页预览转为同 epoch、不继续周期存盘的接收会话；S0 原始数据仍不经过 FPGA HDMI 曲线。
- Hagibis 原始 MJPEG 采集保存在 `host/data/hdmi_diag_20260925_211025_859061/capture.mkv`，2.5 秒派生帧 `frame_2p5s_derived.png` 的均值约 62.21、中位数 26、近白约 12.98%，且下方网格仍偏黑。此分布与亮场曲线一致；上一帧均值阈值 64 被局部灯条拉过门槛，使多数暗像素失去预期提亮。HDMI 采集有损、两路无硬件帧 ID，不能宣称逐帧配对。
- 用户暂时无法移动镜头。对本次旧固件 RAW8 样本离线应用相同暗场曲线的派生预测图保存在原帧目录 `dark_fraction_predicted_derived.png`，均值约 133.68、中位数 154、近白约 12.98%，网格较清楚；该图**不是**新位流上板实拍。旧亮场原始帧不高于 64 的像素约 29.7%，本次混合强光暗场约 75%，因此下一候选改为每帧抽样后以“过半像素码值不高于 64”判暗；仍要求近完整帧且只在帧边界切换。新的代码尚未烧录，不得沿用已使用的整片擦写授权。
- 新判据的 1/64 抽样在旧亮场原始帧约 28.44% 为暗像素，在本次灯条暗场约 74.53%；分别应选择亮场/暗场曲线。仿真 `fpga/build/raw8_dual_sim_20260925_211601_544/` 覆盖连续高亮灯条、全部 256 输入码值、短帧保持和双路原始数据保持；`fpga/build/raw8_board_sim_20260925_211744_952/` 的六帧及晚启动 epoch 均通过。
- PDS 原生构建 `fpga/build/mini_raw8_dual/native_20260925_211833_369/` 已完成同一布线数据库的 min/max 时序和位流导出，`Design Summary: All Constraints Met`；ETH125→PHY_SAMPLE 四组 setup/hold 余量为 0.137/0.103/0.052/0.106 ns，各覆盖五端点。272 项源文件和独立网口时钟/CDC 回归审计通过。新候选离线备份 `fpga/release/raw8_dual_20260925_18a5a3adee5e/` 含 SBIT/SFC，SHA-256 均为 `18a5a3adee5e2771a2ec9206db3d4e604495c02104b334c656d779bc7e642c92`；manifest 标为 `programmed=false`、`flash_verified=false`、`cold_boot_verified=false`。板上仍是已实测但在灯条场景误选曲线的 `9cc979fe6822`，下一候选尚无上板效果证据。

## 2026-09-26 多数暗像素判据候选固化状态

- 用户单独授权本次整片擦除 XT25F128。烧录前核对新候选 SFC SHA-256 为 `18a5a3adee5e2771a2ec9206db3d4e604495c02104b334c656d779bc7e642c92`，旧镜像备份 `fpga/release/raw8_dual_20260925_9cc979fe6822/mini_raw8_dual.sfc` 的哈希为 `9cc979fe6822258bd31eca208ce1e0b012db31b9342622c121737d31603d6af5`。只读探测 `fpga/build/raw8_flash_probe_20260926_134725/probe.log` 确认 PG2L100H ID `0x00602899` 且外部 Flash 扫描成功；PDS 状态位仍报 `over_temp=1`，未屏蔽，也不视为温度实测。
- 使用 PDS 2022.2-SP6.4 原生 JTAG 配置命令整片擦除、写入 `18a5a3adee5e` SFC 并完成 Flash 校验。完整日志为 `fpga/build/raw8_flash_program_20260926_134830/program.log`，发布目录副本为 `flash-program.log`；erase/program/verify 均成功、无 `E:`，JTAG 已断开。manifest 更新为 `programmed/flash_verified=true`，但 `cold_boot_verified=false`。此前候选构建、仿真和时序结果不能代替本候选冷启动后的实拍。须先由用户彻底断电再上电并确认，方可进行新固件板上视频验证。

## 2026-09-26 冷启动双路实测

- 用户确认彻底断电冷启动；LED0 闪烁、LED4 熄灭。发布清单仅据此及本轮启动诊断将 `cold_boot_verified` 更新为 true，不等于图像质量验收。新 RAW8 epoch `9442258690559999880` 的配置位于 `host/config/raw8-majority-cold-20260926/`；串口 Boot CRC/ACK 为成功，Inspect 证据位于 `host/reports/raw8-majority-cold-20260926/`。sensor ready、frame published、每行 1920 像素/1080 行、HDMI 无下溢；聚合、DDR、网口故障位均为 false。旧网页接收器原占用 UDP 50000，已核实为本工作树进程并通过 Web API 优雅停止，未杀服务或其他进程。
- 网口证据为 `host/reports/hardware_unverified-20260926T060554Z-d58edb9d/receiver.json` 和配套 `host/data/`：15 秒接收 450 个完整帧，约 30 fps，归档 3 个 1920×1080 原始 RAW8 帧，无接收错误。结束窗口时仅中止正在到达的 1 帧（`frames_failed_stopped=1`）；首次在串口 Boot 前结束的 0 帧接收窗口不是链路故障。新 RAW 样本中位数 32～33、均值 64.4～64.7，旧同场景 RAW 中位数 37、均值约 66.2；不同时间样本不能逐帧配对。
- Hagibis 1080p30 三秒 MJPEG 原采集、RGB 和派生审校图位于 `host/data/hdmi_diag_20260926_140918_369613/`。取 2.5 秒派生帧，新 HDMI 灰度均值 127.63、中位数 147、下半部均值 49.29；旧 `host/data/hdmi_diag_20260925_211025_859061/frame_2p5s_derived.png` 相应数值为 62.21、26、4.88。近白像素占比新旧约 12.81%/12.98%，说明暗场可见度改善且未额外扩大顶部灯条截白。采集为有损 MJPEG，不能作为精度或 HDMI/网口同帧证明；灯条仍过曝，下半部仍偏暗。
- 已用 `host/scripts/release_raw8_receiver.ps1` 实测优雅释放本工作树旧网页会话并确认端口释放，然后恢复新 epoch 的 `http://127.0.0.1:8766/` 连续预览；恢复后的运行 ID 为 `web-hardware_unverified-20260926T061927Z-4a142310`，约 3 秒内 89 个完整帧、无会话错误。该预览仍标记 hardware_unverified，不把 S0 原始灰阶冒充 FPGA S1，不声称已验证 HDMI 帧源身份。
