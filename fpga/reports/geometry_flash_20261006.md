# 灰度矫正候选 Flash 固化记录 — 2026-10-06

用户本轮明确授权整片擦除 XT25F128、写入并校验。操作工作树为 codex/fpga-geometry-correction，未修改 RTL、约束、官方参考或系统驱动，未提交/推送。

## 结果

- PDS 2022.2-SP6.4 build146967，项目专用 cdt_js/cdt_cfg_shell，USB Cable II，烧录/回读 JTAG 500kHz。
- 预检：PG2L100H ID 0x00602899，外部 Flash ID 0x0B4018（XT25F128）。历史状态位 over_temp=1 保留，未屏蔽、未测量实际温度。
- XT25F128整片擦除成功（12.8秒），新镜像写入成功（121.3秒），原生 cfg_jtag_flash_verify 校验成功（61.7秒）。
- 随后单独 cfg_jtag_flash_readback 成功（61.7秒），3791112字节镜像 SHA-256 与发布SFC完全相同：`5CFC0A3D20D020BC8ECB07B3377C284AFC7B5D08147D9E1676D07C2CD9C51BF5`。
- 恢复镜像 `raw8_dual_20260927_20950eb05c35` 已校验并另存本轮目录，SHA-256 `20950EB05C357525C1DE7E16452D956D4BD93C0F43096BABFA7C7ADEFF7566C4`。不是烧录前Flash全片备份；此次授权的整片擦除已清除原Flash内容，已知旧固件可用恢复文件重新烧录。
- JTAG会话正常断开，本轮启动的专用服务已退出。未使用软复位替代冷启动；未启动串口配置或视频采集。

## 证据

目录：[geometry_flash_20261006_143135_570](../build/geometry_flash_20261006_143135_570/)。

- probe.log / probe-server.log：器件与Flash身份。
- program.log / program-server.log / program_result.json：整擦、写入与原生校验。
- readback.log / readback_result.json / flash_readback_verified.sfc：独立回读与哈希。
- recovery_20950eb05c35.sfc：已知旧版恢复固件。

第一次调用在本地 Select-String 预检参数绑定阶段停止，尚未启动擦写；修正参数后只执行了一次整片擦除与写入，没有重复擦除。回读日志 Configuration-4002 提示新目标文件不存在并创建，是预期文件创建提示；无错误，完成标记和哈希比对均通过。

## 尚未完成

冷启动及新固件功能验收均为false。须先由用户彻底断电、排除USB反向供电后重新上电，等待约10秒并确认，才能继续UART、摄像头、DDR、HDMI、网口和参数矫正测试。本次Flash校验不能代替图像质量、外部DVP时序或实时1080p30验收。
