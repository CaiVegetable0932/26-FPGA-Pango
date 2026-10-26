# 同源快照删除与 HISTORY 所有权实施记录

日期：2026-10-21。范围：活动源码、线上协议、主机重组/保存和回归入口。未运行 PDS，未下载位流；历史冻结源码、报告、数据均保留。

## 实现边界

- 删除 `video_snapshot_service.sv`、`frame_snapshot_pair.sv`、`snapshot_copy_dma.sv` 和专用快照夹具、准备/映射/验证脚本，活动源列表不再引用它们。
- `pc_video_boot` 不含 0x93/96/97 专用端口或业务状态，合法封装请求走通用 NAK code=6。0x90/95 状态冻结、启动/参数控制与新 A0–A6 实体协议保留；capability bit8 清零。
- 帧池只有 SRC/DST/RAW 三银行，各三槽，原地址不变：0x00000000/0x01800000/0x03000000，规划结束 0x03C00000（60 MiB）。旧 bank3/4 在 fabric 中拒绝。
- 六个客户端保持 0 RAW写、1 S1写、2几何源/历史读、3结果写、4HDMI读、5RAW网络读。DMA/fabric 中末客户端特殊准入完全删除，客户端5与其他客户采用同一合法性和排空规则。
- 快照专用 `snap_exact/snap_slot/snap_gen` 删除并重新生成 frame_manager_layout.vh。4个消费者保留为 PROCESS/DISPLAY/NETWORK/HISTORY；HISTORY 是本轮新算法独立内部引用，复用 SRC 和客户端2，不是旧快照消费者别名，不恢复复制/导出。
- 网络只有 RAW_LIVE/type1 生产格式，去掉 RGB/可变类型 formatter、第二帧发送器及快照/ARP内层仲裁，RAW与ARP包级仲裁保留。
- 主机删除 SnapshotSpec/admit/close、双RGB缓冲和 save_snapshot_pair、快照控制编解码、在线 type2/3 接收。旧类型在申请帧内存前明确拒收；RAW重复/乱序/超时/epoch/CRC与通用 descriptor_id 保留。普通HDMI/标定图导入没有删除。
- 核心夹具通过仿真内存观察 S1/DST；GMII捕获 RAW 向量，独立核对Ethernet FCS、type1和全部有效字节，不再为测试恢复可综合快照链。

## 已执行验证

| 证据 | 实际结果 |
| --- | --- |
| `build/full_integration_20261013/sim_20261021_174147_909816/result.json` | Icarus UART35请求和fabric均PASS：93/96/97拒绝后合法读回恢复；六客户端完整写回、旧bank3/4、owner5及未领取HISTORY owner4拒绝，generation/readback/cancel保护保留 |
| `../host/reports/fpga_rgb_vectors_20261021_172424_795753.json` | 冻结主机编解码核对35个UART回复PASS |
| `../host/reports/fpga_rgb_vectors_20261021_173544_477791.json` | 删除后真实RTL GMII RAW 35×33、1155字节完整解码PASS；来源为合成仿真 |
| `../host/reports/snapshot_removal_offline_20261021.log` | 协议/重组24 tests，OK，1个可选native批量接收测试跳过；包含type2/3拒收不分配内存且后续RAW成功 |
| `build/full_integration_20261013/history_scheduler_20261021_173410/result.json` | Verilator真实帧池＋scheduler 4帧PASS：连续历史、运行中clear不提前release、恢复、失败排空后SRC无引用泄漏 |

删除后普通core Verilator已通过编译和首帧S1/DST及RAW路径，但旧增强期望因新tone实现变化失配；由图像增强代理继续排查最终集成。Icarus在部分struct/full-core甚至DMA单例编译发生3221225477异常；这些运行保留日志且不记PASS。新入口对可稳定运行的控制/fabric使用最小依赖闭包。

## HISTORY 生命周期

调度器在SRC分配时记录独立 HISTORY pending。几何作业开始前，只有相邻epoch/frame与尺寸、ISP/增强/标定版本一致的旧S1可用。实际像素 eligibility 还由图像配准、亮度/相机配置和算法开关检查。

旧历史引用保持整个作业，开关/失效不得提前回收在途DMA。结果写入和源读全部排空后，先释放旧历史，再FIFO获取并核对当前源slot/generation/epoch/frame，最后释放PROCESS引用。失败/禁用显式skip；空闲池压力优先丢历史并计数。状态计数不是实板连续帧率证明。

新增 `tb_video_history_core.sv` 与 `sim_video_verilator.py --history-test` 检查真实64×36 S1纹理、多帧、配准、历史DMA、色彩版本/坏帧失效和关闭后清理。实际 `build/full_integration_20261013/verilator_20261021_175932_218948/result.json` 已通过 configure/build/run，source snapshot 完整。6个成功源帧＋1个坏捕获中，frame3估计 +4像素、confidence=1688，产生70个历史像素和36次真实HISTORY DMA。独立内存oracle比对右边历史像素与当前有效像素优先，逐字节一致；色彩版本变化与坏帧间隔禁止补全，关闭后SRC所有引用释放。此为64×36合成整机模型证据，不是1080p性能或硬件验收。

## 限制

本记录没有新SYN/MAP/布线资源和时序结果，也没有新硬件功耗、真实1080p30或HDMI来源证明。16 MiB专用预留撤销只是地址规划变化。严格实板S1/结果同帧导出已不在当前能力中；HDMI回采来源仍为null/unverified，不能用旧快照PASS替代。
