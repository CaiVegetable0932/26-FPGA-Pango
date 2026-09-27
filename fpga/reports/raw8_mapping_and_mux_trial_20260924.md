# 2026-09-24 RAW8 位映射与数据源诊断

## 受控位映射候选 1922021fe2aa

- 目标：PG2L100H-6FBG676、XT25F128；`0x4745` 从 `00` 改为 `02`，把 OV5640 的 D[9:2] 映射到模组引出的 D[7:0]。`0x501F=04` 保持 SNR RAW。
- PDS 原生构建：`fpga/build/mini_raw8_dual/native_20260924_175311_949/`，快慢角时序 All Constraints Met；外部摄像头输入延迟未约束，不能据此宣称 DVP 引脚建立/保持时间已验证。
- 仿真：`fpga/build/raw8_dual_sim_20260924_175055_597/` 和 `fpga/build/raw8_board_sim_20260924_175221_802/` 均通过；行为 DDR 模型不是实物 PHY 验证。
- SFC：`fpga/release/raw8_dual_20260924_1922021fe2aa/mini_raw8_dual.sfc`，SHA256 `1922021FE2AA85271DB8D3814920DD4D36A1A1DB6280216EF5B3E46CBA5AD619`。按用户本次授权整片擦除，写入及原生回读校验通过；日志 `fpga/build/raw8_mapping_flash_20260924/program.log`。用户随后确认彻底冷启动。
- 冷启动后 COM15 RAW8 Boot ACK result=0；Inspect 显示 sensor_ready、frame_published 均为 true，无记录/DDR/网口故障；HREF 每行 1920，VSYNC 每帧 1086 行。以太网网页接收约 30 完整帧/秒，原始帧证据在 `host/data/web-hardware_unverified-20260924T102459Z-e4b89ac8/`。
- 新版未通过图像验收：存档帧 f9420 的均值 101.366（旧版无遮挡帧 9.137），但相邻像素相关性约 0，预览为噪声，无可识别轮廓。两个版本的同一位置均有 1066 个 `FF FF FF` 三字节标记，主要每隔 1952 字节重复；改位映射不能消除该异常。`preview_derived.png` 只是 RAW 灰度派生图，不是独立原始证据。

## 下一候选及边界

OV5640 数据手册把 `0x501F=04` 定义为 SNR RAW，`03` 定义为 ISP RAW (DPC)。1952 字节标记间隔与当前传感器窗口宽度相同，1086 行也多于请求的 1080 行；这支持“传感器 RAW 抽头绕过输出裁切”的假说，但不能单凭间隔证明故障所在。下一候选只把 RAW mux 改为 `03`，维持 8 位映射、RAW formatter、时钟与曝光；采集端仅接受完整 1080 或 1086 行，始终写出前 1080 行，每行仍要求 1920 字节。若实物输出变成 1080 行，后续应收紧合同并重新确认 S0 来源和 DPC 对原始数据的影响。未烧录、冷启动和实测前不得把此候选标记为画面通过。

## ISP RAW 受控候选 9b6f725b154a

- `0x501F=03` ISP RAW (DPC)，保留 `0x4745=02`；DVP 捕获只接受完整 1080/1086 行，逐行仍需 1920 字节。启动、捕获、网口复位以及板级模型仿真通过；板级模型用行为 DDR，不等于实物画面证明。
- 首次 PDS 跑到布线后因 RGMII TX 复位恢复时序失败，修为网口输出专用同步释放；第二次有 RGMII D21 数据脚 0.064 ns 保持违例，未导出或烧录这些失败版本。D21 驱动强度由 16 调至 12，未放宽 `PHY_SAMPLE` 外部延迟要求。
- 最终原生 PDS 构建 `fpga/build/mini_raw8_dual/native_20260924_190350_163/` 生成位流，快慢角报告为 All Constraints Met；RGMII 外部路径最小建立余量 0.052 ns、保持余量 0.103 ns。构建审计核对 271 项输入。外部 DVP 引脚时序和 HDMI 眼图仍未实测。
- 发布包 `fpga/release/raw8_dual_20260924_9b6f725b154a/`，SFC SHA256 `9B6F725B154AFC5A62428E35DE93670E77224A537D5EC0631D649EA2A2678468`。只读探测 PG2L100H ID `0x00602899` 和 XT25F128 Flash ID `0x0B4018` 后，按用户本次授权整片擦除、写入并通过 PDS 原生回读校验；证据 `fpga/build/raw8_isp_flash_20260924/program.log`。旧镜像仍保存在独立发布目录。
- 待用户彻底断电冷启动后再做本镜像板上测试；当前不能声称真实摄像头画面、HDMI 锁定或双路回传已通过。状态寄存器仍报 `over_temp=1`，未屏蔽或修改。

### 冷启动后的首帧实测

- 用户确认彻底断电冷启动。COM15 RAW8 Boot ACK result=0；Inspect 的 sensor_ready、frame_published 为 true，已报告的 DDR/帧池/网口故障均为 false。网页接收端在新 epoch `7523612131053524654` 收到约 29.6 完整帧/秒，保存原始 1920×1080 RAW8 帧 f7407 于 `host/data/web-hardware_unverified-20260924T112514Z-a0760e0a/e7523612131053524654_f7407_t1_d945242450/image.raw`。
- 同目录 `preview_derived.png` 为 RAW 灰度缩放派生图，仅供人工审校。首帧均值 101.436，横向一像素相关性 0.0033、纵向 0.0047；画面仍接近随机噪声，无可辨识场景轮廓。ISP RAW mux 切换没有解决真实图像问题。以太网完整帧只证明传输与组帧，不证明摄像头像素正确；HDMI 尚未在本候选上实测。
