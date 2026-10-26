# 正式 RGB888 HDMI 显示模块

2026-10-12。实现入口为 `hdmi_display.v` → `hdmi_rgb888_tx.v`。本目录与既有 720p/RGB565 诊断链独立；共享顶层、正式 DDR 跨域桥、帧池事务适配尚待集成。验证范围与原始路径见 [显示优化报告](../../reports/hdmi_display_20261012.md)。

## 模块与数据格式

| 模块 | 职责 |
| --- | --- |
| `video_raster.v` | 2200×1125 总扫描，1920×1080 有效尺寸，正 HS/VS，像素域持续运行 |
| `rgb888_line_prefetch.v` | 两个完整行 RAM、256 bit 读 beat、列边界拆突发、RGB888 解包、完成/取消栅栏 |
| `hdmi_display.v` | 场边界获取结果槽、引用保持/释放、整帧重复、欠载黑色恢复、完整统计和像素 tag |
| `hdmi_rgb888_tx.v` | 原有三通道 TMDS 编码器与原生串行器；编码域三拍 tag 对齐 |
| `hdmi_display_pnr_probe.v` | 隔离 PnR 的本地流量夹具；不含真实 DDR，也不是可上板业务顶层 |

默认模式在 74.25 MHz 像素时钟下为 30 Hz，串行时钟 371.25 MHz。内存递增地址的字节顺序为 **R、G、B**，beat 的最低 8 bit 是最低地址字节；输出 `rgb[23:16]=R`、`[15:8]=G`、`[7:0]=B`。每行只读 5760 B，行地址加 6144 B；不请求 384 B 填充。

参数仅支持 `H_ACTIVE` 为 32 的正倍数、32 B 对齐且不小于有效行长度的 stride、行场总数小于 4096、`H_SYNC+H_BACK>=4`。默认参数是正式 1080p30；改变参数需重新验证服务期限。槽 base 必须 32 B 对齐，整帧跨度在已经验证的结果槽范围内。模块不接受任意格式/尺寸元数据，集成适配器负责校验 `width=1920,height=1080,format=2,stride=6144,errors=0` 及完整发布条件。

## 帧池接口与引用栅栏

全部业务端口在 `clk` 像素域；**不能直接接 DDR 时钟域的 `ddr_native_dma` 或 `frame_pool_bank`**。混合回归使用同钟 RTL 事务模型，证明握手兼容；实际 CDC/复位/吞吐尚须验证。

- `offer_valid/offer_ready` 在场边界握手。它原子取得一个已完整发布、按处理顺序选择的 DST 引用；base、slot、generation、epoch、frame_id 整帧不可变。offer 被背压时必须保持描述符稳定，不在场内抢先 acquire。没有新 offer 时保留旧引用并重读整帧；没有“仅选最新”跳帧模式。
- `release_valid/release_ready` 释放精确 slot/generation；场切换时须与新 acquire 原子完成。`release_ready` 低时继续保留旧槽，重复旧帧。关闭显示或失锁可在场外释放，但仅在完成/取消栅栏和本地 RAM 预取读排空后允许。
- 03 侧采用 `DST` bank、消费者 `DISPLAY=1`，base=`0x01800000 + slot*0x00800000`。适配器校验权威元数据，使用 `acquire[DISPLAY]`、`release_mask[DISPLAY]` 和对应 slot/generation 字段；保持所有源身份原值。不能给捕获设备序号填入 FPGA 源身份。
- 03 现有响应 `acquire_ok`/`release_ok` 是“命令有效时的立即结果”，不是无请求的 READY peek。不要把 `release_ready` 直接接 `release_ok` 再通过 `offer_ready`/`release_valid` 反向生成同一命令，形成组合环路。与现有无背压 bank 同钟适配时，只有 `fabric_ready` 且精确已持引用/无在途事务的适配状态可以保证 release 可接收；同时验证 `release_ok`。若跨域 ACK 会延迟，应由适配器先冻结原子操作并持有其确认，禁止乐观切槽。
- 每个 DMA 请求前经 03 `issue` 取得 consumer owner=`DISPLAY+1=2` 的 token/ticket，04 `done` ACK 完成后经 `complete` 退休；`cancelled/error` 同步退休结果。释放之前等待全部 token、CDC 队列、DMA 在途和本地 RAM 读排空。像素/串行 pipeline 可以携带旧 tag，但不能携带旧 DDR 引用或继续发出读。

目前平面 offer/release 接口是局部冻结契约，不代表已实现上述跨域事务适配器。正式工程集成负责人应将它与 03/04 联合落地。

## DMA 契约和显示期限

`req_addr` 是 **byte 地址**，32 B 对齐；`req_beats` 是 1..16 个 32 B beat；`req_tag` 为该引用的 generation。突发不跨 4096 B 物理列边界和有效行末。显示只读，`req_write=0`。一个显示请求在途，接入 04 的显示读 client；`r_valid/r_ready` 与 `r_last` 都在客户端侧，不给无 RREADY 的原生 DDR 总线添加伪背压。

最后一个 `r_last` 不等于完成。04 必须保持 `done/cancelled/error/done_tag` 至 `done_ready`；本模块在 done ACK 后才发布完整行、复用 DMA 描述符或释放引用。abort 不能撤回已经拉高且未接受的 `req_valid`；接受后 cancel，等待原生事务及客户端队列真实排空。短响应、错误 last/tag 和异常完成使当前帧失败。

两个行银行为每行提供独立完整性边界，活动行不可从尚未完成的 bank 读取。`ready_lines` 是两个银行的就绪 **bit mask**。`urgent` 表示运行期间少于两个就绪行，用于 04 紧急服务输入；没有请求时该水位不产生新事务。`low_water_cycles` 记录此水位持续时间；`max_no_service_cycles` 是像素域有行填充需求时未接收 beat 的最长计数，包含请求等待/完成握手，不能当作原生 DDR 时钟周期。

默认扫描下，行 n 最末像素消费与同 bank 的行 n+2 prepare 相隔 **2477** 像素周期。扣除请求产生两拍和必须早于 prepare 的一拍，首个行头 VALID 到完整行就绪的预算为 **2474** 周期，约 33.32 μs。行 0/1 利用前置场消隐预取。此证明要求 04+CDC 给出整个 5760 B 行的服务上界；仅限定平均带宽或单次最大无服务间隔不充分。混合回归仅覆盖一持续竞争读和其固定随机时延模型，不能替代七客户端、刷新、网络/快照及实板服务保证。

## 对齐、欠载与复位

行 prepare 比首活动像素早四拍，覆盖同步 RAM 读与字节预载。活动区每拍消费一个 24 bit 像素。读 RAM 发起时保留 6/7/8 B，响应追加时只剩 0/1/2 B；三种固定对齐替代宽变移位器，34 B reservoir 保留跨 beat 的完整 RGB triplet。违反残留不变量触发故障，不能静默错位。

RGB、HS、VS、DE、坐标、epoch/frame_id/generation 在 `hdmi_display` 共用一拍输出寄存；TMDS 编码器再有三拍。四拍流水不改变扫描总数，内部 symbol tag 与编码字对齐。串行器内部加载相位仍按原生模型和器件实现另验。

准备活动行时缺完整行或活动区缺像素，当前帧剩余像素黑色，DE/HS/VS 与 pixel clock 持续运行。旧预取/读响应排空后，只从下一个合法场边界重新开始；不会用旧 FIFO 字节接着填补丢失像素。`tag_valid=0` 表示该像素为黑色容错；前面已经输出的部分不能撤回，因此失败帧不用于精度测评。

`rst_n` 只用于与 DMA/帧池联合的 cold reset。模式变化、逻辑失锁用 `stream_enable/locked` 及 abort/drain，禁止只复位显示客户端丢弃在途 DDR 工作。实际像素时钟停止时，DDR 域桥必须独立保持/取消/排空旧引用，不能依赖停止的像素时钟释放。

`hdmi_rgb888_tx.serializer_reset` 必须来自经验证的原生分频/OSERDES 专用启动脉冲；`pixel_rst_n` 独立控制编码器。保持现有 `GTP_IOCLKBUF`、`GTP_IOCLKDIV_E2 /5`、主从 `GTP_OSERDES_E2` 和 `GTP_OUTBUFDS`；不用普通逻辑串行化。/5 为两拍高、三拍低，隔离 FDC 用 source edges `{1 5 11}` 描述 40% 占空比。编码器启动先保持至少三拍 DE=0，正式 raster 的前置场消隐提供此条件。

## 统计与来源

`display_scan_frames = display_new_frames + display_repeat_frames + display_failed_frames + display_empty_frames`；在末活动像素之后计完整扫描。new/repeat 只计全部原始像素成功显示的帧；错误/黑色帧计 failed，无引用的空扫描计 empty。`underflow_pixels` 计持有引用期间的黑色容错采样，包含欠载/DMA 故障/停用；引用释放后无源黑色扫描不再归入此计数。所有计数为 32 bit、cold reset 清零，运行至回绕前需快照。处理完成帧数由 03/06 提供，采集卡帧数由 host 独立提供。

内部 tag 用于 RTL 与事务证据，未在有效图像内写任何 OSD/marker。普通 HDMI 回采仍 `source_frame_id=null,pairing_status=unverified`；不以 UART 当前帧号或软件到达顺序配对。正式几何精度使用板端同帧 S1/结果快照。

## 回归与隔离构建

```powershell
./fpga/scripts/sim_hdmi_display.ps1
./fpga/scripts/build_hdmi_display.ps1
./fpga/scripts/sim_hdmi_tmds.ps1
```

前两者在 `fpga/build/hdmi_display/` 生成冻结输入及日志；PnR 夹具仅供时序/资源比较，不生成新的下载位流。最后一项需有效 ModelSim Verilog 许可证，编译安装版原生模型后运行串行器 1024 字与 RGB 通道/tag 测试；当前运行受许可证阻止，不能用 encoder-only 占位验证冒充原生 bit 顺序验证。其官方资料副本及来源记录仅写本开发区。
