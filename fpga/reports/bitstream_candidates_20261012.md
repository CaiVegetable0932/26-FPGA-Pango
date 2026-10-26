# 总体布局布线与候选位流生成记录

日期：2026-10-12（Asia/Shanghai）。用户要求：继续总体布线并形成位流文件。
目标：Logos2 / PG2L100H / FBG676 / -6；PDS 2022.2-SP6.4 build146967。

两套现有工程分别完成完整 Compile → Synthesize → Device Map → Place & Route → Report Timing → Generate Bitstream，原生退出码均为 0、错误数均为 0。已产生可以由 PDS 使用的原生 `.sbit` 和配套 `.smsk`，并完成内部时序、CDC、目标器件、源快照及复制校验。**文件状态为离线候选，未执行下载，也未解除既有硬件放行限制。**

## 1. 文件与用途

交付目录：[candidates/20261012_220946](../release/candidates/20261012_220946/README.md)。

| 文件 | 大小 | 对应功能 |
| --- | --- | --- |
| [pango_video_top.sbit](../release/candidates/20261012_220946/pango_video_top/pango_video_top.sbit) | 3,791,112 B | 现有主工程/IP 集成骨架；DDR 地址请求空闲、PHY 保持复位、HDMI 固定符号 |
| [Top.sbit](../release/candidates/20261012_220946/mini_camera_diag/Top.sbit) | 3,791,112 B | CAM1 单路 1280×720 RGB565 → DDR 帧缓冲 → HDMI 诊断工程 |

两者不可按用途互换；主工程没有摄像头画面业务，诊断工程没有 RAW8/PRAW 千兆网或完整1080p畸变矫正。此次总体布线范围是各自工程现有顶层及其实际依赖，没有把其他分区的独立模块或时序探针自动当作已集成系统。

位流 SHA-256：

```text
pango_video_top.sbit
d0cc119a73e7b519dbe5981aa41a1a2df374971e00a1afd52d4eb139b54c56ba

mini_camera_diag/Top.sbit
c22f697aa5be8192165f98773375920cb14f01611904443fdcb9035002133a46
```

[manifest.json](../release/candidates/20261012_220946/manifest.json) 记录用途、目标、证据目录、资源、时序及硬件状态；[SHA256SUMS.txt](../release/candidates/20261012_220946/SHA256SUMS.txt) 包含全部复制文件的校验值。每个工程子目录另有 `.smsk`、原生 `.bgr`、结果/审计 JSON、源文件哈希和 Tcl 入口。位流及掩码直接复制原生字节，没有改名、修改、压缩转换或生成 Flash/eFuse 镜像。

## 2. 本轮总体布线与时序

PnR 配置保持 `-congest_overlap_limit 20 -action_timeout 15`；时序包含 Slow/Fast corner 的 setup、hold、recovery、removal，保持 min/max，不使用逻辑层数过滤或新扩大时序例外。两报告均为 **All Constraints Met**。下表为对应类型全部时钟对的最小 WNS；所有 TNS 和失败端点数均为 0。

| 类型 | 主工程 Slow / Fast WNS ns | 诊断工程 Slow / Fast WNS ns |
| --- | --- | --- |
| Setup | 1.463 / 2.085 | 1.155 / 2.085 |
| Hold | 0.138 / 0.102 | 0.137 / 0.101 |
| Recovery | 1.527 / 2.398 | 3.307 / 4.572 |
| Removal | 0.324 / 0.219 | 0.336 / 0.231 |

综合资源：主工程 LUT 3,666、FF 3,561；诊断工程 LUT 6,196、FF 6,119。两套 HDMI 均使用 1 个原生 IOCLKBUF、1 个 IOCLKDIV_E2 和 8 个 HDMI OSERDES；包括 DDR 的全工程 OSERDES_E2 数量均为 87。原生 `/5` 像素时钟周期为 13.468 ns、40% 占空比。未将目标频率、Fmax 或工具模型当作真实帧率、功耗或接口测量。

`audit_clock_reset.py` 对此次生成位流的实际构建重新核验：Gray 源 Q→首级 D、同接收域首级 Q→次级 D、布线端点数量及明确剪枝证据；启动脉冲只落到一个分频器和八个 OSERDES 的复位端；新增像素复位链真实连接且后续级正常计时。核验了完整 8 类 corner 汇总和源码快照。没有借用此前同名工程的报告。

## 3. 来源与原始证据

主工程：[本轮 result.json](../build/bitstream_20261012/pango_video_top_20261012_220353_214298/result.json)。
诊断工程：[本轮 result.json](../build/bitstream_20261012/mini_camera_diag_20261012_220409_168975/result.json)。

上述目录均保留：

- `source/`、`source_hashes.json`、原始工程 Tcl 和构建脚本副本。
- `flow.tcl/.pds`、原生 compile/synthesize/device_map/place_route/report_timing 输出及全过程日志。
- `generate_bitstream/*.sbit/*.smsk/*.bgr`、原生 `bgr.db`。
- `clock_reset_audit.json` 和打包前再次执行的 `candidate_audit.log`。

构建源与工具输出均位于新 FPGA 子目录，保留共享工程和之前的验证结果。打包前复查所有快照文件 SHA-256 及当前工作输入一致性，逐个核验 IP 的 Logos2/PG2L100H/FBG676/-6 目标；位流哈希必须与本轮结果相同，原生位流报告必须指向本轮目录，镜像时间不得早于它的路由数据库。交付复制后的每个文件再次检查 SHA-256。

首轮尝试在工程 Tcl 中读取尚未生成的报告作门控，但 PDS 会先预解析 Tcl，出现 `timing_file/timing_text` 未定义错误。已中止并保留在 `bitstream_20261012/pango_video_top_20261012_220029_015246` 与 `mini_camera_diag_20261012_220106_925314`；明确标为失败、未交付。最终流程仅包含安装版支持的原生任务序列，由宿主在完整构建后核验并阻止失败产物进入候选交付目录。

## 4. 可重复构建

```powershell
python fpga/scripts/build_clock_reset.py --project pango_video_top --stage gen_bit_stream
python fpga/scripts/build_clock_reset.py --project mini_camera_diag --stage gen_bit_stream
python fpga/scripts/package_fpga_candidates.py fpga/build/bitstream_20261012/主工程实际目录 fpga/build/bitstream_20261012/诊断工程实际目录
```

`--stage gen_bit_stream` 是明确启用本地位流文件生成的选项；默认仍只到时序报告。没有调用配置器、JTAG、Flash、eFuse 或硬件电源/温度接口。使用已生成 IP，没有重新生成或手工改写 IP HDL；保留 `gen_bit_stream -scbv {High Voltage}` 的既有配置 Bank 选项。

只读查阅安装目录 `doc/Pango_Design_Suite_User_Guide.pdf` §3.9/§5.2–5.4 的 `.sbit`、SCBV 和命令行流程，以及 `Fabric_Configuration_User_Guide.pdf`；文本摘取留在 `build/bitstream_20261012/reference/`。器件/板卡/时钟核对继续采用本轮 [01 分区报告](clock_reset_io_20261012.md) 记录的 MINI V1.3、Logos2、安装版约束和原生拓扑依据。没有向官方参考原件写入内容。

## 5. 实际下载状态

原生文件生成与硬件放行分别记录：`candidate_checks_passed=true`，但 `download_approved=false`、`hardware_tested=false`、`programmed=false`、`external_timing_verified=false`。

未关闭的已有项目包括：over_temp=1 无解除证据；板卡版本、DDR/电气和外部 DVP/RGMII/TMDS 时序未完整签核；加密 OSERDES 行为仿真受许可证阻塞；完整帧/DMA 异常恢复及完整 RAW8/1080p/网络系统验收尚未完成。上述缺口没有通过本次总体布线解除。因此这些文件可供后续 PDS 配置加载使用，但不能称为已通过实板验收或已安全放行的最终整机位流。
