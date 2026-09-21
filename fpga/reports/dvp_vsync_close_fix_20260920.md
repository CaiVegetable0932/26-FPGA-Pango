# DVP 最后一行结算与预热门控修复

## 实物反馈与判断边界

用户确认新启动固件下 LED0/1 同亮时 LED3亮（身份及配置回读成功）；LED0亮、LED1灭时 LED4亮（曾检测到完整720p几何帧）；LED0灭、LED1亮时 LED3灭（尚未输出采集像素）。这些是用户观察的状态，不是逻辑分析仪采到的波形，也不证明摄像头连续帧均正确。

本轮不再修改摄像头寄存器，定位采集端和旁路观测端之间的差异。旧采集端仅在 HREF 下降时结算最后一行；若 VSYNC 先上升，会先清除 active，随后 HREF 下降无法结算。旁路观测端却允许 VSYNC 上升结算最后一行。因此能出现完整帧灯亮、预热计数始终为0、无像素的组合。

## 可复现缺陷与最小修复

`fpga/sim/tb_dvp_vsync_closes_line.sv` 发送12个尺寸正确的帧，让最后一行后的 VSYNC 先升高，HREF 在垂直消隐中稍后降低。修复前 `camera_rewrite_20260920/vsync_close_before.log`：raw=1111、warmup=0、pixels=0，VSYNC_CLOSE_FAIL。修复后 `vsync_close_after.log`：raw=1111、warmup=10、pixels=16，DVP_VSYNC_CLOSE_PASS（4×2缩小几何，前10帧丢弃，随后2帧）。

修复只更改 `vendor/camera/camera_data.v` 的行结算条件：HREF下降或VSYNC上升均可结束有效行；不计消隐区字节，不放宽行宽/高度、不绕过十帧预热。结束时清除active，后续HREF下降不会重复计数。SCCB、ID/配置回读、DDR、HDMI、引脚和时序约束保持不变。

依据：只读核对本地 OV5640 DVP 应用指南第27页，当前4740=20对应VSYNC低/HREF高时有效；以及安装版 PDS 用户手册 report_timing 命令。其余平台来源及电气/时序边界见 camera_verified_rewrite_20260920.md。

该缺陷已通过仿真确证；与实物观测相符，但仍需新固件冷启动和真实画面确认才能判定它是本机黑屏的实际原因。

## 本轮验收

`fpga/build/camera_verified_sim_20260920_210841/` 的8个测试全部通过：SCCB读写及异常、启动故障注入、默认启动等待、RGB565采集、原预热门控、完整720p边界、新VSYNC结算、摄像头封装。重放命令为 `fpga/scripts/sim_ov5640_verified.ps1`。

补充 `camera_rewrite_20260920/vsync_close_full720.log`：1280×720、HREF延后4拍在消隐区下降，12帧输入，raw=1111、warmup=10、输出1843200像素（后两帧），DVP_VSYNC_CLOSE_PASS。该项参数化运行，不是摄像头真实帧率/画面测试。

本轮Flash预检目录 `fpga/build/camera_vsync_close_flash_20260920/`：设备ID00602899，服务器确认Flash ID b4018；状态081ffca0（DONE/PLL/GOUTEN为1，无CRC/ID错误，over_temp仍为1）。未关闭保护或写安全寄存器。

原生PDS构建 `native_20260920_210822_723`：21:08:29–21:13:53，退出码0、错误数0，完整生成位流，内部时序 `All Constraints Met`。新SBIT/SFC位于 `camera_vsync_close_flash_20260920/`，SHA256均为 `7E5A9512F99BEC68B2CA04AA8192FF8149241348E06774804B0BAEE396EA4162`。cfg_gen_sfc 原生转换成功，SPI X1/opcode11/起始地址0；保留旧版C7CFCF...固件及已知HDMI恢复镜像。

Flash擦除13.0秒、写入91.3秒、回读校验31.5秒全部成功；program.log包含CAMERA_FLASH_ERASE_PROGRAM_VERIFY_COMPLETED，原生退出码0，JTAG已断开，专用服务退出。按先前授权擦除整颗XT25F128并替换为本次镜像；旧镜像和已知HDMI恢复位流保留，但不是整颗Flash数据备份。未进行SRAM-only下载或eFuse/安全操作。

等待用户断电重启后检查：LED0灭/LED1亮时LED3（像素放行）、LED4（显示帧池就绪），以及PotPlayer/host真实画面与遮挡响应。尚未宣称实物黑屏已解决。全部操作在 codex/fpga-camera-hdmi-preview 工作树；官方文档和 reference 只读，未修改其他分支或参考源。外部DVP时序未签核，不将内部STA通过等同物理输入时序通过。
