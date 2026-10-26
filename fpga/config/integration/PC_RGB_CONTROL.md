# 集成视频工程 PC 控制扩展

## 2026-10-21 仿射迁移接口（实施中）

本节覆盖下文旧透视／post 语义。活动几何处理链已改为六系数仿射＋镜头；
0x94 仍为 80 字节，仅接受 `(a20,a21,a22)=(0,0,0x04000000)`，否则 NAK=11。
0x95 保留 17 词，内部源槽和处理跨域只存 14 个有效词。0x92 mode=2 返回 NAK=6。
本次新增 A0～A6 不复用旧快照编号。参考上传已接通；其余实体正在并行集成，不代表整份交接已完成。统一字节布局见 [ENTITY_CONTROL.md](ENTITY_CONTROL.md)，该文件覆盖下文早期仅参考实体的范围。

### AFG1 能力与开关

- A0 GET_CAPABILITIES：请求 `page:u8`，本版只接受 page=0。
- A4 READ_ENTITY：请求 `kind:u16LE, page:u8, reserved:u8=0`；参考kind9与控制kind10各4页，其他kind按统一实体记录长度分页。page0 冻结 96 字节，后续读取不得交错其他实体读回。
- A6 SET_AFFINE_ENABLE：12 字节 `enable:u8, reserved[3]=0, control_version:u32LE,
  expected_geometry_version:u32LE`。enable 仅为 0/1，版本为 1..0x7fffffff，预期版本
  必须匹配当前生效几何。几何／开关存在冲突待应用事务时返回 busy=4；非法值或过期版本为 11。
  最后一次已接受请求的相同序号和全部载荷重试幂等；同序号不同载荷拒绝。
  ACK 的 byte2=2 表示 validated/queued，byte4..7 回显 control_version。

读回复仍为 32 字节 payload：byte0 状态，byte1 命令，byte2 页，byte3=24，
byte4..27 数据，byte28..31 ASCII `AFG1`。旧 90/95 保持 `RGB1`。
A0 数据区：offset0 `AFG1`，4 schema:u16=1，6 profile_revision:u16=1，8 flags:u32
（bit0 仿射开关、bit1 透视支持=0、bit2参考上传），12 readable_entity_mask:u32（实际接通kind位），
16 max_entity_bytes:u16=256（当前实际暂存容量，低于协议1024上限），18 max_chunk:u8=64，
19 geometry_model:u8=1（affine_lens），20..23 保留零。

A4 的 96 字节记录（相对记录起点，小端）：

| 偏移 | 内容 |
| --- | --- |
| 0 / 2 | schema:u16=1 / kind:u16=10 |
| 4 | flags:u8：bit0 requested_enable、bit1 applied_enable、bit2 pending、bit3 display_known |
| 5..7 | 保留零；请求错误由 NAK 返回 |
| 8 / 12 / 16 / 20 | control_version / geometry_version / reference_version / requested_version，均 u32 |
| 24 / 32 | 已采集源 epoch / frame_id，均 u64 |
| 40..63 | 实际六系数 a00,a01,a02,a10,a11,a12，i32 Q26 |
| 64 / 72 | 板端显示 epoch / frame_id，均 u64 |
| 80 / 84 / 88 | 显示 control / geometry / reference version，均 u32 |
| 92 / 93..95 | 显示 enable:u8 / 保留零 |

开机 OFF、control_version=0；初始参考版本 1。参考六系数固定为
`[78744,0,-74604029,0,79245,-46141646]`（Q26），来源是既有无附加旋转输出视图。
这是工程基线，不是新完成的光学校准。OFF 保留输入镜头内参与畸变，不清除 ON 配置。
每次源采集锁存实际矩阵和控制版本；已有队列帧继续使用旧值。
display_known 仅在像素域实际采用的描述符匹配结果槽的 generation/epoch/frame 时成立；
它不证明 PC 采集卡图像来源，host 必须继续保留 HDMI 外部身份 unverified。

固定载荷向量：OFF `000000000100000007000000`，ON `010000000200000007000000`，
A4 page3 `0a000300`。外层固定字节及拒绝测试见 `host/tests/test_affine_control.py`。

适用于 `pango_video_system`，PDS 2022.2-SP6.4 / PG2L100H FBG676 -6。这是 FPGA 已实现的 PC 专用协议，外层 version=1；与 MCU_POSE_V2 的独立 version=2/profile=0x4D32 不混用。上位机纯编解码实现见 `host/src/pango_video/fpga_rgb_control.py`。该模块不开串口/网络，不自动采集或发送数据。

## 外层与启动

115200 8N1。`55 AA | version u8 | command u8 | sequence u16LE | payload_len u16LE | payload | CRC16 u16LE`；CRC16-CCITT 初值 FFFF、多项式 1021，覆盖 version 到 payload。PC 0x71 的 32 字节 epoch/MAC/IP/port 实体保持现有 `raw8_boot.py` 格式；MAC/IP 使用标准网络顺序，epoch/ports 小端。启动 ACK 的最后一个 stop bit 排空后才允许采集。用户必须显式配置本地 PC 单播目的 MAC/IP，复位前不能用第二次启动覆盖在途帧的 epoch/端点。

每个回复总长 42 字节，payload 固定 32；command=80 ACK 或 81 NAK，sequence 回显。payload byte0 状态（0 成功、4 忙、6 不支持、11 范围/版本/CRC错误），byte1 请求命令。版本递增且最大 0x7FFFFFFF，0 禁用。收到 queued ACK 不表示 applied；应用发生在下一次源帧采集边界。

## 运行命令

| 命令 | 请求 payload | 行为 |
| --- | --- | --- |
| 90 | page u8，0..3 | 冻结并读取 96 字节系统状态 |
| 92 | mode u8，reserved=0 u8，version u32LE | 0 disabled、1 pre_resample；2 已撤销并返回 NAK=6；ACK byte2=2 validated/queued、byte4..7=version |
| 93 | 已撤销，不复用 | 合法请求统一 NAK code=6 |
| 94 | 80 字节整份几何实体 | CRC32/范围/版本验证后排队；ACK byte2=2、byte4..7=version、byte8..11=entity_id |
| 95 | page u8，0..3 | 读取活动几何实体及实际 applied 的源 epoch/frame |
| 96 | 已撤销，不复用 | 合法请求统一 NAK code=6 |
| 97 | 已撤销，不复用 | 合法请求统一 NAK code=6 |

所有 readback：page0 冻结整份读回，后续页必须依次读取同一命令，不能交错其他读回。reply payload byte2=page，byte3=24，byte4..27=该页数据，byte28..31=`RGB1`。系统状态 capability bit8 恒为 0，旧视频快照能力已撤销；状态冻结读回仍保留。

## 几何实体和界限

94 payload：version u32LE、calibration/entity_id u32LE、17 个有符号 i32LE 定点词、CRC32 u32LE。CRC32 是 ISO-HDLC，覆盖前 76 字节，与 Python zlib.crc32 一致。词序 `a00,a01,a02,a10,a11,a12,k1,k2,p1,p2,fx,fy,cx,cy,a20,a21,a22`；除 fx/fy/cx/cy 为 Q16，其余为 Q26。所有项都保留，不丢弃 k2 或切向系数。

实现范围：a00/a01/a10/a11/a20/a21 ±0x00800000；a02/a12/a22 ±0x20000000；k1/k2 ±0x08000000；p1/p2 ±0x01000000；fx/fy 1..0x20000000；cx/cy ±0x20000000。第三行只能为 (0,0,0x04000000)。范围外坐标和无效源邻域按像素 mask 处理，不以截断/回绕制造合法坐标。范围通过并不代表物理镜头标定已完成。

95 的 96 字节记录：bytes0..67 为上述 17 词，68..71 entity_id，72..75 geometry_version，76..83 epoch，84..91 source_frame_id；byte92 pending，末 byte95=47。95 是活动实体。旧排队源槽保存自己的整份参数，几何处理不会读活动总线来重新解释旧源帧。

## RAW 输出与来源边界

活动网络图像只有 PRAW V1 type=1 RAW_LIVE；type=2/3 已撤销且正式主机拒收。
RAW 的 64 字节头、RAW8/Bayer、epoch/frame_id、descriptor_id、CRC 和完整性规则不变。
网口与 ARP 在包边界仲裁；不存在 RGB 双图复制/导出服务、专用银行或第 6 号 DMA 客户端。

内部 SRC/DST/RAW 三组各三槽保留原地址，视频规划跨度为 60 MiB。
HISTORY 是新算法内部保留上一帧 S1 的独立引用，不支持 PC 触发和双图导出。
增强与 CCM 实体见 ENTITY_CONTROL.md，均在源帧边界应用并随源槽锁存。

HDMI 回采来源未独立验证时继续 `source_frame_id=null`、`pairing_status=unverified`。
当前不提供实板 S1/结果同帧直接导出的严格像素测评；仿真以内存记分板逐字节比较。
旧冻结报告继续保存，但不能作为新源码硬件验收结果。
