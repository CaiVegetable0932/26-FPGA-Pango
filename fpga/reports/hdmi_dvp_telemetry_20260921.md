# HDMI DVP 几何诊断（2026-09-21）

## 目的与现有证据

用户 LED 视频对应 capture_status A7：摄像头配置及 DDR 已就绪，捕获域已解除复位，曾见到帧起始和非法行，但预热有效帧计数仍为零。该观察不能确定实际行长度，也不能把配置前的原始帧观察结果当作配置后成功采集。

本次加入独立 DVP 几何测量，在捕获逻辑因异常行提前退出后仍持续统计完整 HREF 行，保存配置后的首个异常行完整字节数、行号、最近帧行数、有效/异常/总帧数。计数器饱和，不回绕。源为与 camera_data 共用的 PCLK 单级采样信号。

新增 mini_dvp_measure、mini_diag_snapshot、mini_diag_raster；每个模块有用途说明。跨 PCLK/HDMI 的 160 位快照使用保持数据与请求/应答握手，目的域追加同步与等待周期。约束只作用于跨域首级；未放宽摄像头采集内部时序。

没有可显示帧时，HDMI 输出品红顶栏、青色底栏和 16×10 黑白数据格；有效帧存在时仍显示原摄像头 DDR 数据。诊断图不是摄像头图像，不能作为功能验收。

## 离线验证

- `fpga/build/camera_verified_sim_20260921_183252/`：12 项仿真全部通过，包含短行、长行、错误帧高、配置前数据隔离、首次错误保持、跨域一致性及 RTL 诊断页生成。
- `fpga/sim/test_hdmi_integration.py`：4 项测试通过。
- RTL 生成的 RGB 诊断页经 PC 解码得到 `d64101a70006000302d0000a000b0a0000010101`。再经 FFmpeg MJPEG 编解码后结果相同。这是仿真夹具，不是板端读数。
- `host/tests/test_dvp_diagnostic.py`：4 项测试通过，验证有效数据保留非摄像头身份，黑帧/尺寸错误/模糊单元格/错误 magic/保留标志拒绝解码。
- 原生 PDS 2022.2-SP6.4 构建目录：`fpga/build/mini_camera_diag/native_20260921_183431_942/`；18:34:38 至 18:40:37，退出 0，错误 0，新位流 1。
- `Top.rtr` 为 All Constraints Met。摄像头时钟仅按 100 MHz 内部分析预算；外部 DVP input_delay 尚未实测签核，报告中的端口未约束警告仍存在，不能宣称全接口时序验收通过。

## 位流及官方依据

- 固化目录：`fpga/build/camera_hdmi_telemetry_flash_20260921/`。
- Top.sbit/Top.sfc SHA256：`F0B39A4D56D71C0794E02A0C249C12B6977C46693042445ABA2C20222F2CA930`。
- 只读核对官方 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Fabric_Configuration_User_Guide.pdf` 第 4.5.4、4.5.6 节，使用原生 JTAG Flash 擦除、写入、校验及 opcode 11 / 地址零转换流程；官方目录无写入。
- 预检板卡 ID 00602899，Flash ID 0B4018，状态 081FFCA0。over_temp=1 保留，不屏蔽告警，不等同于温度测量。
- 用户已授权擦除整颗 XT25F128。本次替换其配置内容；旧位流及既有 HDMI 恢复位流保留，但不构成整颗 Flash 数据备份。

## 当前验收边界

固化已完成：原生整片擦除 12.8 秒、写入 91.3 秒、回读校验 31.5 秒，程序退出 0，program.log 含 CAMERA_FLASH_ERASE_PROGRAM_VERIFY_COMPLETED 且 JTAG 已断连。保留原生 program.log 和服务器日志。

现等待用户彻底断电再上电确认；未把 Flash 写入成功等同于新镜像已冷启动或视频链路成功。正常摄像头图像与遮挡响应仍未验证，RAW8 千兆网主方案也不在本诊断版本的完成范围内。
