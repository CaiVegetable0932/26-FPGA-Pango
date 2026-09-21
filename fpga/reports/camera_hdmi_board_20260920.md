# 单路摄像头 HDMI 上板验证：未通过

## 范围

在 main a3616f7d 的独立工作树、codex/fpga-camera-hdmi-preview 分支验证现有 CAM1 RGB565 → DDR 帧池 → HDMI 链路。未修改原工作区、reference、官方资料、MCU 或系统设置；未写 Flash/eFuse。本轮没有修改 FPGA RTL，只补充原生位流构建入口及 host 720p30 预览偏好与测试。该诊断链不是 RAW8 千兆网产品基线。

## 已执行结果

- PDS 2022.2-SP6.4 原生完整构建退出码 0，错误数 0，内部 STA 为 All Constraints Met。证据：fpga/build/mini_camera_diag/native_20260920_133030_019/ 和 timing_audit.json。外部 DVP/DDR/HDMI 时序签核仍未完成。
- 位流 implementation/generate_bitstream/Top.sbit SHA256：8D2818CDA75309CC64B722D2BD46451D495CC081E17CD6D62601CEF1BA91D668。
- PG2L100H ID 0x00602899，经 USB Cable II 完成易失 SRAM 下载，DONE=1；证据：fpga/build/camera_preview_program_20260920_133647/。
- 下载前状态 0x081ffca0，下载后及随后复查均为 0x0816fca0。官方 Fabric_Configuration_User_Guide.pdf 的 Logos2 状态定义中，bit19 pll_lock 和 bit16 gouten 分别由 1 变为 0；配置 CRC/ID 错误为 0。此状态不能用于区分是哪一路 PLL 失锁，也不能独立确定根因。
- over_temp 在下载前后均为 1；没有实际温度读数，也没有证据证明其直接导致本次无信号。未屏蔽告警。
- 使用名称及 VID_1DE1/PID_F105 绑定 Hagibis，1280×720 MJPEG 30fps 采得 82 帧；首帧 RGB SHA256 为 489c5ab9511e0b44b8e194d6ca7ffc83fd70dc5ebe04799392b3fed62852dee8，与已知 No Signal 图像一致。因此传输帧数不构成摄像头视频成功证据。
- 采集原始容器、解码 RGB、元数据及派生预览：host/data/hdmi_diag_20260920_133941_444162/。source_frame_id=null、pairing_status=unverified；尚未进行有效的遮挡镜头测试。
- 软件回归：host 视频输入 15 项、Hagibis 身份 4 项、FPGA 集成静态检查 4 项、host 完整回归 68 项通过。不是本轮 RTL 动态仿真结果。

## 当前边界与后续

### 用户反馈 LED 不闪后的代码核查

- heart_beat_led 在 core_clk 域计数，必须 ddr_init_done 为高才翻转；它不是独立的 27 MHz 系统时钟存活指示。
- cam_led0 在 camera_clk_0 域计数，依赖 cam_reset_n 释放；cam_reset_n 又依赖 rst_in 与 HDMI PLL locked0。cam_led1 是摄像头配置完成状态，不是闪烁心跳。
- 因而 LED 不闪与 DDR 未初始化、摄像头时钟缺失、复位未释放或全局输出关闭均相容，不能单凭此反馈确定根因。
- 当前 clk_p/clk_n 的 N3/N2 引脚约束使用 SSTL15D_I；reference 中双摄像头例程 ov5640_200k/ov5640.fdc 使用 HSTL15D_I。这是待核对差异，尚未确认是故障原因，未修改约束。
- 用户已要求后续烧录固化至 Flash；本轮只记录规则，未执行新的 SRAM 或 Flash 下载，原有 Flash 未被本轮覆盖。官方 PDF 的只读文本访问被自动权限审核拦截，待澄清读取授权后核对原生 Flash 流程。

main 的此前报告明确新集成时钟结构只经过离线验证，之前可见彩条来自隔离工程旧位流；不能继承为本摄像头位流的硬件通过结论。本轮未获得摄像头画面，也未完成 HDMI 视频验收。

先核对板端复位、供电与时钟状态，定位 PLL/global output 状态；再决定是否修改时钟结构并重新做内部时序验证。不要仅为强行显示而覆盖输出控制或加入未证实的时序例外。有效视频恢复后，再由用户遮挡 CAM1，确认预览同步变暗并恢复。当前无需遮挡，也不把 No Signal 当作静态摄像头画面。尚未提交或推送本轮修改。
