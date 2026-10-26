# FPGA P12 换机布线交接文档

交付日期：2026-10-18（北京时间）。目标：在另一台 Windows 计算机上接续当前完整视频设计的物理实现，完成布局布线、min/max 时序检查和原生 `.sbit` 位流生成。

**本包交付当前 P12 的完整工程输入及检查点，不包含已通过签核的完整视频位流。** P12 的 Compile/SYN/MAP 已完成，打包时详细布线仍未完成；换机后仍需解决拥塞并通过时序。不能保证仅换一台计算机即可收敛，也不能用历史诊断位流替代本工程的结果。

## 1. 唯一设计基线

| 项目 | 本次交接值 |
| --- | --- |
| 包名 | `pango_video_system_P12_20261018.zip` |
| 顶层 | `pango_video_system` |
| 器件 | Logos2 / PG2L100H / FBG676 / -6；板卡标称 PG2L100H-6IFBG676 |
| 板卡资料 | MINI-100HP，项目配置 MES2L676-100HP-MINI；实物版本仍需核对 |
| 工具 | PDS 2022.2-SP6.4 build 146967，Windows 64 位 |
| MAP 来源 | `delay_20261016_013746_534606` |
| P12 冻结工程 | `phys_20261017_135035_561224` |
| 冻结文件 | 290 个，清单为 `fpga/project/sources.json` |
| 版本识别 | 冻结文件 SHA-256 + 包内 `manifest.json`；Git HEAD 仅为背景记录 |
| 原生 IP | video_pll：PLL 1.5；ddr3_controller：Logos2 HMIC_S 1.10，生成器 build 146967 |

包根目录中的 `fpga/source/` 是本次综合和布线的唯一源码入口。P12 尚未推广至仓库共享 RTL；共有 11 个文件与共享目录不同，完整差异名单见 `fpga/docs/provenance.json`。不得用共享目录的 RTL 覆盖本包源码后继续使用旧 MAP/PLC。

本次没有改动 RTL、IP、约束或时钟，仅新增迁移构建脚本、路径重建模板及交接材料。冻结源码、MAP 和 PLC 均逐文件校验；MAP 与其来源工程一致。

## 2. 功能与约束范围

数据通路为 OV5640 RAW8 DVP → FPGA：S0 原始数据经 DDR 和板载千兆网回传 PC；另一支经过基础 ISP 得到 S1，经透视和镜头畸变逆采样得到结果，再通过唯一 HDMI 输出。设计包含 RAW/RGB 帧池、DDR DMA、HDMI 扫描输出、PC 参数控制及同源 S1/结果快照。PC 不转发主视频，也不执行实时几何矫正。

保持 1920×1080、矫正至少 30fps 的目标。业务/DDR 用户时钟为 125MHz，HDMI 像素时钟为 74.25MHz、串行时钟为 371.25MHz，板上另有 27MHz 参考时钟。不得以降频或放宽时序约束把当前候选标为通过。DDR 引脚、原生 PHY 固定位置、DDR 时序约束及 IP 注册上下文必须一并保留。

本版本 MCU 外部连接尚未接入板级顶层，自动 Gamma 和动态 LUT 上传尚未集成；PC 控制接口使用 V1，不能与独立 MCU_POSE_V2 混用。初始化需要 PC 通过 115200 8N1 UART 下发启动实体，指定本机目的 MAC/IP 等参数，ACK 发送完后才允许采集。具体字节格式见 `fpga/source/config/integration/PC_RGB_CONTROL.md`。

接口与设计资料在 `fpga/docs/design/`。原文中的仓库相对链接作为背景保留，原路径在迁移机上可能不存在；本包构建入口不依赖这些链接。

## 3. 包内目录

| 路径（相对解压后的包根目录） | 用途 |
| --- | --- |
| `HANDOFF.md` | 本交接文档 |
| `README.txt` | 最短启动说明 |
| `manifest.json` | 包内文件大小和 SHA-256 清单 |
| `fpga/source/rtl/` | P12 冻结 RTL，包括必要厂商示例副本 |
| `fpga/source/ip/` | 已生成的 DDR/PLL、IDF、加密源码和依赖 |
| `fpga/source/constraints/` | 板级管脚、DDR、时钟/CDC、布局和路由约束 |
| `fpga/source/config/` | 板卡、IP、协议及相关配置快照 |
| `fpga/project/flow.template.tcl` | 从原生冻结工程导出的有序源文件/约束/综合流程，`@RUN@` 由脚本替换 |
| `fpga/project/sources.json` | 原始 290 文件冻结哈希 |
| `fpga/checkpoints/device_map/` | MAP ADF、PCF 和资源报告 |
| `fpga/checkpoints/place_route/` | 已完成的 PLC 布局数据库 |
| `fpga/scripts/portable_video_build.py` | 换机校验、工程生成、综合、布线、时序与位流入口 |
| `fpga/scripts/native_bitgen.py` | 同一已通过时序的 routed DB 位流生成门禁 |
| `fpga/evidence/` | MAP、模型、回归、主机解码和布线观察证据 |
| `fpga/docs/reference/` | 匹配板卡手册及安装版 PDS 手册副本 |
| `fpga/docs/history/` | 历史集成、拥塞和上板问题记录；状态可能早于本交接文档 |
| `fpga/docs/provenance.json` | 原路径、参考文件哈希、版本和迁移修改说明 |
| `fpga/build/` | 运行脚本后创建的新工程与结果，ZIP 不携带旧运行目录 |

`original_P12.pds`、原始 Tcl、日志和 JSON 中的旧绝对路径仅作来源记录，不作为换机执行入口。不要直接打开历史 PDS 来续跑。

## 4. 接收机准备

1. 安装 **PDS 2022.2-SP6.4 build 146967**，包括 PG2L100H 器件支持。脚本会读取目标器件的原生命令帮助，拒绝不匹配的版本或缺少功能的安装。
2. 安装 Python **3.11 或更新版本**；建议使用本次验证所用的 3.12。迁移构建脚本仅使用标准库，无需 pip 安装依赖。仿真证据的重新生成另需 Verilator/GCC 等工具，布线和位流生成不需要它们。
3. 在接收机配置有效 PDS 许可证。许可证与安装包不在 ZIP 内，不能直接沿用绑定原机的授权文件；参数 `--license-file` 只给构建进程设置 `PANGO_LICENSE_FILE`，不修改系统设置。
4. 解压到本机可写的短英文路径，例如 `D:\FPGA\pango_video_system_P12_20261018`。路径不要包含 `{`、`}` 或换行。为多次物理实现保留足够磁盘空间；实际内存和时间需求取决于 PDS 布线过程，没有已验证的固定配置下限。
5. 使用 ZIP 旁的 `.zip.sha256` 校验下载完整性；解压后再运行包内校验。无需原仓库、`reference/`、原机 `D:`/`E:` 布局或网络连接。

## 5. 推荐命令：从 MAP 重新布局布线

打开 PowerShell，进入解压后的包根目录。下面 PDS 与许可证路径必须改为接收机实际路径。

```powershell
cd D:\FPGA\pango_video_system_P12_20261018
python .\fpga\scripts\portable_video_build.py --mode verify
python .\fpga\scripts\portable_video_build.py --mode route-map --pds-home 'C:\Pango\PDS_2022.2-SP6.4' --license-file 'C:\Licenses\pango.lic'
```

`route-map` 使用包内 MAP/PCF，保留 DDR IP 上下文和全部板级约束，执行新的布局与布线。默认与 P12 一致：Normal、seed 11、decongestion 1、Global macro placement、planning_before_place TRUE、控制链 500、拥塞迭代上限 200、输出拥塞信息。`--seed` 可指定新布局种子，不能保证改善收敛。

默认 `--action-timeout 0` 表示不设原生 PnR 超时，不代表不可能失败；PG2L100H 为单线程布线器件。终端会打印 `RUN_DIRECTORY` 和当前日志位置。每次启动创建独立的新目录，不覆盖先前结果；运行期间保留终端，不并行修改其输出或输入文件。

布线成功后，脚本依次执行独立的 `report_timing -delay_type min_max`，确认新报告为 `All Constraints Met.`，核验同一 routed ADF 未改变，再执行独立 bitgen。失败会非零退出，记录原因且不继续生成候选位流。

## 6. 其他入口

### 只生成本机 PDS 工程或检查编译

```powershell
python .\fpga\scripts\portable_video_build.py --mode prepare --pds-home 'C:\Pango\PDS_2022.2-SP6.4' --license-file 'C:\Licenses\pango.lic'
python .\fpga\scripts\portable_video_build.py --mode compile --pds-home 'C:\Pango\PDS_2022.2-SP6.4' --license-file 'C:\Licenses\pango.lic'
```

打开命令打印的新 `fpga/build/<时间戳>/flow.pds` 可查看完整工程。该工程的显式 Tcl 步骤截止 MAP；后续物理流程、时序门禁和 bitgen 由脚本接续，推荐使用脚本完成交付。不要把 GUI 中手工生成的文件视为已通过脚本门禁。

### 从冻结源码重新综合并生成位流

```powershell
python .\fpga\scripts\portable_video_build.py --mode full --pds-home 'C:\Pango\PDS_2022.2-SP6.4' --license-file 'C:\Licenses\pango.lic'
```

`full` 执行 Compile → ADS Synthesize → Device Map → PnR → min/max STA → bitgen。`--mode map` 只做到 MAP。默认复用包内生成的 DDR/PLL，不重新生成 IP，不读取其他板卡示例。任何 RTL/IP/约束修改都需要单独版本、新清单、新模型验证和重新综合，不能混用原检查点；本脚本会拒绝清单不一致的修改。

### 从已完成布局重新路由

```powershell
python .\fpga\scripts\portable_video_build.py --mode route-placement --pds-home 'C:\Pango\PDS_2022.2-SP6.4' --license-file 'C:\Licenses\pango.lic'
```

该模式同时加载原 MAP/PCF 与 PLC，不重做布局。**它重新开始路由，不恢复原计算机内存中的某个详细布线迭代。** 已完成的 PLC 是磁盘检查点，未完成的 router 内存状态不在包内。原 PLC 来源布局种子为 11；该模式的 `--seed` 不改变已有布局。拥塞已经较严重时，复用旧布局未必有益。

## 7. 结果位置和验收

每次运行结果位于 `fpga/build/<时间戳>/`：

- `result.json`：运行模式、成功/失败、源包清单哈希、位流状态；`prepare/compile/map` 的 passed 仅代表对应阶段完成。
- `place_route.log`、`place_route/pango_video_system_pnr.adf`：新布线日志和最终数据库。
- `timing.log`、`report_timing/pango_video_system.rtr`：同一 routed 数据库的 min/max 时序报告。
- `bitgen.log`、`bitgen_checkpoint.json`：位流生成记录与数据库/时序报告前后哈希。
- `generate_bitstream/pango_video_system.sbit`、`BITSTREAM_SHA256.txt`：成功后得到的原生 SRAM 配置位流及校验值。

只有完整模式的 `passed=true`、`bitstream_generated=true`，同时原生日志无 E 错误、真实 routed DB 存在、min/max 报告通过、位流非空且哈希一致，才可作为本候选的离线构建结果。还须审查约束覆盖、未约束路径和板级 I/O 时序；报告通过不自动证明真实摄像头、DDR 或外部接口已经验收。

`.sbit` 为本流程的原生配置输出。本包不自动调用下载器，也不自动制作或烧写 Flash 固化镜像；若需掉电保存，须按板上实际 Flash、配置方式和官方配置手册另行准备。历史首次上板出现 `over_temp=1` 的问题仍需按既有记录完成排查与下载放行，生成文件本身不解除该限制。

## 8. 已有证据与未完成项

MAP 原生退出码 0，无 E 错误，冻结源码完整。资源报告为 LUT 41,616、FF 40,440、APM 117、DRM 86。它是映射结果，不能代替路由或时序签核。

冻结的完整帧模型结果通过：3 个几何任务，最大 4,114,261 个 125MHz 周期（约 32.914ms），检查完整 1920×1080 RGB 字节及参数/快照路径；模型中的 HDMI 扫描包含重复帧，网络全通路测试标记为 false。主机解码报告检验 8,888 个快照报文、12,441,600 字节。上述均为合成仿真数据，不是实板持续 1080p30、真实相机帧率或完整 S0 网络吞吐测量。

打包时复制的路由观察日志最新完整内部迭代为 60，未布通 32,509 / 100,568 子网；这只是文件快照，不是实时状态。没有本轮成功 routed/min-max/bitgen 证据。热点记录见 `fpga/docs/history/p12_congestion_diagnosis_20261018.md`；该历史报告的最后一节可能早于日志快照。

未完成项包括完整物理收敛、实板持续 1080p30、外部 I/O 签核、真实 DDR/网络/HDMI 联调、帧身份验收和功耗/热稳定性测量。HDMI 来源身份未确认时保持 null/unverified；严格精度比较使用同源 S1 与 S2/S3 快照，不用 S0 的 PC 可视化代替 S1。

本次迁移检查确认：85 项工程注册文件、88 项 IP 文件引用齐全，70 个模型/原生重叠源码完全一致；迁移后的工程生成、MAP/PLC 接续工程模板均经 PDS 原生解析。构建脚本的 4 项模拟工具测试通过，覆盖路由失败、时序失败、数据库变化和通过门禁后调用 bitgen；这些测试不代表实际位流生成。

额外的本机迁移 Compile 已完成设计展开及 sdm2adm，在保存数据库阶段主动停止，以结束本次包装任务额外占用的计算资源；**没有记为新的 Compile 成功，也不是自然编译失败**。原始 P12 对应的 Compile/SYN/MAP 成功记录仍保留。本次未重新完成综合、布局布线、时序或 bitgen，也未在第二台物理计算机上实际运行。迁移可用性仍须接收机执行上述命令确认。

详细结果见包内 `fpga/evidence/portability_validation.json` 及 `fpga/evidence/portability/` 日志。本次只停止本次额外 Compile 的进程，未修改或中断原 P12 布线。

## 9. 常见问题与继续开发

- 许可证失败：在新计算机重新配置有效授权；查看 `tool_help.log`。不要复制原机许可证内容到工程包。
- 缺少 IP 或黑盒：先执行 verify，确认安装版本；不要用其他 PG2L200H/100Pro 的 IP、引脚或位流替换。
- MAP/PLC 跨机读取失败：保留错误日志，使用 `--mode full` 从同一冻结源码重建。二进制检查点不承诺跨 PDS 版本兼容。
- 路由长时间不结束：查看每次完成的迭代与原生进程状态。CPU 活跃不等于一定收敛；更换多核机器不等于 PG2L100H 路由自动并行。
- 时序失败：保留 routed DB 与报告，优化真实路径；不要删掉约束或直接绕过 STA 生成发布位流。
- 校验失败：重新解压原包核对 SHA-256。开发修改应建立新候选并重新验证，不可仅改清单来宣称原 P12 仍一致。

交回结果时保留本次输入包 SHA-256、新 run 目录、完整日志、MAP/PCF、routed ADF、min/max 报告、bitgen_checkpoint、result.json、`.sbit` 和位流哈希，确保可以将结果绑定到唯一源码版本。

## 10. 官方依据与来源

只读查阅的安装目录为 `E:\PDS_Pangu\PDS_2022.2-SP6.4\doc`，未在其中写入任何文件。包内提供未修改的参考副本，原路径及 SHA-256 见 provenance.json。

- 安装版 PDS User Guide 印刷页 111、113、117：超时、布局策略、拥塞输出及 PG2L100H 单线程规则；印刷页 164–166：Tcl/项目命令流程；250、252：位流与物理选项。PDF 阅读器页码比印刷页码大 1。
- 安装版目标器件 `pnr -help`：`input_db_file`、`planning_before_place` 等真实可用参数；保存在 `fpga/docs/installed_pnr_help.log`。独立时序和 bitgen 沿用仓库已建立的原生命令入口，验证副本中另存安装版帮助。
- MINI 开发板硬件手册 V1.3 第 6 页：PG2L100H-6IFBG676；第 13 页：125MHz 差分参考 N3/N2 和 27MHz 时钟。具体连接仍应核对实际板卡及包内管脚约束。
