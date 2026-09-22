# 1080p RAW8 双路首板候选

目标：100K MINI / PG2L100H-6FBG676 / XT25F128。来源分支：`codex/fpga-raw8-dual-output`。生成日期：2026-09-23。

本包可进入首次上板验证流程，**尚未烧录、Flash 回读、冷启动或验证真实摄像头来源**；本轮未操作任何板卡接口。

- `mini_raw8_dual.sfc`：Flash 候选，起始地址0、SPI x1、opcode 11；由原生 cfg_gen_sfc 离线转换。
- `mini_raw8_dual.sbit`：同一原生 PNR 数据库导出的位流。
- 两文件均 3,791,112 字节，SHA256 均为 `2197404297E45D3B3386D02FE69464460E6EE849D32E0FF190C1BF39AAFB0131`。
- `timing.rtr`：最终快慢角 STA，All Constraints Met；`source_manifest.json` 固定270个构建输入，`audit.json` 记录发布门禁，`manifest.json` 区分文件生成与实机验证。

路径：J10/CAM1 OV5640 RAW8 → 原生 DDR 三帧池 → PRAW 千兆网和 HDMI RAW 采样灰阶。MAC 与 RGMII 之间经过原生整包跨时钟 FIFO，RGMII 使用独立125 MHz PLL。没有合成视频兜底，HDMI 不是 ISP S1 或几何矫正 S2/S3。

完整六帧及配置晚到五帧均在整包跨域桥之后由真实 host 重组器逐像素验证；HDMI各5帧检查通过、无欠载。数据为仿真激励，不是实测视频。外部 DVP 偏斜、RGMII PCB 偏斜、HDMI 电气、持续1080p30、Bayer相位和源身份仍未验收。

RAW8启动命令0x71、ACK `RAW8`，不能复用旧0x70/TEST配置。每次冷启动生成新epoch。HDMI source_frame_id 保持 null/unverified，不开启严格同帧精度测评。

使用前阅读 [构建与验收报告](../../reports/raw8_board_candidate_20260922.md) 和 [host启动/预览说明](../../../host/docs/RAW8双路候选启动与预览.md)。报告保留窄裕量提示、失败构建历史及原摄像头恢复镜像的路径/哈希。
