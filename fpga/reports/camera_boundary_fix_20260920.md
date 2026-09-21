# DVP帧边界修复

## 已构建固化，等待实物复测

原生构建 native_20260920_175939_986，退出码0、错误数0，内部时序All Constraints Met。SBIT/SFC归档在fpga/build/camera_boundary_flash_20260920/，SHA256均为9B4DF61797157852E16EC335248DB4E20347846EEC799AB337C32675794ED41D。

该目录program.log记录整片擦除12.8秒、写入91.2秒、校验31.5秒均成功，NATIVE_EXIT=0、JTAG已断开。旧Flash镜像已替换，前序恢复镜像保留，未操作安全配置。当前四页LED含义不变；须断电重启后检查第二页完整帧、第三页像素放行/显示就绪和真实摄像头画面。本轮尚未验证画面恢复。

## 复现与修复

camera_data将VSYNC独立延迟后再启用flag，但HREF/data直接采样。若第一行在VSYNC下降沿同时或紧随其后开始，首字节会被丢弃，像素配对错位，首行无法凑满FRAME_WIDTH*2，EOP/预热门控可能不再推进。新增tb_dvp_boundary在未修复源码上复现BOUNDARY_FAIL shifted pixels，证据boundary_before.log。

本次让VSYNC边沿与同拍HREF/data一起判定，允许下降沿当拍接收首字节；仍要求配置完成、VSYNC低、HREF高，不放宽尺寸或预热要求。跨域cfg_done/ddr_init仍使用两级同步。外部DVP时序尚未实测签核。

mini_dvp_observe也存在边界计数漏洞：VSYNC下降沿同拍首字节未计入；最后HREF下降沿与VSYNC上升沿同拍时，最后一行未结算。本次修正这两种情形。因此旧版观测灯未认出完整帧，不能单独证明传感器实际输出行数错误。

## 离线验证

fpga/build/camera_startup_audit_20260920/：

- tb_dvp_boundary_boundary_after.log：间隔0～6周期，缩小尺寸下逐像素数据、EOP、观测标志均通过。
- boundary_full720.log：同样7种间隔，1280×720，每帧921600个像素顺序检查、1个EOP、flags=1111，DVP_BOUNDARY_PASS；共7帧6451200像素。
- tb_mini_dvp_boundary_after.log：原有27项字节序、就绪门控、行间重新对齐测试通过。
- tb_camera_warmup_audit_boundary_after.log：12个短帧不放行，默认10个完整帧丢弃，第11帧放行通过。
- tb_mini_dvp_observe_boundary_after.log：部分帧、短行、正确帧与复位清除通过。

这些是合成波形仿真，不证明实物确实具有该边界关系，也不是摄像头画面恢复的证据。本次保留此前FIFO写长度修复及四页诊断；摄像头寄存器表、720p参数不变。等待原生时序审核、固化校验及冷启动实测。
