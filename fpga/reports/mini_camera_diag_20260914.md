# MINI 摄像头厂商例程适配与离线验证（2026-09-14）

## 当前结论

已建立独立的 **PG2L100H-6FBG676 / J10 CAM1 / 720p RGB565** 诊断工程。
截至 2026-09-17，已完成离线回归、PDS 原生位流生成、易失 SRAM 下载和
Hagibis HDMI 短时采集。9 月 14 日的时序失败及“未烧录”内容保留为历史记录，
以本节和下方“2026-09-17 延续验证”为当前结论。

本工程不能替代 RAW8/1080p30 的主方案，也不能作为 FPGA ISP、几何矫正或 PRAW 网络回传验收结果。

当前分支为 `codex/fpga-pds-project`。未切换或改动其他分支，未提交、未推送。
保留了开始工作时已有的 48 个暂存文件和其他工作区修改。

## 2026-09-17 延续验证

| 项目 | 实际结果 | 证据 |
| --- | --- | --- |
| PDS 原生全流程 | `gen_bit_stream` 原生退出 0、错误 0；同次时序报告 `All Constraints Met.` | `native_20260916_211619_864/`、`timing_audit.json` |
| 位流 | `Top.sbit` SHA-256 `7DFA379D20516670411496E7A3D8CE65BB58E020A6CD616CBDCD97647404843B` | `implementation/generate_bitstream/Top.sbit` |
| JTAG 烧录前 | USB Cable II、PG2L100H、ID `0x00602899`；DONE=0、over_temp=0、配置错误位全 0 | `status_20260917_194922_559/` |
| 易失配置 | 仅 CRAM/SRAM，进度 100%，DONE=1；未操作 Flash/eFuse/key | `program_20260917_195007_007/` |
| HDMI 主机采集 | Hagibis 协商 1280×720、30.00003 fps；2.281 s 收到 55 帧、0 读取失败、55 个唯一帧哈希 | `host/data/hdmi_diag_20260917_200123_460448/result.json` |
| 采集后状态 | DONE=1，CRC/ID/readback/timeout 错误位全 0；over_temp=1 | `post_capture_status_20260917_200206_579/` |

本轮证明 FPGA→HDMI→Hagibis 的 720p 动态视频传输已经建立；首末帧哈希不同，
且不等于此前静态“No Signal”基线。因未对画面内容做人工视觉核验，来源身份仍为
`null/unverified`，不能仅凭到达顺序声称已确认是 OV5640 实景，更不能替代 RAW8、
1080p30、ISP、矫正或千兆网链路验收。烧录后 over_temp 再次置 1，未屏蔽该告警，
本轮只执行了短时采集并停止继续压力测试。

## 来源与落点

- 原始板卡厂商例程：
  `reference/盘古100K200K MINI开发板/2_Demo/5_1 双目摄像头例程/ov5640_200k`。
  原目标是 **PG2L200H / FBB676**，不是 100H，不能直接沿用其工程目标。
- 适配源码：`fpga/rtl/mini_camera_diag/vendor/`。
- 本次复制的 FIFO：`fpga/ip/mini_camera_diag/`。
- 复用现有 100H 原生 `ddr3_controller`、`video_pll` 及串行器封装；未改动这些共享实现。
- 新工程：`fpga/project/mini_camera_diag/mini_camera_diag.pds`。
- 约束：`fpga/constraints/mini_camera_diag/`，DDR 板级引脚复用现有专用 FDC。
- 构建与证据：`fpga/build/mini_camera_diag/`。
- 来源清单记录了 41 个原始文件及 SHA256；适配后复核 **41/41 原始文件均未改变**。
- 仅在副本中对四个混合编码文件做 GBK→UTF-8 规范化。未修改参考目录、PDS 安装资料、系统设置或下载保护入口。

查阅了安装版 PDS 2022.2-SP6.4 build 146967 的 PDS、IP Compiler、Simulation、
Timing Analyzer、UCE 手册，以及板卡/摄像头参考资料。官方资料先复制到本开发区再读取，
不在官方目录写提取文本、日志或结果。UCE §2.2.1.2 的原生 CLKDIV 时钟推导用于 HDMI /5 约束。

## 已修改的功能块

| 功能块 | 修改与用途 |
| --- | --- |
| SCCB | SCL/SDA 开漏 0/Z；释放第九位并检查 ACK；NACK 停止、拉伸超时退出；锁存请求，忙时不接受新请求。完成脉冲不等于成功。 |
| 配置表 | 保留 244 条有效厂商写事务；删除最后四条对只读 ID 高字节寄存器 0x300A 的占位写；修复越界/额外事务；软件复位后等待 5 ms。 |
| 摄像头封装 | ACK 成功才推进配置；失败保持未完成；PCLK 域独立释放复位；修正 27 MHz 下的延时注释。没有实现芯片 ID 读取。 |
| DVP 数据 | 配置/DDR 就绪经两级同步；RGB565 字节拼接；HREF 间隙清除悬空半像素；VSYNC 重置行计数；保留启动丢帧。尚不具备整帧合法性校验。 |
| 单路顶层 | 去掉 CAM2 实例和拼接；绕过以 VSYNC 作时钟的厂商缩放模块；CAM1 使用完整 1280×720。 |
| DDR/FIFO | 原生 FIFO 重生成为 100H；补齐 9-bit 水位到 16-bit 比较值的高位；宽字深度改为实际 256；帧长改为 57,600 个 32-byte 字，4 个 2 MiB 地址槽。 |
| AXI 接口 | 修正 RID/LAST 位宽；显式区分通用适配器与原生 DDR 的地址、LEN、ID 宽度。固定 16-beat 请求下使用低位，不代表已完成 DMA 事务回归。 |
| HDMI | 复用原生 PLL、CLKBUFR、IOCLKDIV_E2，生成同源 371.25/74.25 MHz；复用原生 10:1 主从串行器封装；补齐显示第三级复位。 |
| CDC | 增加读写请求 ACK 的两级返回同步和若干域复位；不将这些局部修复冒充完整帧池 CDC 签核。 |
| 工程/注释 | 使用原生 tcl2prj 写 .pds，再由 PDS 打开构建；所有参与本诊断的业务 module 已有用途注释。 |

注：FIFO 实例名称中的 `64` 是厂商历史命名，实际数据宽度是 **16↔256**，
不是 16↔64；按名称推断容量或帧长会出错。

## 已执行验证及证据

| 验证 | 实际结果 | 证据 |
| --- | --- | --- |
| SCCB/配置回归 | PASS：1,238 检查，6 个 ACK/NACK/超时场景，244 条配置事务；无额外第 245 条请求 | `sim_20260914_212726_581/simulation.log` |
| DVP 单元回归 | PASS：27 检查；字节序、行间奇字节重对齐、帧起始 SOP、末像素 EOP、就绪与复位门控 | `sim_20260914_212726_581/dvp_simulation.log` |
| 两个原生 FIFO 重生成 | 各 0 error、0 warning | `native_20260914_212425_664/afifo_*.log` |
| .pds 原生生成、重新打开、首轮 Compile | native_exit=0，error_count=0，有新生成 .cmr | `native_20260914_212425_664/result.json` |
| 最新源码重新编译与 Synthesize | native_exit=0，error_count=0，有新生成 .snr | `native_20260914_212911_838/result.json` |
| 引脚/IP 静态检查 | 100 个引脚无重复 port/pin；4 个 IDF 均为 PG2L100H / FBG676 / -6 | `input_audit.json` |
| 原参考源完整性 | 41/41 原 SHA256 一致 | `reference_integrity.json` |

以上相对证据路径均位于 `fpga/build/mini_camera_diag/`。
单元测试使用 ModelSim SE-64 10.1c，不含完整 DDR/摄像头/TMDS 联合仿真。

### 布局布线与时序

本轮原生 Compile → Synthesize → Device Map → Place & Route → Report Timing
已执行完成，耗时约 3 分 28 秒，native_exit=0，error_count=0。
记录：`native_20260914_213107_080/result.json`。
**时序结论为 FAIL：原生报告写明 “Some Constraints Violated.”，不是时序通过。**

- Slow corner setup 最差 **−7.235 ns**：显示 FIFO 读指针
  `ASYN_CTRL.rptr[12]` → DDR 域第一级 `wrptr1[12]`。
- Slow corner recovery 最差 **−4.515 ns**：DDR 域的
  `frame_fifo_read_m0/read_req_ack` → 显示 FIFO DRM 的 `RSTB[0]`。
- 还存在相机↔DDR、系统→相机、DDR→显示等跨域负 slack。
- 不能通过把独立时钟强行视为同步、整域 false path 或只看同域 Fmax 消除问题。
  应先验证 Gray 指针跨域的有界延时约束，以及 FIFO 复位在各端口时钟域的释放方式。
- 时序原件：`implementation/report_timing/Top.rtr`；
  独立判定：`timing_audit.json`。构建脚本现会在该审计失败时停止，保留原生结果。
- 布局布线资源记录：CLMA LUT 4,131，CLMS LUT 1,639，DRM 8，APM 0。
  这不是功耗或温度测量。

PDS 综合已明确发出 **Timing-4086：摄像头数据、HREF、VSYNC 等输入无外部延时约束**；
还存在厂商 IP 常量探测/未使用端口等警告，未将 warning 数量隐去为零。
相机时钟的 100 MHz 仅为暂定内部分析预算，既不是实测 PCLK，也不是 OV5640 模式时序证明。

## 2026-09-14 未烧录原因（历史记录）

1. **历史告警未查清**：先前状态为 `0x0810FC80`，bit27=`over_temp=1`。
   没有本轮 ADC 温度、阈值、供电或告警解除记录。该标志不能直接证明实际温度达到某个值，
   但也不能以“暂时忽略”屏蔽它。本轮未读取/改写 JTAG、未新增板上运行负载，已建议断电。
2. **外部时序未闭合**：缺少本摄像头模式的有效数据窗口、排线/板级偏差和 HDMI 输出签核；
   不凭空写 input/output delay，不用整域 false path 抹掉摄像头/显示 CDC 问题。
3. **帧槽所有权仍不完整**：厂商 VSYNC 轮转读索引不是 DDR 写完确认；首次显示可能读取未写内存，
   缺少显示占用保护、超时/异常帧回收及有效帧发布。尚不能保证不撕裂或同帧身份。
4. **异常视频与 DMA 尚未验证**：短行/超长行、缺失 VSYNC、FIFO overflow/underflow、
   DDR 背压、字序/突发边界、显示读延时、TMDS 全帧编码需要联合回归。
5. **接口身份仍需实物签核**：当前 J10 定义仅对应参考资料中的官方模组；SCCB 上拉 2.8 V、
   Bank L5 与 RESETB 电气兼容性未做本轮实测。模组自身有 24 MHz XCLK，不由本顶层提供。
6. **PC 回传不存在**：该厂商摄像头工程没有以太网 MAC/UDP/PRAW 发送链路，本次也未把 RGB565
   HDMI 路径冒充 RAW8 S0，未打开 host 接收并伪报采集成功。

上述条目记录 9 月 14 日当时为何未放行，已由 2026-09-17 的窄范围时序例外、
全流程重构建和用户明确要求的短时 SRAM 实测部分更新。当前仍不具备外部 DVP
setup/hold 签核、画面来源身份确认或长期热稳定性结论。

## 后续顺序

先完成帧池发布/占用握手、FIFO 异常与完整视频联合回归，再根据模式时序和板级资料闭合约束。
硬件告警及电气问题获得可核验的排除证据后，才能安排短时 SRAM 下载与真实摄像头/HDMI 采集验证。
PRAW/RAW8 网络链路作为主方案另行实现，不能由此 720p RGB565 诊断结果替代。
