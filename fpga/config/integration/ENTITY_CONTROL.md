# AFG1 统一实体布局

2026-10-21 schema 1。本文是 PC_RGB_CONTROL.md 的实体字节布局组成部分。
字段小端，所有保留字节为零；能力位只有实际 consumer 接通后才开放。
字段冻结不等于算法已完成、光学校准已验证或实板验收通过。

## 上传与读回

| 命令 | 载荷 |
| --- | --- |
| A1 BEGIN | kind:u16,schema:u16,txid:u32,version:u32,entity_id:u32,length:u16,reserved:u16,crc32:u32；24字节 |
| A2 CHUNK | txid:u32,offset:u16,count:u8,reserved:u8,data[count]；count=1..64，包长=8+count |
| A3 COMMIT | txid:u32,crc32:u32,policy:u8=0,reserved[3]；12字节，视频实体下一源采集边界应用；kind12链接策略在提交时应用 |
| A4 READ | kind:u16,page:u8,reserved:u8；page0冻结完整记录，随后依次读取 |
| A5 ACTION | action:u16,reserved:u16,txid:u32；8字节，1取消匹配未提交上传，2查询上传 |

单个活动上传，块必须连续；相同 BEGIN 和最近块完整相同重试幂等。
冲突、越界、缺块、CRC错误拒绝；2秒无请求回收暂存，不改变活动实体。
CRC32为ISO-HDLC，对完整body计算。COMMIT busy保留暂存；最近成功COMMIT的相同
txid/CRC重试不再次提交。暂存容量由编译期能力掩码决定：支持kind2时256字节，
仅保留kind8等当前整板功能时128字节；A0返回实际容量，低于协议1024上限。

ACK byte2=1 received（A3成功为2 queued），byte4 txid:u32（无活动为0），
byte8 accepted_frontier:u16，byte12 version:u32，byte16 entity_id:u32，其余零。
ACK不代表applied；后续READ提供实际源边界。

非kind9/10的A4记录采用32字节头：

| 偏移 | 字段 |
| --- | --- |
| 0 / 2 | schema:u16=1 / kind:u16 |
| 4 / 8 | applied_version:u32 / entity_id:u32 |
| 12 | body_length:u16 |
| 14 / 15 | flags:u8（bit0 active_valid，bit1 pending；仅kind7另有bit2 exposure_binding_unverified）/ error:u8 |
| 16 / 24 | applied_epoch:u64 / applied_source_frame:u64 |
| 32起 | 完整活动body；末页补零 |

页数为ceil((32+body_length)/24)，最大12页。读取正在排队的状态不意味着活动body已改变。
kind9/10沿用各自96字节布局；A4回复byte28..31均为`AFG1`，不冒充旧`RGB1`。

2026-10-23 新增 kind12 MCU_LINK_POLICY：上传64字节，读回192字节（标准头32、策略64、
诊断96，共8页）。epoch/frame为0，不表示源帧应用；默认禁用且不批准配置/时间映射。
字段、会话持久化与接线见 [MCU_LINK_POLICY.md](MCU_LINK_POLICY.md)。整板参数掩码0x1BCA，
A0叠加固有kind9/10后在线掩码为0x1FCA。C4能力仍撤销；MCU V2线协议不变。

2026-10-23严格资源候选使用手动图像配置：kind1仅OFF/MANUAL和内置曲线0/1/2，
kind2/kind5不支持，kind3仅手动白平衡，kind7仅mode0手动曝光/增益。自动模式与曲线3请求
明确拒绝；下表保留完整schema供独立模块测试和历史实现解释，不表示当前板级能力。
独立C6固定裁边/缩放组件关闭；MCU/手动姿态、六参数仿射和镜头矫正保留。
状态快照最多8页；kind12仍为8页，kind8仍可上传完整128字节标定。

板端显式设置 `SUPPORT_VIEWPORT=0`；独立模块默认值仍为1，用于保留原固定视窗
实现与模块回归，不能据此宣称整板支持kind5。板端A1 kind5返回6（UNSUPPORTED），
A4 kind5在能力门禁返回11；直接连接配置bank的内部读取则返回error=6、正文长度0、
版本/ID/源身份/active/pending均0。所有kind5模式都被拒绝，不会改变已排队的其他实体。
每源冻结的viewport为unity、viewport_version=0；kind11正文偏移68的版本亦为0。
实际作业直接转发对应源的C3姿态/手动六系数，仍按epoch/frame匹配并保持到消费；
MCU不可用、姿态无效或超时继续使用原有手动回退。关闭仿射时仍使用既有参考/手动
矩阵语义，不替换成单位六系数。448位几何记录的高256位镜头参数保持原作业值。
本段优先于文末2026-10-22关于固定视窗与M*V的历史描述。

## 实体body

| kind | 字节 | schema1字段及偏移 |
| --- | ---: | --- |
| 1 TONE_CONFIG | 32 | 0 mode:u8（0 OFF/1 MANUAL/2 AUTO），1 curve:u8（0 gamma.7/1 unity/2 gamma1.3/3 uploaded），2 allowed_mask:u8，3 hysteresis:u8，4 low:u8，5 high:u8，6 hold_frames:u16，8 LUT_version:u32，12..31 reserved |
| 2 TONE_LUT | 256 | 256个单调不减u8；四邻域RGB共享同一条曲线 |
| 3 ISP_COLOR | 64 | 0 black[4]:u8，4 gain[4]:u16 Q12，12 ccm_enable:u8，13 wb_mode:u8，14 reserved:u16，16 ccm[9]:i32符号扩展S18.14，52 calibration_id:u32，56 awb_min:u16，58 awb_max:u16，60 awb_step:u16，62 awb_hold_frames:u16 |
| 4 STABILIZATION | 32 | 0 enable:u8，1 smooth_shift:u8(1..8)，2 search_radius:u8(1..4)，3 reserved，4 min_texture:u16，6 min_confidence:u16，8 max_translation:i32 Q16，12 max_rotation:i32 Q26，16 max_scale_delta:i32 Q26，20 calibration_id:u32，24 match_error_limit:u32，28 reserved |
| 5 VIEWPORT | 32 | 0 mode:u8，1..3 reserved，4 fixed_zoom:u32 Q16，8 max_zoom:u32 Q16，12 step:u32 Q16，16 hysteresis:u32 Q16，20 min_area:u32 Q16，24 calibration_id:u32，28 reserved |
| 6 COMPLETION | 16 | 0 enable:u8，1 max_age:u8（源帧数），2 min_confidence:u16，4 max_luma_delta:u16，6 reserved:u16，8 registration_version:u32，12 reserved:u32；历史深度固定1 |
| 8 POSE_AFFINE_CALIBRATION | 128 | 0 enabled:u8，1..3 reserved，4 calibration_id:u32，8 ref_pitch:i32 mdeg，12 ref_yaw:i32 mdeg，16 pitch_min、20 pitch_max、24 yaw_min、28 yaw_max（i32 mdeg），32 max_model_error:u32 Q16，36 max_time_error_us:u32，40 model_source_id:u32，44 expected_mcu_config:u32，48 reference[6]:i32 Q26，72 J_pitch[6]:i32 Q26/rad，96 J_yaw[6]，120..127 reserved |
| 9 AFFINE_REFERENCE | 64 | 0 fx/fy/cx/cy:i32 Q16，16 a00/a01/a02/a10/a11/a12:i32 Q26，40 width:u16，42 height:u16，44 calibration_id:u32，48 lens_model:u16=1，50..63 reserved |

kind7 CAMERA_CONFIG采用后文冻结的固定、停流AE和连续group候选接口。kind10 AFFINE_CONTROL只读，
只能由A6与内部源帧／显示记录改变。mode字段由各kind定义；旧0x92 mode=2仍不支持。

## 参考视图校验和版本

kind9要求正焦距、a01=a10=0、尺寸匹配，六系数必须与输出内参一致。
FPGA使用64位乘积检查a00*fx≈2^42、a02*fx+cx*2^26≈0及y轴关系；
绝对残差不得超过对应焦距定点整数的一半，不接受任意ON矩阵伪作参考。
A4 kind9记录：0..63 body、64 version:u32、68 entity_id:u32、72 epoch:u64、
80 frame_id:u64、88 pending:u8、89..95保留零。

启动参考版本1的内参Q16为[55852465,55499357,62090440,38159366]，六系数为
[78744,0,-74604029,0,79245,-46141646]。这是工程种子，不是完成光学校准的证明。
参考更新与几何／仿射开关共享冲突仲裁，SRC与结果侧记录保留实际参考版本。
所有calibration/model_source ID都只是来源标识；非零不代表已经获得真实标定。


## kind7 CAMERA_CONFIG / kind11 MOTION_FRAME 补充

kind7/schema1/body48 提供固定曝光、受约束停流AE和官方group0连续AE候选；曝光帧绑定均未实测。
0 mode:u8（0固定、1停流AE、2连续group候选）；1 flicker:u8（0关闭、1实测150Hz档）；2 low:u8；3 high:u8；
4 exposure:u32（行/16）；8 gain:u16；10 gain_min:u16；12 gain_max:u16；14 gain_step:u16；
16 exposure_min:u32；20 exposure_max:u32；24 exposure_step:u32；28 hold_frames:u16；30 settle_frames:u16；
32 line_time_ns:u32；36 period150_code:u32；40 timing_calibration_id:u32；44 reserved:u32=0。
曝光硬限17856（固定VTS 1120减4行，乘16），禁止修改VTS。150Hz档须提供实测行时间和非零标定ID。
mode0/1停流、排空、SCCB回读、稳定等待后才恢复采集；mode2保持采集并在group回读后等待稳定。
header flags bit2=1 表示曝光帧绑定未实测；header source仅为稳定等待后的首次采集身份，不能据此推断真实曝光生效帧。

kind11只读，schema1/body128（7页共168B，末8B为0）。header版本/ID=1，源身份绑定实际几何job。
body0六个i32实际Q26系数；24 pose_status:u8；25 visual_status:u8；26 history_applied:u8；27保留；
28 missed_results:u32；32 history_epoch:u64；40 history_frame:u64；48 history_pixels:u32；
52 invalid_pixels:u32；56 current_pixels:u32；60 registration_version:u32；
64 stabilization_version:u32；68 viewport_version:u32；72 completion_version:u32；76 pose_version:u32；
80 geometry_version:u32；84 ISP_version:u32；88..127为后文runtime_action状态及保留字节。
此记录给出任务的运动矩阵与结果来源；板端HDMI采用及外部采集卡配对仍使用各自独立证据。


A4 exact retry：最近成功页的同seq/kind/page请求重放同一冻结数据，不推进next page；包括page0跨帧边界重试。
客户端单次应答等待0.5秒后原包重试一次，早于2秒上传暂存空闲回收。每次read有100ms上界。
A5 action3/4要求reserved=0、txid=0，分别重置视觉参考（并撤销不兼容历史）／清空历史。
成功ACK=queued，动作在下一源采集边界执行；在途DMA不清空，引用在排空后释放。
最近成功seq/action完全相同重试幂等，seq相同但action变化拒绝，待执行时新动作返回busy。
kind11 body88 pending:u8，89 last_action:u8，90..95保留；96 action_epoch:u64，104 action_frame:u64，112 action_seq:u16，114..127保留。
动作状态独立于最近完成作业的identity/count，不将其执行帧误作处理结果帧。

CAMERA_CONFIG mode2 使用独立白名单group事务，预先核对manual/no-night/extra-lines/固定VTS和group状态；写入曝光/增益后end/launch，再轮询回读。通用SCCB写仍要求quiesced。group不明或失败需要板复位，last-good保留；不伪造回滚。主视频不断流，稳定窗口内不推进Gamma/AWB。

## 2026-10-22 C4 撤销修订（优先于上述旧字段功能描述）

保留 schema/长度用于识别旧报文，C4 kind 4 从整板 A0 能力掩码移除；A1 kind4 和 A5 action3 均 NAK=6，不入队，不发布 active。kind5 mode2 与 kind6 enabled=1 在 COMMIT 返回不支持（6），不改变活动配置。kind5 mode0/1 固定视窗、kind8 姿态标定仍按源帧原子应用。kind6 的禁用配置仍可提交/读取，error=6 明确表示配准补全不可用；kind6 能力位仅保留禁用实体与 A5 action4 清空历史引用，不代表可启用补全。

MOTION_FRAME visual_status=8 表示 C4 已撤销，registration_version 固定0，置信度与位移为0且 history_registration_ok=false；零位移不得解释成成功配准。最终矩阵是 C3 手动/姿态 M 与固定视窗 V 的 M*V。溢出仍使用状态5并回退原 M。历史框架与独立插值/DDR/引用释放模块保留，但当前整板不允许未配准历史采样。host JSON features 明确发布 visual_stabilization=false、dynamic_viewport=false、history_completion=false；旧 JSON 动态/启用补全草稿在导入和发送时拒绝。
