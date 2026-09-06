# Codex + PDS 快速开发方案

更新日期：2026-09-06（本轮为架构与路径同步）
适用项目：26-FPGA-Pango，PG2L100H（盘古100Kmini）。
当前视频基线：[OV5640 RAW8千兆网＋结果HDMI](OV5640_RAW8千兆网与HDMI双路回传方案.md)。原图S0网络接收、FPGA处理结果回采、严格同帧证据分别验收。
环境状态：第2节保留2026-09-05的检查记录，本次未重新运行环境探测、ModelSim或PDS，不能据文档更新声称工具/硬件验证通过。

目录遵循[AGENTS.md](../AGENTS.md)：实现与产物分别归fpga/、mcu/、host/；output/只放规划。Git仅排除根reference/和PDS/。安装版官方资料E:\PDS_Pangu\PDS_2022.2-SP6.4\doc始终只读。

## 1. 建议采用的工作方式

**Codex 负责需求拆分、资料定位、参考模型、RTL、测试和报告分析；ModelSim 负责自动仿真；PDS 通过命令行/Tcl 负责综合、布局布线、时序报告和位流。** PDS 图形界面用于首次核对器件、配置 IP、导出工程脚本，以及下载和片上调试。

按原环境检查记录，开工前先复核 PDS License 环境配置。在此之前，可以继续完成 Python 算法模型、RTL 编写和纯 RTL 仿真。对于现有两个月周期，先用最小工程打通工具链，再逐步复用板卡例程和接入算法。

```mermaid
flowchart LR
  A[需求与 reference 资料] --> B[Codex 编写模型、RTL、测试]
  B --> C[ModelSim 批量仿真]
  C --> D[PDS 综合与布局布线]
  D --> E[时序、资源、告警报告]
  E --> B
  E --> F[下载与上板测量]
  F --> B
```

## 2. 2026-09-05 本机检查记录

| 项目 | 本次发现 | 对开发流程的影响 |
|---|---|---|
| PDS | 已安装 2022.2-SP6.4，命令行报告 build 146967 | 固定此版本建立第一份可复现基线 |
| 安装位置 | `E:\PDS_Pangu\PDS_2022.2-SP6.4` | 脚本用完整路径；项目内 `PDS/` 是安装资料，不能当成实际安装目录 |
| 命令行程序 | `bin/pds_shell.exe`；帮助已实测 | 支持 `-file`、`-project`、`-work_dir`、`-project_name`、`-run` |
| PDS License | 执行 Tcl 时出现 `E: Flow-0183: Environment variable PANGO_LICENSE_FILE is not set.`，随后 `Check license failed.` | 当前命令行综合被阻塞；进程、用户、系统三个范围均未发现该变量配置 |
| 退出码 | 上述 License 失败仍返回 0 | 构建成功判定必须同时检查日志、阶段完成状态和本次产物 |
| ModelSim | `E:\ModelsimSE\win64\vsim.exe`，SE-64 10.1c，2012.07 | 已通过最小批量仿真，日志出现 `SMOKE_PASS count=4`（输出空格已归一化），仿真时间 42 ns |
| Pango 仿真库 | 已检查的 ModelSim 全局 `modelsim.ini` 没有 usim/vsim 映射 | 尚未验证 Pango 原语/IP 联合仿真，不能把纯 RTL 测试通过当作 IP 可用 |
| DDR IP | 检查到的 Logos2 HMIC_S 条目为 1.10，DDR 测试例程的 IDF 也标为 1.10；资料另有 `ips2l_hmic_s_v1_16a.iar` | 首次构建按例程依赖固定版本；新包是否需要安装应逐项核对，不能直接覆盖升级 |
| 示例器件 | 已检查的按键 LED 例程为 Logos2 / PG2L200H / -6 / FBB676 | 当前项目目标为 PG2L100H，不能直接把原例程位流下载到目标板 |
| 路径 | 当前项目根目录为英文路径；reference 内仍有中文目录 | 从资料导入需要构建的文件时，放入英文路径，并修复源码/IP/初始化文件的引用 |

ModelSim 首次运行在日志初始化时失败；改用明确工作目录与绝对日志路径，并在获准的本机执行环境中重试后通过。因此首次落地还要验证 Codex 正式工作区内的执行权限与路径，不把所有初始化失败都归为 License 问题。

未完成的验证：PDS 正式综合、布局布线、Pango 仿真库编译、DDR IP 仿真、下载器连通和实物功能测试。本次没有修改 License 配置、安装 IP 或下载位流。

## 3. 首次配置：按依赖顺序处理

### 3.1 关联已有的有效 PDS License

按 reference《01_PDS安装指导手册》第 9～10 页，把 `PANGO_LICENSE_FILE` 指向合法、有效的 License 文件。此次检查未在 PDS 安装树中找到 `.lic`，这不代表机器其他位置一定不存在。

建议由后续 `env.ps1` 读取本地配置，在启动 PDS 的当前进程内设置变量。License 内容和机器绑定信息不写入 Git、AGENTS.md 或公开报告。配置完成后的验收是让最小 Verilog 工程真正通过综合，不能只执行 `-help` 或 `-version`。

第一版选用 Verilog-2001 可综合子集和 ADS，与已读例程一致。SystemVerilog/VHDL 或 Synplify 的采用另行核对当前版本语言支持与授权；旧安装手册的语言授权说明不能替代本机实际验证。

### 3.2 建立目标板配置

在 PDS 中选择 PG2L100H，并根据实物和匹配资料核实速度等级、封装、晶振、复位、电压和管脚，保存成目标板配置。已有 PG2L200H 例程里的 `FBB676` 是工具配置字段，不应通过字符串替换推断 PG2L100H 的正确封装选项。

建议形成 `fpga/config/board.json` 与 `fpga/constraints/board.fdc`，记录每项值的资料来源和确认状态。PG2L100H、PG2L200H、PGX-NANO、100Pro+ 的工程分别保留配置，不能混用引脚和 DDR 参数。

### 3.3 先复制最小例程，再复制复杂例程

首选 reference 中 `2_7_key_led_test` 作为工具链基线；下一步使用 `2_8_uart_test` 建立状态输出，再处理 `2_9_ddr3_test`、RAW视频和匹配MINI的RGMII/以太网例程。MAC、UDP与原图DMA需要联合验证，不能只测试网络链路灯。

导入内容包括 RTL、约束、IP 配置及必要生成源码、ROM/寄存器初始化文件、仿真模型。不要只复制顶层 `.v`；也不要依赖资料里已有的编译数据库、历史位流或绝对路径。

### 3.4 编译并固定 Pango 仿真库

根据《04_PDS与modelsim联合仿真》和安装目录《Simulation_User_Guide》，在 PDS 的 `Tools → Compile Simulation Libraries` 中先生成所需库：

- Simulator：ModelSim；实际程序目录使用 `E:\ModelsimSE\win64`，不要照抄教程截图中的其他路径。
- Family：目标系列 Logos2；首轮只编译需要的系列。
- Language：与当前源码一致，首轮优先 Verilog。
- Library：usim 对应前仿；需要后仿时再编译 vsim 及相应模型。
- 输出位置：项目 `fpga/build/simlib/` 下按 PDS 版本、仿真器版本和系列区分缓存。

保存界面生成的 Tcl 命令和库编译脚本，之后由 Codex 重复调用。PLL、FIFO、DDR 等实际设计还要包含各 IP 的专用仿真文件；仅存在 usim 库不证明所有 IP 模型齐全。

## 4. 建议的项目布局

以下是后续待建立的目录和文件；本次只交付方案。

```text
26-FPGA-Pango/
  AGENTS.md
  reference/                  # 原始资料，仅本地
  PDS/                        # 安装资料，仅本地
  output/                     # 规划与接口文档
  scripts/backup.ps1           # 仅仓库备份
  fpga/
    config/                   # board/toolchain/sources配置，不存License正文
    rtl/
      video/                  # RAW接收、ISP、时序与HDMI输出
      geom/                   # 坐标映射与插值
      memory/                 # S0/S1/结果/快照池与DDR适配
      network/                # RGMII、MAC、IPv4/UDP、RAW组包与限流
      control/                # UART、参数解析与计数
    ip/
    constraints/
    sim/
    model/                    # 权威浮点与位精确参考
    scripts/                  # env/doctor/test/build/report入口
    build/                    # 运行产物，按现有规则受Git管理
    reports/
    release/
  host/                       # PC实现、配置、数据、报告与发布
  mcu/                        # MCU固件、测试与产物
```

PDS 手册物理第 247 页规定了文件与目录命名允许的字符。实际参与构建的路径使用英文、数字和下划线；中文资料可以保留在 reference 中供阅读。IP 文件命名限制更严格，按手册和工具校验执行。

## 5. Codex 日常操作接口

给 Codex 固定少量入口，内部细节由脚本管理。

| 拟建立的入口 | 功能 | 必须返回的结果 |
|---|---|---|
| `doctor.ps1` | 检查版本、License 配置、工具路径、目标板、源文件和仿真库 | PASS / FAIL / 未验证，指出具体原因 |
| `test.ps1 -Suite unit` | 运行受影响模块的 ModelSim 自检测试 | 用例结果、耗时、失败位置、日志 |
| `test.ps1 -Suite image` | Python 生成预期输出，与 RTL 像素/坐标输出比较 | 最大误差、错误像素数、边界错误和吞吐统计 |
| `build.ps1 -Stage synth` | 编译和综合 | 语法/连接/位宽告警、资源估计、License 状态 |
| `build.ps1 -Stage timing` | 运行到布局布线和时序报告 | 各时钟域 setup/hold 最差裕量、约束覆盖、资源 |
| `build.ps1 -Stage bit` | 生成候选位流并整理本次结果 | 新产物路径、哈希、工具/IP/板卡配置及报告 |

以上名称是拟定接口，不是本机已经存在的脚本。

日常每次只运行与改动有关的模块测试；接口集成后运行小图和连续多帧测试；阶段版本再做完整布局布线。这样可缩短功能错误的反馈周期，同时保留定期检查真实时序和资源的机会。

### 5.1 PDS 调用方式

本机 `pds_shell.exe -help` 已确认下列入口参数。下面是完成初始化后使用的调用示例，文件位置需由落地脚本建立；由于当前 License 未配置，完整构建尚未验证。

```powershell
$pdsExe = 'E:\PDS_Pangu\PDS_2022.2-SP6.4\bin\pds_shell.exe'

# 使用已经核对并复制到英文路径的工程
& $pdsExe -project 'D:\XDU\concept\26-FPGA-Pango\fpga\build\pds\video_top.pds' -run synthesize

# 使用可重建工程的完整 Tcl 脚本
& $pdsExe -file 'D:\XDU\concept\26-FPGA-Pango\fpga\scripts\build.tcl' `
  -work_dir 'D:\XDU\concept\26-FPGA-Pango\fpga\build\pds' `
  -project_name video_top
```

第一轮优先运行核对过的 `.pds`。基线通过后，在 PDS 中通过 `File → Export Project To Tcl` 导出完整工程，保留文件列表、IP、器件和选项，再整理为版本控制中的 `build.tcl`。手册还支持同时导出 Windows 批处理文件，可作为参数和调用顺序的依据。

**不能把 reference 的 `impl.tcl` 直接当作完整工程重建脚本。** 已检查的按键 LED 例程 `impl.tcl` 只有器件选择和流程动作，没有源码及约束的导入。新工作目录必须由完整导出脚本或显式文件清单重建设计。

已读例程的主要动作顺序为：

```text
导入源文件、IP和约束，选择目标器件
→ compile
→ synthesize -ads
→ dev_map
→ pnr
→ report_timing
→ gen_bit_stream
```

脚本中精确参数以当前版本导出结果为准，不套用其他厂商 FPGA 工具的命令。

### 5.2 成功判定与结果保存

- 同时检查退出码、`E:` 错误、`Check license failed`、严重告警和各阶段实际完成状态。此次已实测证明：退出码 0 不足以判定 PDS 成功。
- 仿真须有自动比较和明确 PASS 标记；超时、断言失败、ModelSim Error/Fatal、未到达 PASS 均判失败。
- 输出目录隔离每次构建；记录起止时间和本次生成文件，防止把原资料的旧位流当成本次结果。
- 时序验收覆盖 setup 与 hold、各时钟域和未约束路径；不能只看一项 Fmax 或位流是否生成。
- `fpga/reports/latest.md` 面向人阅读，`fpga/reports/latest.json` 提供可机读字段；保留原始日志，禁止通过隐藏错误获取 PASS。
- 允许清单只豁免已经分析、有理由的告警；不能将 latch、多驱动、关键位宽截断和缺失约束整体忽略。
- 成功报告包含源码版本或输入哈希、PDS 版本、板卡配置、IP 版本、测试集合、时序结果与位流哈希。

## 6. 结合现有 1080p 畸变矫正项目的实施顺序

| 阶段 | 重点开发内容 | 通过条件 |
|---|---|---|
| A：工具链基线 | License、PG2L100H 配置、LED/UART、脚本与报告 | 同一输入可从干净工作目录重建；最小测试和综合通过；上板能观察状态 |
| B：参考模型与算术模块 | Python 浮点/定点模型；坐标计算、舍入、饱和、双线性插值 | RTL 与位精确模型逐样本一致；另行评估定点模型相对浮点的误差 |
| C：视频数据通路 | 模拟视频源、行帧标记、FIFO/缓存、DDR适配、输出适配 | 小图、连续帧、停顿和复位测试通过，像素与有效信号保持对齐 |
| D：真实相机和内存 | 复用对应板卡例程，验证单路RAW8 DVP、基本ISP、76MiB帧池、RGMII/UDP与帧管理 | 实测尺寸、帧间隔、帧计数、DDR带宽和错误计数，不能只看显示器有图 |
| E：1080p30 整机 | 接入逆映射、插值、旋转、Gamma、RAW网络30FPS、结果HDMI30及控制 | 按现有设计方案完成真实输入帧率、图像精度、处理吞吐和长稳验收 |
| F：1080p60 扩展 | 基于独立真实60fps输入源重新评估时序和带宽；RAW满流超千兆，原图回传须另设计 | 单独记录输入/处理/输出帧率，保留30fps稳定版本 |

1080p30 必达、1080p60 需更换真实视频源等目标来自现有详细设计方案，本次未重新验证摄像头模式或硬件带宽。低分辨率仿真仅用于缩短调试时间，不能代替1080p验收。

适合先交给 Codex 的三个独立模块：

1. **视频计数与校验模块**：统计有效像素、行、帧和异常；先建立测量能力，避免后续只凭视觉判断。
2. **双线性插值模块**：明确坐标小数位、像素位宽、舍入和边界策略；生成随机及边界测试。
3. **参数更新与帧边界切换模块**：测试 UART 命令解析、影子寄存器和帧同步生效，避免一帧内参数变化。

DDR PHY、PLL、高速串行输出和已验证 FIFO 优先复用匹配器件的 Pango IP，通过适配层连接自研逻辑。Codex 重点编写接口、控制、缓存和可测算法；先通过原例程再修改 IP 参数。

## 7. 给 Codex 的项目约定

根目录已有[AGENTS.md](../AGENTS.md)，后续直接遵循并保持一致，不重新生成另一套项目约定。官方参考资料保持只读，规划和实现分别在规定目录中维护。

执行时重点核对：

- 当前设计依据是 `output/PG2L100H_1080p畸变矫正详细设计方案.md`，历史50K方案只供追溯。
- 先用 `reference/内容索引.md` 定位具体资料，按需读取，不每次遍历上万份编译产物。
- 核对目标板配置；禁止从其他平台例程猜填引脚、Bank电压或时钟。
- 生产 RTL 采用已经在当前 PDS 综合链上验证的语法；明确接口、时钟域、复位、延迟与有效信号。
- 定点计算明确位宽、有符号性、缩放、舍入、饱和与中间溢出；修改后更新参考模型和相关测试。
- 每项功能完成时报告：改动、运行的验证、结果和未验证项；不能把仿真通过写成上板通过。
- 不直接修改参考例程；正式开发文件放入项目英文源码路径，记录导入来源。
- 按任务执行必要验证；工具环境、License 或硬件阻塞时准确标注，并继续独立的开发工作。

## 8. 日常任务描述模板

可以直接向 Codex 发出这类任务：

> 按当前 PG2L100H 设计方案实现双线性插值模块。先明确输入输出协议、像素位宽、坐标小数位、舍入规则和流水延迟；建立 Python 位精确模型及自动比较的 ModelSim 测试，覆盖四角、整数坐标、边界、极值和随机输入。运行相关测试并生成结果摘要。工具链可用时完成一次模块综合，报告资源和时序限制，不修改其他模块或原始 reference 资料。

板级联调任务则应补充实物版本、输入源、接线和可观察结果。例如“连续统计100帧的有效尺寸和帧间隔，并通过UART读出”，比“让摄像头正常显示”更容易自动验证。

## 9. 第一批落地交付物与完成标准

建议按以下顺序实施，工时是计划估计，依赖有效License和板卡信息：

1. **环境与板卡确认**：建立本地工具配置、License检查、目标板配置及最小综合，预计半天到一天；License取得时间不包含在内。
2. **自动化入口**：建立 `doctor/test/build/report`，跑通纯RTL回归与最小工程重建，预计一到两天。
3. **板级基线**：完成 LED/UART、DDR和视频例程的逐项适配与测量；按现有周计划推进，实际时间取决于板卡差异与IP。
4. **算法迭代**：每项功能都有模型、RTL、测试与报告，再接入整机。

第一批交付完成的标志是：Codex 能从明确输入生成结果、运行测试、调用 PDS 构建，并从报告中判断真实成功或失败；随后用户只需描述功能和验收条件，即可持续迭代。

## 10. 依据与检索入口

页码均指 PDF 物理页序，从1开始。

| 来源 | 本方案使用的信息 |
|---|---|
| [01_PDS安装指导手册](../reference/盘古100K200K%20MINI开发板/1_Demo_document/工具使用篇/01_PDS安装指导手册.pdf) p.9–10 | License 环境变量配置与综合工具授权提示 |
| [02_PDS快速使用手册](../reference/盘古100K200K%20MINI开发板/1_Demo_document/工具使用篇/02_PDS快速使用手册.pdf) p.3–4、23–25 | 工程创建、仿真库和激励文件 |
| [03_IP核安装与查看用户指南](../reference/盘古100K200K%20MINI开发板/1_Demo_document/工具使用篇/03_IP核安装与查看用户指南.pdf) p.1–4 | IP Compiler、Add Packages、View Datasheet |
| [04_PDS与modelsim联合仿真](../reference/盘古100K200K%20MINI开发板/1_Demo_document/工具使用篇/04_PDS与modelsim联合仿真.pdf) p.1–4 | 仿真器目录、usim/vsim、系列与库输出目录 |
| [安装版 PDS User Guide](E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Pango_Design_Suite_User_Guide.pdf) p.33–35、165–167、247–255 | 导出Tcl、命令行运行、命名规则、构建和仿真库命令 |
| [安装版 Simulation User Guide](E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Simulation_User_Guide.pdf) p.6–9 | 仿真阶段、库的作用和库编译脚本 |
| [按键LED工程](../reference/盘古100K200K%20MINI开发板/2_Demo/2_7_key_led_test/2_7_key_led_test/key_led_test.pds) / [impl.tcl](../reference/盘古100K200K%20MINI开发板/2_Demo/2_7_key_led_test/2_7_key_led_test/impl.tcl) | 示例器件、源文件引用及实际流程动作 |
| [当前详细设计方案](./PG2L100H_1080p畸变矫正详细设计方案.md) | 目标平台、单路输入、30fps交付及60fps扩展边界 |
| [reference 内容索引](../reference/内容索引.md) | 后续按接口、文档、工程或模块检索 |

环境证据来自本机 PDS 帮助输出、一次受License阻塞的Tcl调用、ModelSim版本及最小自检仿真、安装目录和工程配置读取。任何尚未运行的正式脚本与性能指标均作为后续实施内容。

## 11. 当前回传架构的专项检查

- 网络64字节头＋最多1400字节载荷、CRC32、乱序/重复/缺块/重传边界与PC接收器共同验证；UART继续原CRC16协议。
- RAW DDR stride2048与线上stride1920分别定义；SRC/DST行跨度6144，快照导出只保留有效RGB像素。帧池共76MiB，未计掩码等诊断空间。
- 参数解析测试覆盖K/D字段顺序、负数和定点范围、尺寸/模型不符、实际寄存器回读与帧边界整组生效。
- PC基础RAW预览不等于S1；连续HDMI帧身份未验证时保持null/unverified，不能由测试脚本推测为已配对。
- 网络断连、快照限流、输出欠载、独立PC演示和板级能效均需上板证据；报告明确此次是否包含片上调试逻辑。

以上项目按[跨端回传方案](OV5640_RAW8千兆网与HDMI双路回传方案.md)及最新[两个月计划](两个月开发规划表.md)组织。本文环境实测记录保持原日期；文档一致性检查不替代PDS、RTL或硬件测试。
