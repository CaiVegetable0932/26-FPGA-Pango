# 07 网络实现与集成契约

本目录实现离线验证的 S0 紧凑 RAW8→PRAW V1→IPv4/UDP→MAC 业务路径及有界 ARP/MDIO。板级顶层、PHY 延时/速度管理和 CDC 尚待联合集成。验证结果及适用范围见 `../../reports/network_control_20261012.md`。

1. `raw_dma_reader` 对接 04 的字节地址、1..16 个 32 B beat 请求接口。每行独立使用 `dma_byte_unpack` 去首偏移/尾 padding，跨行连续输出真实有效字节。slot_begin/end 为独占源槽的半开字节区间且须 32 B 对齐；验证舍入访问不越槽，突发不越 4096 B 列边界。此层只允许一个在途请求，native adapter 的 r_data/r_valid 必须稳定到握手；dma_done 持有到 dma_done_ready。
2. 03 在帧发布后 acquire 源槽和 generation，才可 start/frame_valid。请求/tag/事务票据仍由 03/04 保持；07 不从“已发最后一个请求”推断写可见或槽可释放。取消将 dma_cancel 接 04，所有 native 在途事务排空且 done ACK 后置 dma_drained。release_valid 必须由 03 release_ready 接受。失败同样排空，不复用旧像素。
   `reader_failed/dma_error` 必须驱动帧取消，不能只置 dma_drained 而等待缺字节超时。07 在排空状态继续接受并丢弃已出现的客户端回应；04 可抑制后续客户端交付，但仍须完成 native 排空及 done 栅栏。
3. `raw_frame_tx` 固定单路 RAW8；descriptor/epoch/frame_id/param/Bayer/端点按帧冻结。DDR stride2048→线上 stride1920 的 compactor 在上游，只有 WIDTH×HEIGHT 有效字节可送入。短帧输入有有界缺服务超时，整帧明确失败。PC 重连不生成 epoch，不重标已有帧。
4. `praw_udp_tx` 默认双包银行（各 2048 B、最多 1464 B 应用数据）；64 B 头 CRC 字段必须为零，载荷 1..1400 B。先算全头+载荷应用 CRC32，再发布可发送完整包；同时对 UDP 伪头、标准 UDP 头和实际应用数据算非零校验和，CRC patch 计入 UDP 校验。IPv4 无分片、TTL64、标准网络字节序；PRAW 字段仍为既有小端。`PACKET_BANKS=1` 仅用于同口径串行基线对照。
5. `ethernet_mac_tx` 接收**已完整缓存**的帧体，一旦开始不可欠载：前导码/SFD、至少60 B帧体、独立 FCS、至少12 B IFG。欠载/链路丢失明确 TX_ER。`ethernet_mac_rx` 保存整帧后核验 FCS residue/长度，再回放帧体；回放期间新帧整包丢弃并计数，物理 RX 不能背压。
6. `arp_peer` 单个显式 peer，不学任意 IP/无请求的 MAC；只在 FCS 已核验后接受对应查询的合法回应。一次轮询最多3次请求，失败要新 resolve 脉冲；低速回应槽有界。`ethernet_packet_mux` 最多8个 RAW 包后服务一个待发控制包，整包不抢占。
7. `raw_network_service` 联合 MAC RX/ARP/RAW/仲裁/MAC TX，所有端口共用 clk。只有 `gigabit_link_up && peer_valid` 允许新帧；PHY 断链/ARP失效取消 RAW 并按 drain/release 契约释放。端点只允许在服务空闲时变更并重新建立 peer；现有帧身份保持。
8. `mdio_clause22` 提供64bit完整Clause22读写（含32bit前导、TA释放/零校验），默认125MHz÷50=2.5MHz。IO三态只在板级封装实现。调用者须按 RTL8211F 和实物板的地址/strap/页寄存器/延时配置初始化和轮询，不能把交易完成当作千兆状态证明。

2026-10-21视频快照已经删除，type2/3和UART93/96/97拒绝。主流只有RAW8；没有快照重读/释放或独立RGB导出槽。不得按旧预算重新启用已删除业务。

`raw_network_service` 的同钟 GMII 不是可直接跨 RXC/DDR 域的 RGMII 电气接口。真实板级接入应使用 01 核验的双沿 IO/125MHz相位和异步 FIFO/描述符握手，DDR adapter/帧池按04/03实施；不能直接把两个异步域的 wide bus 接到这些端口。本次不解除过温后的上板/下载暂停条件。

32bit 运行统计按模计数；接收方应定期原子快照、保存时间并按模差计算增量，不能把长运行后的回绕当清零、或从统计计数推断帧身份。
