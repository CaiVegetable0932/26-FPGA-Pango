# 单路摄像头 HDMI 与 host 预览

本入口基于 main 的共用 HDMI 实现。当前联调模式为 J10/CAM1 OV5640
RGB565 1280×720，经 DDR 完整帧发布、RGB888 扩展后输出 720p60 TMDS。
Hagibis 的 PC 采集模式为 720p30；这两个刷新率分别记录。

## 构建与运行

1. 在当前 FPGA 分支工作树根目录执行
   `./fpga/scripts/build_mini_camera_diag.ps1 -Stage gen_bit_stream -LicenseFile <本机许可证>`。
   必须使用 `mini_camera_diag` 摄像头工程；`pango_video_top` 是动态自检图。
2. 查看 `fpga/build/mini_camera_diag/timing_audit.json`，要求原生时序通过。
   下载对象为 `fpga/build/mini_camera_diag/implementation/generate_bitstream/Top.sbit`。
   按当前用户约定使用 Flash 固化：先核对 PG2L100H/XT25F128，原生转换 SFC，
   再通过 `fpga/scripts/jtag_camera_flash_erase_program.tcl` 执行擦除、写入与校验。
   调用方设置 `CAMERA_SFC` 和已获授权的 `CAMERA_FLASH_ERASE_AUTHORIZED=YES`；
   整片擦除会清除其他 Flash 内容。校验通过后断电重启，不能把旧 SRAM 画面当作冷启动验证。
3. 双击 `host/scripts/start_web.cmd`，或运行 `python host/scripts/web.py`。
4. 工作台中打开“连接设置 → 视频采集卡输入”，刷新/授权后选择 Hagibis，
   保存设备选择，点击“打开预览”。现在优先请求 1280×720、30 fps；界面显示实际协商值。
5. 遮住再放开 CAM1 镜头，确认画面对应变化，排除自检图或其他摄像头。
   这只确认视频内容来源，不赋予 HDMI 图像 FPGA 帧号；配对身份仍为 null/unverified。

## 证据与边界

2026-09-21已完成Flash冷启动及J10/CAM1遮挡—放开实景来源验证，见
[实测报告](../reports/camera_scene_20260921.md)。当前摄像头3035=21，
使用降低源时钟的已验证候选；不将HDMI或UVC刷新率当作摄像头实际帧率。
品红/青色色条与黑白数据格是无有效帧时的诊断页，不是摄像头图像。

短时归档使用 `python host/src/hdmi_diag_capture.py --seconds 3`。
该工具核验 Hagibis 的 DirectShow 物理路径与 VID/PID，保存压缩原流和解码 RGB。
执行前关闭网页预览以释放设备，完成后再打开预览。
浏览器预览独立于左侧 RAW8 网络接收，本流程不需要启动网络模拟器。
RAW8/1080p30、ISP、几何矫正及严格同帧测评仍按主方案分别验收。
