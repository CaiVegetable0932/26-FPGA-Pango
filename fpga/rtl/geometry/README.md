# 06 算法实现与集成契约

本目录是独立算法实现，尚未接入两套板级顶层。正式像素保持 RGB888。`geometry_rgb_pipeline` 接收已取得所有权、内容不变的 S1 源槽；RAW 分流、S1/DST DMA、源身份、控制载荷解析和 HDMI 仍由相邻分区接入。离线参考模型不属于 PC 实时视频路径。

## 数据与参数

- `frame_tag` 是不解释的固定宽度描述符。默认 160 bit 可携带 epoch64/frame_id64/geometry_version32；集成时可改为 `frame_manager_pkg::META_BITS`，保留采集时间、实体句柄等全部信息。
- 完整核一次只处理一个源帧，完整 `frame_tag` 在帧开始锁存到输出排空，逐像素只流水携带 u/v 32 bit token。帧中改动外部身份不影响在途帧，不能在最后像素退休前启动下一帧。独立模块仍支持通用 tag 逐拍传播。
- 内部参数总线 `frame_coefficients[447:0]` 的最低 32 bit 为字段 0。依次为 `a00,a01,a02,a10,a11,a12,k1,k2,p1,p2,fx,fy,cx,cy`。前十个字段为 S(32,26)，后四个为 S(32,16)。这是模块内部寄存器契约，不分配 UART/UDP 命令或外部载荷编号。
- 输出像素中心为整数 `(u,v)`，屏幕 u 向右、v 向下。逆映射输出源坐标 S(28,12)。所有舍入使用 `floor((n+2^(s-1))/2^s)`，负数同样向正无穷处理半整数；不得替换为向零截断。
- 仿射累加保持完整 S(40,26) 范围并在图块起点精确重算。x/y 为 S(24,20)，平方、r2、切向项和畸变射线为 S(32,20)，Horner/radial 为 S(32,26)。完整 64 bit 乘积后才舍入，缩窄前检查溢出；溢出通过 `frame_failed` 作废整帧。
- `lens_inverse_map` 为 23 级、连续段 II=1；宽乘法使用三拍部分积。`affine_ray_stepper` 在每个区域开始后另计 5 拍起点准备，区域内逐拍递推。`perspective_divide` 是独立的 13 级 S(40,26) 齐次坐标前端，支持正深度、256 项倒数种子和两次 Newton 迭代；尚未接入正式透视矩阵解析/处理核。

## 输入 ISP

`../isp/raw8_isp.sv` 在 proc 域接收弹性 RAW8 流，不能直接暂停 DVP。02 提供异步 FIFO、RAW 格式及整帧错误；接收端须先分配同一身份，然后同时分流 RAW DMA/ISP，禁止额外读整帧 RAW 而不记 DDR 流量。

- Bayer 编码：0=RGGB、1=GRBG、2=GBRG、3=BGGR；颜色顺序 R/Gr/Gb/B。
- 黑电平四个 u8 按最低字段开始排列，增益四个 U(16,12)。RAW 减黑钳位后乘增益，舍入至 12 bit；默认单位增益是诊断设置，未证明色彩校准。
- 两行独立同步 RAM 为 `READ_BEFORE_WRITE`；边界 reflect-101，最末行内部生成，最末列显式 flush。尺寸至少 2×2、宽不超过 MAX_WIDTH，输出尺寸不裁小。
- 输入 `sof/eol` 必须符合本帧精确尺寸。`frame_abort` 用于截帧或上游溢出，停止接收并排空；`frame_error` 使整个源槽无效，包括此前的写入。
- `out_rgb` 是线性 identity 基础曲线的 RGB888；`out_linear_rgb` 同拍提供 `{R12,G12,B12}`。可将其接入 `rgb_colour_matrix`，使用 S(18,14) 白平衡/色彩矩阵后量化，不能在 8 bit 结果后冒充保留中间精度。当前板级已连接真实 12-bit `rgb_colour_matrix`，默认单位阵；色卡校准参数仍未验证，不能把默认设置称为校准。
- `rgb_frame_statistics` 对 S1 的 ROI 每 4×4 抽样，Y=(77R+150G+29B+128)>>8，最后像素计入锁存；结果必须消费后才接受下一帧。未实现自动 Gamma 的迟滞选择器。

## 缓存和 04 回填边界

默认完整核采用 32×8 源块、32 组×4 路、128 槽和四个奇偶 bank，数据有效容量 96 KiB；16×16、8×32 通过 TILE_X_BITS/TILE_Y_BITS 参数保留，二者之和必须等于 8。缓存独立 RAM 经 PDS 检查为 24 块 DRM36K；旧 128 KiB RGBX 候选不是相同端口的已验证业务 cache。

输出按相同尺寸的图块遍历。`out_u/out_v` 是精确目的地址，04 须通过图块双缓冲/行段恢复结果行写，不得将到达顺序当作整帧 raster。输出图块顺序不修改外部图像格式、frame_id 或 DDR stride。

1. 开始帧前由 03 acquire S1 槽；锁定 base/stride/尺寸/slot generation 和参数实体。跨端方案 S1 stride=6144 B，有效一行 5760 B，板级集成须核对所有权。
2. `fill_req_valid/ready` 握手携带源 tile 索引，默认源左上为 `(tile_x*32,tile_y*8)`，非输出块索引。一次只允许一个在途回填；FIFO 为 8 个等待请求，另有邻域、标签读出、数据地址和输出四个弹性寄存级。重复源块合并，round-robin 替换时保护当前四邻域。
3. 04 为每个有效源行生成合法 DDR 行段，使用已有 DMA 字节地址、32 B beat 和 4 KiB 原生边界规则。只读有效行列，边缘虚拟像素补零；不得越过源槽或用未初始化 padding 作为有效像素。
4. 默认每次返回一个 2×2 四奇偶样本，`fill_rgb[23:0]`=even/even，随后 odd/even、even/odd、odd/odd，每样本 `{R,G,B}`。默认 32×8 块为 16×4 个 quad，按 quad raster 返回 64 拍；`fill_last` 仅最后一拍为 1。FILL_PIXELS=1 保留 256 拍 raster 基线。
5. `fill_bus_bytes` 在实际 LAST 上给出本次实际传输字节，包含对齐、重复回填、padding 与发生错误前的已传输部分；不能固定填 768 或仅报有效 RGB 字节。
6. 读和回填互斥，RAM 同址冲突不依赖厂商未定义语义。标签仅在整块成功完成后生效。提前 LAST、错误、过长响应作废整帧；过长响应持续接收到真实 LAST。04 的超时/取消必须先排空原生事务，再提供 `fill_error=1,fill_last=1` 的完成，不伪造未排空完成。
7. `frame_done` 仅代表结果像素全部被下游消费。03 发布 DST、release S1 或切换 slot generation 前，还须等待 04 原生事务完成/可见性栅栏；失败帧不得提交半帧。

标签范围判断/邻域生成、标签读出、比较/地址选择、数据 RAM 读取分为四级，miss 替换独立，回填后重查持有请求的标签。小型多读口标签表强制采用本地 LUT RAM，data bank 保持 DRM。连续命中支持 II=1。合法四邻域的不同地址按奇偶必分不同 bank，边界重复地址广播；从源坐标检测异常冲突并作废整帧。当前回填不乱序，无多 outstanding/双回填缓冲预取，04 不得返回乱序数据。

## 增强实体

0=disabled，1=pre_resample，2=post_resample。pre 使用 12 个独立查表读端口，再插值；post 为插值后 3 次查表。cache 与 DDR 中 S1 始终保持基础 ISP 结果。中间水平插值 U(20,12)，最终一次舍入/钳位，闭区间末行末列通过邻域夹取保留。

`lut_write` 只在空闲写影子页；256 项全部写入后 `lut_commit/lut_version` 才可提交。帧的 LUT 版本必须匹配已提交页；帧中写入/切换拒绝。12 个双页同步 RAM 每 lane 一个读端口，通过帧模式选择 pre/post 地址。示例 gamma=0.7 LUT 为调试曲线，未宣称光学校准或信息恢复。

## 复现与证据

在仓库根运行 `fpga/scripts/sim_isp_geometry.ps1 -FullFrame`。ModelSim 分支可选择，但本机运行许可证不足；Icarus 用现有 `fpga/build/ov5640_pwm_20261012/tools/iverilog/app/bin`，可通过 IcarusHome 指定。测试会生成自己的 RAW/RGB 原始合成证据和 model_audit，不覆盖实测数据。

PDS 检查入口为 `fpga/scripts/build_isp_geometry.ps1 -Top <模块>`，使用 PG2L100H/FBG676/-6、150 MHz 和注册边界封装，源码快照/报告均在 fpga/build。完整核保留全部默认 160 bit 帧身份，观测端口只做校验归约；逐像素数据路径完整保留。已验证配置为 ADS fanout_guide=64、PnR seed=7、CE/RS 链长度≤4，均保留同一时序约束。当前脚本明确 `-run report_timing`；初期使用 PDS 默认全流程生成过诊断位流，未下载，不能用于板级运行。

结果见 `fpga/reports/isp_geometry_20261012.md`。独立核时序、合成帧服务与真实传感器/混合 DDR/HDMI/网络验收分别列出。

## 2026-10-13 总体连接与精确透视

`geometry_frame_processor` 通过真实所有权/DMA读取 S1，图块回填与有界写缓冲将 RGB 结果写入 DST，并等完整写 readback fence 才完成。`video_memory_core` 在三个 SRC 槽保留 PC 提交的系数，运行期更新不重解释旧排队源帧。固定历史 tone LUT 的 pre/post 模式已接入，自动 Gamma/运行期 LUT 上传未实现。

透视除法为26级、共同CE保持的II=1数据/标签路径，U(31,30) mantissa、256 midpoint seeds、两次Newton；指数恢复使用 U(48,34) reciprocal，完整88-bit signed40×unsigned48乘积舍入到S(24,20)。合法正深度≥2^-12，完整signed40范围4096样本与独立整数除法误差≤2 LSB；负深度/近零/溢出以mask作废。归一化与指数恢复均分开寄存；32×32精确分段乘法3级、40×48乘法4级。小算术逻辑诊断的正裕量不能替代总体真实板级min/max报告。
