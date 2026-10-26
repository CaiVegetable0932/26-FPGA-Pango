# 06 ISP 与几何矫正实施及优化验证

日期：2026-10-12。对应 `output/FPGA分区优化交接/06_ISP与几何矫正优化方案.md`。本次完成独立算法 RTL、参考模型、局部回归和注册边界封装的目标器件 PnR；尚未接入板级视频顶层或执行硬件验证。

## 1. 实现落点与本次能力

原实现只有候选 IP 与 RGB565 摄像头诊断链，没有可比较的正式 ISP/几何吞吐基线。本次新增：

- `fpga/rtl/isp/`：RAW8 减黑、分 R/Gr/Gb/B 增益、12 bit 中间数据、两行同步 RAM、四种 Bayer 双线性去马赛克、reflect-101 边界和完整行帧排空；独立可选 CCM 与按帧/ROI 锁存统计。
- `fpga/rtl/geometry/`：精确图块起点与行列递推、23 级镜头逆映射、三拍完整 32×32 部分积、32×8/16×16/8×32 可配置四 bank 缓存、四像素并行回填、四级弹性查找/读出、最终一次舍入的 RGB888 插值、12 端口双页 LUT、disabled/pre/post 三模式。
- `geometry_rgb_pipeline`：图块调度、完整参数与身份按帧锁定、完整结果计数、整帧失败；保持完整帧元信息，逐像素仅流水 u/v token，帧退出前不能覆盖源身份。
- `perspective_divide`：独立倒数/齐次除法前端，256 项种子、两次 Newton、指数恢复与深度/范围拒绝；尚未接入正式矩阵解析和完整处理核。
- `fpga/model/isp_geometry.py`：浮点与位精确模型、边界/增强顺序、透明的 arithmetic overflow、缓存事务模型。
- `fpga/sim/`、`fpga/scripts/`：golden、原始合成 `.raw/.rgb`、随机等待/背压、异常回归、全域精度、完整 1080p 服务模型及独立 PDS 入口。

两个现有顶层、共享 IP catalog、全局约束、现有诊断业务、外部 UART/UDP/MCU 协议均未修改。原工作区改动保留。基本 ISP 曲线仍是可复现的线性 identity；没有色卡标定或光学校准成功的声明。

## 2. 可复核结果

机器记录为 `fpga/reports/isp_geometry_20261012.json`，包含逐项角点、资源、源码 SHA-256 和原始日志路径。最终 PDS 快照与当前全部算法 RTL 哈希一致。

| 验证 | 实际结果 | 范围 |
|---|---|---|
| Python 合同测试 | 14 项通过 | 四相 Bayer、2×2 边界、增益/黑电平、CCM、单次舍入、负坐标、identity、无漂移、溢出、倒数、缓存保护 |
| 全域数值扫描 | 5×2,073,600 输出位置，五种旋转均通过 | 真实标定候选 K/D 的离线量化误差 |
| 最终完整 RTL 回归 | 14 个顶层全部通过 | 算术、CCM、ISP、坐标、透视除法、缓存、LUT、统计、全帧 |
| 补充溢出回归 | `OVERFLOW_PASS`，同一 RTL | 合法中心、Horner/radial 溢出、输入无效与 tag |
| RAW ISP 1080p 合成帧 | 2,073,600 像素逐个检查通过；2,084,167 周期 | 四边扩展/排空，条件折算 13.894447 ms@150 MHz |
| 完整几何 1080p 合成帧 | 2,073,600 像素、mask、坐标、身份通过；4,136,650 周期 | 条件折算 27.577667 ms@150 MHz |
| II | 坐标连续段 II=1；缓存热命中 169 次连续 II=1 检查通过 | 平均停顿另计，不代表 DDR 无等待 |
| 目标器件 PDS | 内部 slow/fast setup/hold 全通过，TNS=0 | PG2L100H FBG676 -6，150 MHz 注册边界封装 |
| 实板/整机 | 未执行 | 不宣称真实输入、HDMI、网络、功耗或光学精度通过 |

最终完整 RTL 日志：`fpga/build/isp_geometry/final_delivered/`。新增的溢出顶层单独保存在 `fpga/build/isp_geometry/overflow_signoff/`，不把该用例冒充旧日志里已有。ModelSim 编译成功，但缺运行许可证；实际运行工具为工作区已有 Icarus 12.0，失败/替代过程的原始日志保留。

## 3. 精度口径

使用 `host/reports/rgb33-calibration-20261010/pinhole_k1_k2_p1_p2.json` 的 K/D，原件只读，副本与定点候选保存在 `fpga/config/isp_geometry/`。原始 SHA-256：`03cfa2872a1b0f331eceeafea6eaac052732d12f57f0b57277ea8f073a69af54`。

该档为 `candidate_unverified`、`source_stage=unverified`、`hardware_applied=false`，原标定重投影 RMS=1.61549 px。因此下表只证明位宽/量化与该浮点模型一致，不证明镜头精度、板端 S1 来源或标定已经验收。

| 旋转 | 有效浮点输出位置 | 坐标 RMS/px | max/px | 算术溢出 | mask 差异位置 |
|---|---:|---:|---:|---:|---:|
| 0° | 2,073,600 | 0.003749 | 0.007153 | 0 | 0 |
| +15° | 2,055,035 | 0.006789 | 0.012053 | 0 | 4 |
| −15° | 2,054,590 | 0.005024 | 0.010359 | 0 | 3 |
| +45° | 1,734,213 | 0.005665 | 0.009995 | 0 | 3 |
| +90° | 1,391,538 | 0.004075 | 0.007344 | 0 | 5 |

RMS 使用二维欧氏坐标误差、有效浮点域全覆盖；max≤0.25 px、RMS≤0.05 px 均通过。边缘少量 mask 不同来自量化过闭区间边界，单独保留，没有隐去。逐阶段整数范围保存在 `model_audit.json`。定点格式、signed rounding、clip 和 tag 语义见 `fpga/rtl/geometry/README.md`。

## 4. 吞吐与缓存比较

### 4.1 回填端口

同一 1,200 请求坐标轨迹、相同 RGB888 源样本、同一随机等待分布，16×16 源块：

| 回填 | 周期 | miss | 字节 | 队列峰值 | 最长阻塞 | 重复邻域 |
|---|---:|---:|---:|---:|---:|---:|
| 单像素 raster | 13,754 | 38 | 26,208 | 8 | 1,277 | 231 |
| 四 bank 2×2 quad | 4,620 | 38 | 26,208 | 8 | 333 | 231 |

该轨迹周期下降 66.4%，四像素回填次数从每块 256 拍变为 64 拍，完整样本和最终数值一致。随机等待的时刻会随握手相位变化；不把这个比例外推为所有角度或真实 DDR 的固定提升。

### 4.2 完整帧条件服务

1080p identity 合成源用不对称 RGB 函数逐个核对，处理核真实执行仿射、镜头公式、cache、插值和结果握手；关闭增强。每十个 proc 时钟仅四个允许返回 quad，其间再注入随机等待，结果也随机背压。

| 配置 | 周期 | 条件 ms@150 MHz | miss | 回填字节 | g |
|---|---:|---:|---:|---:|---:|
| 早期 16×16 源/输出块 | 5,727,573 | 38.183820 | 16,176 | 16,564,224 | 2.662716 |
| 最终 32×8 源/输出块 | 4,136,650 | 27.577667 | 8,168 | 6,273,024 | 1.008395 |

早期配置未满足 33.333 ms，保留失败日志 `native_20261012/tb_geometry_rgb_pipeline_1080p.log`。最终在明确的合成服务模型下满足内部 30 ms 留量目标。g 分母为完整输出 `3×2,073,600`，回填统计包含重复与 fixture 声明的实际对齐/padding 字节。

上述模型没有调用真实 DDR 控制器，也没有同时运行实际 RAW/S1/DST/HDMI/网络 DMA；四时隙不能等同真实仲裁保证。硬件 30 fps、无服务最长间隔、源 PCLK 峰值及混合负载需要 04/整机验证。不能将该数字写为实板帧率或 60 fps 能力。

### 4.3 标定访问分布

`cache_round_robin_audit.json` 使用与 RTL 相同 round-robin/pinned 替换、32 组×4 路、128 槽、S1 stride=6144，固定同一 16×16 输出遍历比较源块形状，逐坐标检查，不用四角包围盒猜测。

| 角度 | 16×16 g | 32×8 g | 8×32 g |
|---|---:|---:|---:|
| 0° | 1.63144 | 0.89543 | 4.32527 |
| +15° | 1.86420 | 1.23704 | 4.28716 |
| +45° | 1.84230 | 1.56395 | 3.14086 |

精确数值、miss 和字节以 JSON 为准。g<1 合法，因为去畸变访问的源域可以小于整份 S1；不据此省去整份 S1 写流量。缓存 96 KiB RGB888 与旧 128 KiB RGBX 候选均为 128×256 像素，padding 不增加槽数或命中率。本次只选择有服务/端口证据的 32×8 候选，其他形状可复现保留。

## 5. PDS 时序和资源

依据只读安装资料 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/` 中 ADS Synthesis、Simulation、IP Compiler、Timing Analyzer 和 PDS User Guide，以及 MINI 硬件指导手册；工具为 2022.2-SP6.4 build146967，目标 PG2L100H/FBG676/-6。官方提取文本只写 `fpga/build/isp_geometry/reference/`，没有修改参考原件。

比较保持 `create_clock proc_clk 6.666667 ns`，未加入 false path/multicycle 或放宽周期。结果取最终 `report_timing/*.rtr`，包含 slow/fast、setup/hold、报告例外；不拿筛选路径或工具退出零代替通过。

| 核/候选 | slow setup WNS/ns | fast hold min/ns | APM | 物理 DRM | LUT | FF |
|---|---:|---:|---:|---:|---:|---:|
| 坐标原 12 级宽乘法 | −2.835 | 0.120 | 42 | 0 | 945 | 1,598 |
| 坐标 23 级部分积 | +1.653 | 0.103 | 52 | 0 | 1,663 | 2,965 |
| ISP 原组合增益/行表 | −1.036 | 0.102 | 1 | 0 | 1,346 | 716 |
| ISP 分级/独立同步 RAM | +0.736 | 0.101 | 1 | 2 | 537 | 875 |
| RGB 双线性 | +1.720 | 0.149 | 18 | 0 | 62 | 277 |
| 完整核早期缓存组合查询 | −8.621 | 0.095 | 79 | 30 | 6,266 | 6,672 |
| 最终完整核、seed 7 | **+0.382** | **0.088** | **79** | **30** | **5,938** | **7,359** |

各独立核统计包含自己的注册边界/串行配置封装，不等同板级业务实例资源。完整核保留默认 160 bit 身份，全部算术和数据 RAM 端口，实际覆盖 28,041 个内部端点；slow hold +0.129 ns、fast setup +2.593 ns，四项总负余量和失败端点数均为 0。Cache 为 24 DRM36K，Gamma 为 12 DRM18K；布局物理归并后共 30 DRM。ISP 的两行 RAM 映射为 `READ_BEFORE_WRITE/SINGLE_PORT`，已从生成网表核对。

最终配置是 fanout_guide=64、placement seed=7、CE/RS 控制链≤4。seed=1 在同一 RTL/约束下仍有 −0.195 ns setup，保留结果，说明布局敏感性与余量有限；不声称任意 seed 或板级集成都收敛。稀疏 tag RAM 自动映射 DRM 的候选无法完成布线，改为有注册读的本地 LUT RAM。PnR 所有失败/超时日志均保留。

最终证据：`fpga/build/isp_geometry/pds_geometry_seed7/`，尤其 `result.json`、`source_manifest.json`、`report_timing/geometry_timing_top.rtr`、`place_route/run.log` 和 `synthesize/apm_drm_lutram_utilization.log`。输出端口是内部测试封装，I/O 延迟尚未定义，外部/CDC/板级签核未执行。部分早期 PDS 默认全流程生成了诊断位流，未下载且未发布；最终入口明确停止在 report_timing。

## 6. 复现与接入条件

在仓库根运行：

```powershell
& fpga/scripts/sim_isp_geometry.ps1 -FullFrame
& fpga/scripts/build_isp_geometry.ps1 -Top geometry_rgb_pipeline -PlacementSeed 7 -MaxControlChain 4
python -B fpga/scripts/audit_geometry_cache.py
```

脚本每次创建独立 FPGA 构建目录，PDS 使用源快照；全部原始日志/数据留存，不写入 output/ 或官方文档目录。

集成负责人需依据 `fpga/rtl/geometry/README.md` 合并如下边界：02 的 RAW 帧身份/错误/峰值 FIFO；03 的 S1 acquire、参数实体、结果 seal/release 和快照；04 的 32×8 对齐行段→2×2 quad 回填、actual bus_bytes、错误排空、图块结果行写与可见性栅栏；07 的真实参数 CRC/范围校验、按帧提交、LUT 实体/版本/读回；05 的完整结果消费、显示来源与时序。不能直接替换现有 RGB565 诊断位流运行。

未完成项：正式透视矩阵前端集成/全域精度，真实色彩/基础曲线、自动 Gamma 迟滞选择，多 outstanding/双缓冲预取，真实混合 DMA 期限/CDC/存储后仿，板级 IO 时序，实板输入/几何/显示/网络完整帧率、同源 S1/结果裸快照、光学质量与功耗。强缩小抗混叠未实现，不扩大支持范围。现阶段 HDMI 来源继续按已有约定保持 null/unverified。
