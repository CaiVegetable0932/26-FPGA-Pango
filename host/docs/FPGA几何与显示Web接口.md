# FPGA 几何与显示 Web 接口

此实现属于板端控制：主机编码参数、发送 UART、回读版本并在网口预览上绘制 FPGA 返回的源像素位置。计算机软件参考仍使用 `fisheye-preview.js` 的标准 `markerPixels/sourcePoint/destinationPoint`，算法未改动。

## 工作台

主页面新增“FPGA 几何与显示控制”。先启动板卡链路，再选择板端 HDMI 模式、标记开关及直径（4～32，默认 10），点击“应用板端显示”。切换不重启 UDP、摄像头或 HDMI 采集。参数 JSON 可直接编辑，也可显式填入标定页已保存参数；点击“上传并验证 FPGA 参数”才会写入板卡。损坏或缺失的保存参数不会自动替换后写入。

“原图”指同一灰度 ISP 图像、不执行几何映射，不是原始 RAW S0。网口保持现有默认 enhanced RAW8 / RENH v2 阶段标签。HDMI 模式为 FPGA 时禁止浏览器重复标记或再次软件矫正；切换到“计算机软件参考”才恢复原有软件参考按钮和叠加。

## HTTP 与 UART

写请求沿用同源检查及 `X-Pango-Token`。所有操作通过 `BoardLink.control_session()`，与启动流程共用 `uart_lock`；校验已选唯一 CP2102、接收 epoch、UART epoch/session。生命周期操作在 UART 忙时拒绝。设备和固件缺失时返回显式错误，不创建本地成功状态。

| HTTP | 内容 |
| --- | --- |
| GET `/api/board/geometry` | CAPS 0x80、当前参数版本及首次应用帧；不是 HDMI 帧关联证明 |
| POST `/api/board/geometry` | `{preset, rotation_deg?:0, enhance?:true, version?:N}`；现有 GeometryClient 完整上传、参数回读、按帧激活等待 |
| POST `/api/board/view` | `{mode:"original"或"corrected", markers:boolean, diameter?:10, revision?:N}`；CAPS 0x100 必须存在 |
| GET `/api/board/markers` | 一致的 FPGA 标记元数据，含 20 条源位置、目标 Q12 解码位置、颜色与可见性 |

0x35 请求为 24 字节：epoch LE64、session LE32、revision LE32、flags LE32、diameter LE32。flags bit0=原图，bit1=显示标记。其他位拒绝。回复额外 12 字节为请求 revision、已显示 revision、**已显示** flags | (diameter<<8)。ACK 不等于已显示：客户端继续回读确认。

0x34 bank=2：0 magic `0x4d4b5231`；1 显示 revision；2 flags/diameter；3 HDMI 显示参数版本；4 20 位可见掩码；5 generation；6 status。每个 ID 的五字记录位于 `16+5*(id-1)`：source x低16/y高16、dest x signed Q12、dest y signed Q12、RGB24、visible bit0。READ 回复 version 字段是 **HDMI 参数版本**，不是显示 revision。

根据当前 `geometry_marker_table.v`，status bit0=ready；bit1=映射失败、bit2=LUT失败、bit3=模型不支持。主机仅接受 status=1、generation非零；错误或未知位均失败关闭。头部七字在全部记录前后重复读取，全部 READ 参数版本、头部、revision/generation 必须一致，最多重试三次。记录可见性须与掩码一致，保留位和尺寸须有效。

## 来源与验收边界

源像素叠加只使用 bank2 的 SOURCE 坐标、RGB 和 visible，不能用目标映射位置标记未矫正网口图像。叠加还要求网口为硬件来源、epoch 相同、源尺寸匹配；失败、过期、等待写入或链路中断清除旧层。原始 RAW 和采集像素不被改写。普通 HDMI 始终 `source_frame_id=null`、`pairing_status=unverified`、`hardware_image_verified=false`。

参数主点缩放已改为 `(cx+0.5)*sx-0.5` / `(cy+0.5)*sy-0.5`，与标准 `sourcePoint` 的像素中心约定一致。

## 集成注意

逐帧递增 generation 导致慢 UART 回读持续不一致的问题已修复。当前 FPGA snapshot 仅在收到 HDMI 显示确认，且 `generation==0`（首次有效快照）或 `metadata_changed` 时更新快照并递增 generation；`metadata_changed` 比较完整 metadata。同配置、同 metadata 的不同源帧重复显示不会改变 generation，也不构成 HDMI 源帧配对证明。

完整回读仍为 114 次 UART 事务；请求 30 字节加回复 42 字节，115200/8N1 的纯线速下限约 0.713 秒，尚不含软件调度和设备处理。配置或 metadata 在读取窗口内频繁变化时仍可能读到不一致快照，HOST 保留前后 generation/revision、全部 READ 参数版本及头部一致性检查，最多重试三次；持续不一致即报错并清除叠加，不忽略 generation、不混合多次快照、不以主机重算坐标回退，也不按到达顺序配对 HDMI。

目前只运行离线 fake-UART HTTP/锁测试与 Node 线框客户端测试；没有操作板卡、运行 PDS、烧录、重启采集链路或完成真实图像验证。Hagibis 名称 + VID_1DE1/PID_F105 + 唯一物理路径的采集限制保持不变。

2026-10-06：Python 组合回归 63 项通过（geometry_control、board_geometry、board_link、webui、hdmi_device_identity）；最终小修改后重点 33 项再次通过。前端 23 项通过（6 个 board_geometry 线框客户端、6 个标准 marker、10 个 HDMI 软件参考、1 个 board_link）。修改 JS 语法检查通过。组合测试曾出现一次既有短寿命 HTTP 帧空响应，单项与组合复测通过；Windows 主动断开预览流时另有现有 ConnectionAbortedError 日志，未改变测试结论，也未在此功能改动中修改该路径。真实浏览器视觉验收及硬件串口联调未执行。
