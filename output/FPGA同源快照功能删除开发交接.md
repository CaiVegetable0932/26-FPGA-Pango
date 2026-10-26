# FPGA 同源快照功能删除开发交接

日期：2026-10-20。状态：删除决定已确认，代码修改待执行。面向 FPGA、上位机和验证维护者。

后续整体范围见[FPGA 仿射与图像增强及剩余功能实施交接](FPGA仿射与图像增强及剩余功能实施交接.md)：完整透视改为仿射、亮度增强精简并新增可控 CCM，其他保留功能按阶段完成。本文件继续负责同源快照删除；新方案的一帧历史补全不恢复快照触发或双图导出。

用户已确认删除同源快照功能及其对应实现。删除目标是完整移除“选择同一源帧的 S1 和处理结果、复制到独立槽、通过网口导出”的业务链路，不是隐藏按钮或把 `SUPPORT_SNAPSHOT` 固定为 0。

本次交付为实施交接文档，尚未修改 RTL、协议实现、上位机或测试。本决定取代旧规划中将板端同源快照列为必备功能的要求；其他视频、参数控制与帧身份约定继续有效。后续实施不需要重新确认是否删除，实施人员应完成代码、文档和验证的同步调整。

## 1 删除后的功能边界

正式数据路径保留：

```text
OV5640 RAW8 → FPGA 接收
                 ├─ S0 帧池 → RAW 网络读 → 千兆网 → PC 原图接收
                 └─ 基础 ISP → S1 帧池 → 几何处理及可选增强
                                            ↓
                                        结果帧池 → HDMI

PC UART → 启动配置、系统状态、增强模式、几何参数提交与读回
```

| 删除内容 | 必须保留的相邻能力 |
| --- | --- |
| 同源快照触发 `0x93` | `0x71` 启动配置，`0x90` 系统状态 |
| 快照描述符读回 `0x96`、快照几何实体读回 `0x97` | `0x92` 增强模式，`0x94` 几何参数提交，`0x95` 活动几何实体及生效帧读回 |
| SNAP_S1、SNAP_RESULT 两个专用帧槽 | SRC、DST、RAW 三组主视频帧池，各自三个槽 |
| 配对选择、复制 DMA、快照 RGB 网络发送 | RAW_LIVE 原始网络流、ARP/MAC、HDMI 显示、几何缓存回填 |
| 上位机快照请求、描述符解析、双图重组和成对保存 | RAW 重组与归档、HDMI 采集、标定与普通图像导入 |
| 快照业务专用测试和维护脚本 | 主视频、参数原子生效、故障排空、帧身份与像素正确性测试 |

S1、S2/S3 的内部阶段定义仍用于主流水，不能因删除导出功能而删除这些阶段。PC 不接替 FPGA 实时几何处理。原始证据仍保存 RAW/RGB 与元数据；PNG 仍是派生可视化。

## 2 当前实现与证据

本次核对的是工作区当前文件，核对时 Git HEAD 为 `8bc75f0de3c13445a4bd67f8e7f10ed67bd8b586`。工作区已有其他修改，HEAD 不能替代实际文件版本；实施前须记录本次涉及文件的差异和哈希，保留其他任务成果。

当前整机 `pango_video_system.sv` 显式启用 `SUPPORT_SNAPSHOT(1)`。`video_memory_core.sv` 将快照复制和导出共用到 DMA 客户端 6，主视频客户端为 0～5。快照配对在下一次成功分配 S1 的采集帧上锁定身份，不是对当前 HDMI 任意截图。

已有使用证据属于仿真和离线验证：

- [10 月 13 日集成记录](../fpga/reports/full_integration_20261013.md)：完整 1080p、同源快照和旧／新参数保留验证。
- [10 月 20 日主机报告](../host/reports/fpga_rgb_vectors_20261020_052259_836952.json)：两幅 1920×1080 RGB，共 8,888 报文和 12,441,600 字节；`passed=true`，来源为合成 RTL UART/GMII，`hardware_tested=false`。
- [10 月 20 日交接记录](../fpga/reports/route_optimization_handoff_20261020.md)：完整帧控制／快照／显示回归，以及快照关闭夹具通过。关闭夹具只能用作辅助对照，不能证明彻底删除后的实现正确。

保留上述历史报告、原始测试产物和冻结源码，不改写为新版本结果。当前没有据此确认过实板同源快照采集成功。

资源补充：用户要求 LUT 使用率低于 70%。当前已核实 MAP 为 41,477 / 66,600，即 62.28%，已满足该比例；快照专用层级合计 3,197 LUT、6,905 FF，完整删除的净收益暂估 3,200～5,000 LUT，必须以新版本 SYN/MAP 确认。详见[功能裁剪与 LUT 资源评估](../fpga/reports/功能裁剪与LUT资源评估_20261020.md)。低于 70% 不代表布线与时序必然通过，禁止为达到比例而删掉主链正确性保护。

## 3 外部接口删除规则

### 3.1 PC 串口协议

维护 [PC_RGB_CONTROL.md](../fpga/config/integration/PC_RGB_CONTROL.md) 与对应 RTL、host 编解码。

| 项目 | 删除后的要求 |
| --- | --- |
| `0x93`、`0x96`、`0x97` | 移除业务处理与专用后端；编号保留为已撤销，不复用 |
| 旧客户端发送已撤销命令 | 对合法封装请求走通用不支持回应，使用既有 NAK code=6；不得 ACK 成功、无限等待或意外触发其他操作 |
| capability bit8 | 清零；不把其他功能移入该位 |
| `0x90`、`0x95` | 保留 page0 冻结、多页一致读回及合法页范围 |
| `0x92`、`0x94` | 保留校验、版本递增、影子提交、源帧边界生效与实际应用记录 |
| PC V1 封装与既有 RAW 启动 | 保留长度、序号、CRC 和错误恢复规则；不因内部帧池收缩更改未受影响的线格式 |

检查能力位和状态说明中是否还间接宣告快照可用。原有状态页布局尽量保持；若发现必须变更的字段，先在接口文档列明新旧布局并同步测试，不静默改变。

`pc_video_boot.sv` 中的 `status_snapshot`、`have_snapshot`、`snapshot_operation` 服务于分页状态冻结，其中仍被 `0x90/0x95` 使用的逻辑必须保留。删除 192 字节双快照读回后，可将存储收缩到保留命令所需的 96 字节，但仍须验证原子读回。名称可改为清楚的 readback 名称，不能按关键字整段删除。

### 3.2 网络协议

正式网口仅保留 `packet_type=1 RAW_LIVE` 图像输出。撤销 type=2 SNAP_S1、type=3 SNAP_RESULT 的生产发送和在线接收路径；类型值保留为旧协议编号，不重新解释为其他图像。

RAW_LIVE 的 PRAW V1 头、RAW8 格式、Bayer 字段、epoch/frame_id、版本、descriptor_id、CRC、分包及完整性规则保持不变。通用 descriptor_id 不是快照专属字段，不能删除。

新上位机收到旧快照类型应明确按不支持类型拒收，不申请双 RGB 帧缓冲，不混入 RAW 流，不影响后续合法 RAW 接收。历史格式说明可归入历史说明；旧报告的冻结解码器继续保留，正式客户端无需继续提供在线快照能力。

## 4 FPGA 修改清单

以下路径均相对仓库根。专用文件删除前核对全部引用，清理活动构建列表；共享文件只删除快照业务部分。

| 文件或范围 | 处理要求 |
| --- | --- |
| `fpga/rtl/control/video_snapshot_service.sv` | 删除整个快照服务模块及活动工程引用 |
| `fpga/rtl/memory/frame_snapshot_pair.sv` | 删除配对、独立槽分配、快照复制与导出协调模块 |
| `fpga/rtl/memory/snapshot_copy_dma.sv` | 删除专用复制 DMA；不删除主视频 DMA |
| `fpga/rtl/board/pango_video_system.sv` | 删除快照控制、描述符总线、端口连接及 SUPPORT_SNAPSHOT 配置；保留启动、状态、增强和几何控制 |
| `fpga/rtl/board/video_memory_core.sv` | 删除快照服务实例、客户端 6、快照总线及关闭时的占位分支；移除快照命令合并，按实际保留客户端重整 packed 总线 |
| `fpga/rtl/control/video_frame_scheduler.sv` | 删除 arm/request 状态机、快照源身份追踪、快照专用 claim/skip；保留正常采集、几何、网络和显示生命周期 |
| `fpga/rtl/control/pc_video_boot.sv` | 删除三个命令的业务解析、SNAPSHOT_SUBMIT 状态及专用端口；保留通用不支持回应与状态冻结 |
| `fpga/rtl/memory/frame_manager_pkg.sv` | 删除 SNAP_S1、SNAP_RESULT 和 SNAPSHOT 消费者语义；删除 `snap_exact/snap_slot/snap_gen` 专用请求字段 |
| `fpga/rtl/memory/frame_manager.sv` | 银行数由 5 改为 3，移除快照地址和单槽银行实例；主视频槽大小与地址保持 |
| `fpga/rtl/memory/frame_pool_bank.sv` | 删除快照精确槽选择条件；同步消费者数量、引用位图、release/acquire 数据布局及 owner 范围 |
| `fpga/rtl/memory/frame_manager_layout.vh` | 从修改后的 package 重新生成；不得手工改偏移而遗漏其他结构字段 |
| `fpga/rtl/memory/frame_memory_fabric.sv` | 收缩银行／客户端总线与循环，删除快照地址分支、allow_snapshot 和末客户端特殊门控；保留地址、代次、所有权、票据及取消排空保护 |
| `fpga/rtl/memory/ddr_native_dma.v` | 删除快照专用末客户端判断；同步客户端数与端口，保持原生事务完成、取消、读回确认语义 |
| `fpga/rtl/network/raw_network_service.sv` | 删除快照 raw_frame_tx 实例、快照与 ARP 的内层仲裁、快照端口和取消分支；保留 RAW 与 ARP 的外层包仲裁及 MAC |
| `fpga/rtl/network/raw_frame_tx.sv`、`praw_udp_tx.sv` 等共用网络模块 | 保留 RAW 发送；审查并删除仅为快照引入且无其他调用者的可变类型／RGB 配置分支，不能整文件删除 |
| 其他顶层、探针、源文件列表、工程生成脚本 | 更新上述模块的接口与文件引用，不能仅让一个顶层可编译 |

消费者可从 4 个收缩为 PROCESS、DISPLAY、NETWORK 三个；应统一修改 `frame_cmd_t/frame_rsp_t`、向量切片、常量拼接、循环和测试夹具，不只改枚举。`issue_owner=0` 的生产者写语义，以及三个保留消费者的读语义须一致。META_BITS 所对应的帧元数据不因内部消费者收缩而任意裁剪。

### 4.1 必须修复的末客户端依赖

当前 `frame_memory_fabric.sv` 有 `(c!=N-1 || allow_snapshot)`，`ddr_native_dma.v` 有 `(i==CLIENTS-1 && !allow_snapshot)`。删除客户端 6 后，客户端 5 是 RAW 网络读取。如果仅改 `N/CLIENTS=6` 并保留上述判断，会把正常 RAW 通道错误当成快照通道。

必须取消这项业务特殊判定，检查轮询索引、最大等待统计、urgent 位图和所有客户端切片。增加“最后一个客户端仍能完成 RAW 读取并持续发送完整帧”的回归。

保留客户端映射为：0 RAW 写、1 S1 写、2 几何源读、3 结果写、4 HDMI 读、5 RAW 网络读。若实施中改编号，须同步列出新映射并验证全部端口，避免隐式错连。

### 4.2 帧池布局

优先保持主视频已有地址，避免引入无关重排：

| 银行 | 保留容量 | 起始地址 | 结束地址，不包含 |
| --- | --- | --- | --- |
| SRC | 3×8 MiB | `0x00000000` | `0x01800000` |
| DST | 3×8 MiB | `0x01800000` | `0x03000000` |
| RAW | 3×4 MiB | `0x03000000` | `0x03C00000` |

撤销 `0x03C00000～0x04400000` 的 SNAP_S1 和 `0x04400000～0x04C00000` 的 SNAP_RESULT 预留。三组视频槽总规划跨度由 76 MiB 变为 60 MiB，减少 16 MiB 专用预留；这不是物理 DDR 容量减少，也不是已测得的 LUT/BRAM/功耗节省。

保持 SRC/DST stride=6144、RAW stride=2048，以及线上 RAW 紧凑行宽 1920。无效 bank、槽号、owner、跨槽请求仍须拒绝。不要把 `CAPACITY_BYTES` 的实际控制器窗口与视频槽预留跨度混为一谈。

## 5 上位机修改清单

| 文件 | 处理要求 |
| --- | --- |
| `host/src/pango_video/fpga_rgb_control.py` | 删除 `snapshot()`、`snapshot_descriptor()` 和 0x96/0x97 分页支持；保留 mode、geometry、reply 和 0x90/0x95 读回 |
| `host/src/pango_video/protocol.py` | 删除在线快照格式支持，保留 RAW 解码校验；旧类型明确拒收 |
| `host/src/pango_video/reassembly.py` | 删除 SnapshotSpec、validate_specs、admit_snapshot、close_snapshot、快照超时／配对内存／统计分支；保留 RAW 乱序、重复、缺包、epoch 和内存限制 |
| `host/src/pango_video/storage.py` | 删除 save_snapshot_pair 及其专用描述符处理；保留普通 RAW 证据、元数据和原子保存 |
| `host/src/pango_video/ethernet.py` | 删除把非 RAW 线上类型统称 snapshot 的分支；非法类型不可伪装成合法 S0 |
| `host/src/pango_video/web_session.py` 与相关 UI/API | 清理 snapshot_request_available 和未来入口描述；必要兼容字段只能明确为功能已移除，不能显示待连接或即将可用 |
| `host/scripts/verify_fpga_rgb_vectors.py` | 移除视频快照二进制与 0x93/0x96/0x97 的生产回归要求；保留有效的控制协议核对与冻结源码机制，调整名称／报告字段以匹配剩余职责 |
| `host/tests/test_transport.py`、控制与 Web 测试、协议向量 | 移除快照正向功能用例，增加旧命令／旧图像类型拒绝用例；不能连带删除 RAW 测试 |

禁止因含 RGB、snapshot、capture 等字样而批量删除普通 HDMI 拍照、标定图导入、历史 RGB 数据、会话状态一致性或其他图像保存功能。对剩余调用者逐一检查再删共享工具。

## 6 测试与构建迁移

### 6.1 活动入口清理

- 删除 `fpga/sim/tb_frame_snapshot_pair.sv` 及活动测试清单中的对应项目。
- 修改 `tb_pc_runtime_control.sv`：原快照成功／busy／描述符用例改为撤销命令不支持测试；保留启动、状态、增强、几何更新与冻结分页测试。
- 修改 `tb_video_memory_core.sv`：删除 SNAPSHOT_TEST、快照 arm、快照导出文件与专用层次探针，保持完整帧像素、处理完成、显示、网络与错误恢复断言。
- 修改帧池、fabric、DMA、元数据、参数化和网络相关夹具，适配三银行、六客户端、三消费者；保留原有宽票据、代次和回压检查。
- 更新 `fpga/scripts/sim_full_integration.py`、`sim_video_verilator.py`、`sim_frame_manager.ps1`、构建脚本及工程源列表，移除 `--snapshot-test` 和专用源码。清查 `probe_regional_route.py`、`run_video_route_attempt.py` 及其他硬编码源列表。
- `prepare_snapshot_local_capture.py`、`prepare_snapshot_control_repair.py`、`probe_snapshot_capture_mapping.py`、`verify_snapshot_local_capture.py`、`verify_snapshot_control_repair.py` 等专用脚本不再作为当前开发入口；核实无其他职责后删除活动脚本，旧实验副本保留在既有冻结证据中。

### 6.2 必须保留的其他快照概念

`counter_snapshot_cdc.sv` 是计数器跨域一致采样；PC 状态分页使用冻结读回；`--rtl-snapshot`、`--fixture-snapshot`、companion snapshot 是源码／工具版本冻结。它们与本次视频同源快照无关，必须保留。

`audit_ddr_snapshot.py` 等名称仅作为检索入口，按职责决定，不能仅凭名字删除。保留已有源码哈希、冻结输入、历史日志、报告和原始数据，不递归清理 build/reports/data 来制造“没有 snapshot”。

### 6.3 删除后的替代验证

删除视频快照不能同时删除证明主流水正确的观察点。用仿真测试平台读取完成并已确认写入的 S1/DST 内存，或在真实写入接口建立测试平台记分板；与相同输入、相同参数的参考结果逐字节核对。此观察只存在于仿真，不重新添加可综合的双帧复制／网络导出模块。

参数保持测试继续验证：旧排队源帧使用旧几何／增强实体，新采集帧使用新实体。通过处理作业绑定参数、结果像素和现有状态读回建立证据，不能把快照删除后的全部用例替换成恒等映射。

正式硬件侧暂不再具备板端 S1／结果同帧直接导出的能力。普通网口 S0 与 HDMI 回采仍只能作为独立流，HDMI 来源未验证时保持 `source_frame_id=null`、`pairing_status=unverified`。静态图卡或 HDMI 离线分析可以报告各自的图像质量，但不能冒充原先同源像素对照；严格实板同帧精度验收标为当前范围不提供／待另行设计，不能沿用旧快照 PASS。

## 7 文档与项目约定同步

实施代码删除时，同批维护以下活动文档：

| 文档 | 必须更新 |
| --- | --- |
| `AGENTS.md` 的当前视频与测评基线 | 将“严格精度使用板端同帧快照”改为删除后的能力边界，保留来源诚实性要求 |
| `output/OV5640_RAW8千兆网与HDMI双路回传方案.md` | 架构图、60 MiB 三组帧池、RAW-only 网络图像、协议撤销、带宽预算与测评边界 |
| `output/PG2L100H_1080p畸变矫正详细设计方案.md` | 去掉快照必备功能、复制与快照带宽预算；保留内部 S1/S2/S3、主几何与增强 |
| `output/可控光照箱与上位机测评详细实施方案.md` | 去掉快照按钮和周期采集任务，调整精度、配对、功耗与验收条目 |
| `output/host/00_输入输出与数据约定.md`、`01_硬件连接与通信.md`、`02_算法处理与测评.md`、`03_开发流程和规划.md` | 同步功能删除、协议兼容和测评缺口 |
| `output/FPGA分区优化交接/03_帧池与帧身份优化方案.md`、`04_DDR与DMA优化方案.md`、`07_网络与控制接口优化方案.md` | 移除快照职责，维护主链所有权、客户端与调度规则 |
| `fpga/config/integration/PC_RGB_CONTROL.md`、各受影响 RTL README、`fpga/README.md` | 反映真实接口和当前实现状态，移除过时能力说明 |
| `host/docs/千兆网视频协议与上位机实现.md`、`Web界面与核心接入说明.md`、`host/README.md` | 不再承诺快照接入，保留 RAW 和 HDMI 正常工作说明 |
| `output/赛题对照与功能裁剪建议_20261020.md`、其他活动规划与目录索引 | 同步已确认裁剪范围，不留下“待决定是否删除”的矛盾 |

历史实验报告不重写；在新的删除实施报告中说明版本边界。所有新增或受影响代码块同步维护用途与设计意图注释，尤其是银行数、消费者数、客户端号、状态冻结与地址边界。

## 8 实施顺序与验收

1. **记录基线。** 保存受影响源码、工作区差异、构建配置和哈希；确认当前其他任务的构建使用冻结源，避免改写在跑任务的输入。
2. **冻结删除后的接口。** 明确撤销命令／类型、能力位、银行／消费者／客户端映射、状态页兼容方式及 60 MiB 布局。
3. **删除完整 RTL 链路。** 同步修改共享结构和所有调用者，重新生成 `frame_manager_layout.vh`，清理活动工程引用。
4. **删除 host 功能并迁移测试。** 保留 RAW 主流程和 0x90/0x92/0x94/0x95，加入撤销接口负向验证及仿真像素观察。
5. **运行针对性回归和完整帧验证。** 检查下表各项，不以旧快照关闭夹具结果代替新源码测试。
6. **重新构建并比较。** 在相同器件、约束、时钟和可比流程下报告资源及实现结果；功能删除前的时序和位流不能认证新源码。
7. **交付差异与证据。** 更新活动文档，列出删除文件、共享代码改动、测试结果、资源变化及未完成硬件项目。

| 验收项 | 通过条件 |
| --- | --- |
| 删除完整性 | 活动设计无三个专用模块、无快照帧槽、无客户端 6、无视频快照开关／占位生成分支；历史证据与状态／源码冻结除外 |
| UART 兼容 | 0x71/90/92/94/95 按既有契约成功；0x93/96/97 合法请求返回不支持，随后合法请求仍可正常执行 |
| 能力与状态 | bit8=0；0x90/95 page0 冻结一致，多页读回与版本、生效源帧信息正确 |
| RAW 网络 | PRAW RAW_LIVE 格式不变，完整字节覆盖、CRC、身份、乱序和丢包行为正确；无 type2/3 输出，旧类型拒绝不破坏新 RAW 流 |
| 帧池和 DMA | 三组主槽完整；非法旧快照 bank/owner 拒绝；六客户端全部能完成，特别验证客户端 5；票据、generation、cancel/drain 不回退 |
| 图像正确性 | 合成非平凡几何和增强模式下，S1/结果与独立参考一致；旧帧不受新参数重解释 |
| 显示与整机 | 完整 1920×1080 控制＋真实显示 RTL 模型通过，RAW／处理／显示计数独立；重复帧、失败、下溢如实报告 |
| 故障恢复 | 断链、取消、错误完成、背压、复位后不泄漏槽，不死锁，不把迟到数据归入新帧 |
| 资源和时序 | 新源码完成相应构建检查；报告实际 LUT/FF/APM/DRM、拥塞和时序范围，不预报固定收益 |
| 文档一致性 | 无活动文档承诺已删除的板端同源快照；严格同帧硬件测评不伪报通过 |

可沿用的验证入口为 `fpga/scripts/sim_full_integration.py`、`fpga/scripts/sim_video_verilator.py`、`host/scripts/test.py`，先检查改造后的参数和测试清单，再运行。完整帧控制与显示场景不再携带 `--snapshot-test`；网络故障场景按原脚本互斥规则单独运行。帧布局仍通过 `fpga/scripts/generate_frame_manager_layout.py` 生成。验证产物分别归 `fpga/build`、`fpga/reports`、`host/reports`，不写入 output。

涉及 PDS 工程、综合、仿真、约束和时序时，先查阅当前安装目录 `E:\PDS_Pangu\PDS_2022.2-SP6.4\doc` 下的对应官方资料，包括 `Pango_Design_Suite_User_Guide.pdf`、`ADS_Synthesis_User_Guide.pdf`、`Simulation_User_Guide.pdf`、`Timing_Analyzer_User_Guide.pdf`，并核对 reference 中目标板卡资料。官方目录只读，提取与构建产物放在 fpga 开发区。

本交接不要求下载位流、烧写板卡或变更物理连接；代码删除与软件验证可直接实施，实板部署按后续任务安排。不能把功能减少、16 MiB 预留撤销或局部仿真通过写成已达到真实 1080p30、资源下降或功耗下降。

## 9 交付完成标准

完成意味着生产链路中已经不存在视频同源快照功能，相关活动代码和入口已删除，主视频双路回传及运行参数控制通过新版本验证，接口与测评文档同步，并提交可追溯的实施报告。

只删除 0x93、只隐藏 UI、只设置 SUPPORT_SNAPSHOT=0、只移除测试，均不满足本次删除决定。历史报告和冻结证据中的快照实现允许继续存在；应明确属于旧版本，不再作为当前活动源码。
