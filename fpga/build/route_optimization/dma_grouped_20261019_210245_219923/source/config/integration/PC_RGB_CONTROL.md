# 集成视频工程 PC 控制扩展

适用于 `pango_video_system`，PDS 2022.2-SP6.4 / PG2L100H FBG676 -6。这是 FPGA 已实现的 PC 专用协议，外层 version=1；与 MCU_POSE_V2 的独立 version=2/profile=0x4D32 不混用。上位机纯编解码实现见 `host/src/pango_video/fpga_rgb_control.py`。该模块不开串口/网络，不自动采集或发送数据。

## 外层与启动

115200 8N1。`55 AA | version u8 | command u8 | sequence u16LE | payload_len u16LE | payload | CRC16 u16LE`；CRC16-CCITT 初值 FFFF、多项式 1021，覆盖 version 到 payload。PC 0x71 的 32 字节 epoch/MAC/IP/port 实体保持现有 `raw8_boot.py` 格式；MAC/IP 使用标准网络顺序，epoch/ports 小端。启动 ACK 的最后一个 stop bit 排空后才允许采集。用户必须显式配置本地 PC 单播目的 MAC/IP，复位前不能用第二次启动覆盖在途帧的 epoch/端点。

每个回复总长 42 字节，payload 固定 32；command=80 ACK 或 81 NAK，sequence 回显。payload byte0 状态（0 成功、4 忙、6 不支持、11 范围/版本/CRC错误），byte1 请求命令。版本递增且最大 0x7FFFFFFF，0 禁用。收到 queued ACK 不表示 applied；应用发生在下一次源帧采集边界。

## 运行命令

| 命令 | 请求 payload | 行为 |
| --- | --- | --- |
| 90 | page u8，0..3 | 冻结并读取 96 字节系统状态 |
| 92 | mode u8，reserved=0 u8，version u32LE | 0 disabled、1 pre_resample、2 post_resample；ACK byte2=2 validated/queued、byte4..7=version |
| 93 | reserved=0 u8 | 选择下一次成功分配 S1 的源帧，复制同源 S1/结果到独立槽再导出；已有请求/导出时 NAK busy |
| 94 | 80 字节整份几何实体 | CRC32/范围/版本验证后排队；ACK byte2=2、byte4..7=version、byte8..11=entity_id |
| 95 | page u8，0..3 | 读取活动几何实体及实际 applied 的源 epoch/frame |
| 96 | page u8，0..7 | 读取保留的两幅快照描述符（各 96 字节） |
| 97 | page u8，0..3 | 读取该快照源帧实际使用的旧几何实体；后续活动更新不能改写此记录 |

所有 readback：page0 冻结整份读回，后续页必须依次读取同一命令，不能交错其他读回。reply payload byte2=page，byte3=24，byte4..27=该页数据，byte28..31=`RGB1`。系统状态中的 capability bit8 表示快照已接通；不要把它解释为实板功能验收。

## 几何实体和界限

94 payload：version u32LE、calibration/entity_id u32LE、17 个有符号 i32LE 定点词、CRC32 u32LE。CRC32 是 ISO-HDLC，覆盖前 76 字节，与 Python zlib.crc32 一致。词序 `a00,a01,a02,a10,a11,a12,k1,k2,p1,p2,fx,fy,cx,cy,a20,a21,a22`；除 fx/fy/cx/cy 为 Q16，其余为 Q26。所有项都保留，不丢弃 k2 或切向系数。

实现范围：a00/a01/a10/a11/a20/a21 ±0x00800000；a02/a12/a22 ±0x20000000；k1/k2 ±0x08000000；p1/p2 ±0x01000000；fx/fy 1..0x20000000；cx/cy ±0x20000000。第三行不得全零。透视负深度、范围外坐标和无效源邻域按像素 mask 输出黑，不以截断/回绕制造合法坐标。范围通过并不代表物理镜头标定已完成。

95/97 的 96 字节记录：bytes0..67 为上述 17 词，68..71 entity_id，72..75 geometry_version，76..83 epoch，84..91 source_frame_id；byte92 pending（95）或 0（97），末 byte95=47。95 是活动实体；97 是快照实体。旧排队源槽保存自己的整份参数，几何处理不会读活动总线来重新解释旧源帧。

## 快照、增强与来源

96 的两条 96 字节记录分别对应 SNAP_S1、SNAP_RESULT：bytes0..76 为冻结的 616-bit frame_meta，77..80 为与 PRAW 匹配的 descriptor_id，其余保留 0。具体字段由 `frame_manager_pkg.sv`/生成布局定义，主机 `snapshot_descriptor()` 已独立核对。每条含源 epoch/frame_id、原始采集时间、ISP/几何/增强版本、calibration/parameter/pose实体、尺寸、格式、stride、错误和阶段。

快照 PRAW V1 保持既有设计格式：type=2/3、format=RGB888(2)、Bayer=0、bit_depth=8，1920×1080 紧凑 stride5760、6,220,800 byte/image、4,444 个包；最后 600 字节。两条独立 DDR 槽使用 stride6144，有效行 5760；导出不含 padding。源 S1/DST 引用只保持到校验后的复制排空，网络只持有独立快照槽。RAW 每八个包给辅助通道一次包级机会，辅助通道再有界仲裁 ARP；连续帧率/服务期限仍需实板验收。

92 的 pre/post 使用固定历史 RGB tone 曲线、版本1；S1 在该增强前产生，结果 stage=2（disabled/pre）或3（post）。当前没有宣称自动 Gamma、在线 LUT 上传或已标定 CCM。默认 CCM 为真实连接的单位阵，不冒充标定色彩校正。

本轮按用户范围暂忽略 MCU 外部接线；pose_status=1（无样本）、pose_entity=0，不用机械 yaw 当作图像 roll，不编造 q_wc、物理 XYZ、平台→相机外参。HDMI 帧源身份未做实板验证时保持 unverified；上述快照记录不能按软件到达顺序推广为 HDMI 同帧证明。
