# RAW8 双路候选首次 Flash 固化记录

日期：2026-09-23。分支：`codex/fpga-raw8-dual-output`；候选源码提交：`b295de0404235a34284a3a0e7e0d458b603e5ca7`。

## 实际完成

- 用户要求先烧录验证，已确认板卡接线、上电。本次按既有 Flash 固化约定，替换所选 XT25F128 配置 Flash；未操作 eFuse、密钥或第二颗 Flash。
- 原生 JTAG 实测 FPGA ID `0x00602899`（PG2L100H），Flash ID `0x0B4018`。状态 `0x081ffca0`：done、init_complete、pll_lock 为 1；CRC/ID/auth 错误为 0。这是替换前旧镜像状态，不是新候选启动证据。
- `over_temp=1` 仍存在；原样保留，未屏蔽告警/保护，未测得实际温度，不宣称热安全已经验证。
- 重新执行候选审计：270 个构建输入，最终时序门禁通过。写入文件为 `fpga/release/raw8_dual_20260923_2197404297e4/mini_raw8_dual.sfc`，3,791,112 字节，SHA256 `2197404297E45D3B3386D02FE69464460E6EE849D32E0FF190C1BF39AAFB0131`。SPI x1，起始地址 0。
- 所选 16 MiB 配置 Flash 整片擦除成功（13.0 s），写入成功（91.3 s），原生回读校验成功（31.5 s）；Tcl 完成标记及 `result.json` 均通过。旧配置已被替换，可用保留镜像重新烧录恢复。
- JTAG 会话已正常断开，任务启动的 JTAG 服务已停止；未关闭用户 PDS 窗口、未修改官方/reference 资料或系统网络设置。
- PC 预检：CP2102 `USB\VID_10C4&PID_EA60\0001` 对应 COM15；ASIX 网卡 ifIndex16、MAC `20-7B-D2-C0-29-96`、IPv4 `169.254.81.186/16` Preferred；Hagibis VID_1DE1/PID_F105 存在。以上不等于新镜像数据链路通过。

## 证据与恢复

- 预检：`fpga/build/raw8_flash_probe_20260923_155354/`，含原生配置/服务日志、Flash ID、状态及候选审计。
- 固化：`fpga/build/raw8_flash_program_20260923_155610/`，含 `program.log`、原生日志、审计和 `result.json`。
- 原以太网测试流恢复镜像：`fpga/release/comms_bringup_20260922_6abc5069a8b4/mini_comms_bringup.sfc`；SHA256 `6ABC5069A8B45B2E895CE50C7467F324515E50382D1A9B1F468B4672FED5CD1A`，本轮复核一致。
- 旧摄像头恢复镜像：`fpga/build/camera_div2_flash_20260921/Top.sfc`；SHA256 `317733DFC9A6D083971E2E09B203E403B8939E6163B33BD7EAB32667048CFAAC`，本轮复核一致。
- 操作依据：只读核对 PDS 2022.2-SP6.4 官方 `Fabric_Configuration_User_Guide.pdf` 第 89–90 页及 MINI 硬件手册 V1.3 第 17 页；使用既有项目配置运行副本及已审阅脚本，未修改工具安装目录。

## 尚未完成，不得视为验收通过

等待用户彻底断电再上电。新候选冷启动、RAW8 串口配置、以太网完整帧/帧率、HDMI 画面及遮挡镜头来源验证均未执行。HDMI 暂为 RAW 样本灰度显示，不是 ISP S1 或矫正图；帧源身份保持 unverified。发布 manifest 的首次发布状态不追改为硬件通过，实测以本报告和本次日志为准。

下一步：确认冷启动后生成新 epoch，先启动接收器再发送 RAW8 配置；仅绑定唯一 Hagibis 物理路径采集 HDMI。关闭 PotPlayer/host 预览以避免占用。所有实测原始证据仅留本地，本轮不执行云端推送。
