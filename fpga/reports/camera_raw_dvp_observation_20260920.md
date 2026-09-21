# 原始 DVP 黑屏定位

## 诊断版已固化，待冷启动灯态

原生构建 native_20260920_154753_610 完成，退出码0、错误数0、All Constraints Met。诊断SBIT/SFC位于fpga/build/camera_raw_observe_flash_20260920/，SHA256均为02D815110B77A1D5BB44C1A0FF0900F10E4E794DEE1100080C4441E3EBE9EF42。外部摄像头时序仍未实测签核。

同目录program.log记录整片擦除13.0秒、写入91.3秒、校验31.5秒全部成功，NATIVE_EXIT=0；JTAG断开，无遗留配置进程。Flash旧内容已被本诊断版替换，先前恢复镜像保留。尚未观察这版冷启动或画面，不宣称黑屏修复。

## 板端反馈与只读状态

首帧FIFO修复版固化后，用户确认LED0/LED2闪烁，LED3/LED4不亮，PotPlayer仍黑屏。本轮只读JTAG状态0x081ffca0：DONE/PLL/global output正常，over_temp仍置位。此前FIFO缺陷并非所有黑屏问题的充分解释。

若实际运行的确为该修复版，LED3不亮说明预热后未见有效像素，因此需要检查摄像头输入及首帧放行，而非首先调整HDMI。此前Flash校验已通过，但不能用Flash内容代替运行中镜像身份的验证。

只读查阅OV5640_AF_Imaging_Module_Application_Guide_(DVP_Interface).pdf第27页：默认0x4740=0x20对应VSYNC低时数据有效、HREF高时数据有效、数据在PCLK下降沿推出。与当前接收器上升沿采样约定一致。此前仅按数据手册Active high/low字段解释的疑问由更具体的接口指南澄清；没有据此随意改极性。

## 新增被动观测

mini_dvp_observe在原始PCLK域观测，不依赖cfg_done或预热门控，不驱动相机。记录四个上电后粘滞标志：VSYNC边沿、HREF边沿、完整2560字节行、720条正确长度行组成的帧。标志只表示事件曾发生，不代表持续无丢帧。完整帧识别基于正常行间空白与VSYNC边界，不替代波形分析。

LED2保留DDR初始化后心跳。其他灯为高电平点亮；LED1:LED0为页号，每两秒切换，八秒循环。请上电十秒后记录一整轮，避免启动过程影响：

| LED0 | LED1 | 页号 | LED3亮的含义 | LED4亮的含义 |
|---|---|---|---|---|
| 灭 | 灭 | 00 | 原始VSYNC出现边沿 | 原始HREF出现边沿 |
| 亮 | 灭 | 01 | 曾有2560字节的行 | 曾有720行正确完整帧 |
| 灭 | 亮 | 10 | 预热后曾放行像素 | 完成帧被显示DMA接纳 |
| 亮 | 亮 | 11 | SCCB配置流程完成 | DDR初始化完成 |

各独立状态经sys_clk域两级同步，首级添加既有6ns单比特CDC界限，第二级及后续逻辑仍参与时序分析。摄像头配置、视频门控、DDR及HDMI数据路径未改；保留此前写FIFO修复。

仿真tb_mini_dvp_observe覆盖部分帧、短行、正确帧及复位清除，DVP_OBSERVE_PASS，证据fpga/build/camera_startup_audit_20260920/observer.log。待原生构建/时序/Flash校验后再记录冷启动观测，不能把新观测模块当成黑屏已修复。
