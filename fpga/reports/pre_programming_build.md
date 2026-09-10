# PDS 原生工程重建与烧录前构建记录

日期：2026-09-10。分支：`codex/fpga-pds-project`。目标：MES2L676-100HP-MINI / PG2L100H / FBG676 / -6。工具：PDS 2022.2-SP6.4 build 146967。

## 当前结论

烧录前工具全流程已通过：15 个候选 IP 原生生成均为 0 error / 0 warning；主 `.pds` 经 PDS 直接读取，Compile、ADS Synthesize、Device Map、Place & Route、Timing、Netlist、Bitstream、Power 全部完成。2026-09-10 12:47:06–12:51:46 的最终一键重生成构建已通过严格审计，最终内部 STA 为 `All Constraints Met.`，快慢角建立、保持、恢复、移除检查均无违例。前一轮正式构建与本次从参数目录重生成全部 IP 的结果一致；最终位流身份见后文及 `all_result.json` / `all_audit.json`。

工程为 IP 集成底座，不是完整视频应用。没有运行功能仿真、DDR 测试、网络/HDMI 测试、下载器或实板烧录。

## 文件与重建入口

- 工程：[pango_video_top.pds](../project/pango_video_top/pango_video_top.pds)。结构由 `tcl2prj -tcl` 原生生成；不拼接 `.pds` 语法。
- 主脚本：[build.ps1](../scripts/build.ps1)，IP 参数：[ip_catalog.json](../config/ip_catalog.json)，板级约束权威输入：[board.json](../config/board.json)。
- 正式构建输出：[build/pango_video_top](../build/pango_video_top)。结果汇总以 `all_result.json` 和 `all_audit.json` 为准；失败诊断不等同于正式成功结果。
- 日志与诊断：`build/ip_generation/`、`build/project_generation/`、`build/route_diagnostic/`、`build/route_isolation/`。最后一个是去掉 HDMI 串行器的编译隔离副本，只用于排查布线，不生成位流。

```powershell
./fpga/scripts/build.ps1 -GenerateIps -LicenseFile '本机许可证的实际路径'
```

许可证参数只作用于本轮进程环境并在结束时恢复；没有修改系统/用户环境变量或许可证内容。正式工程不依赖被忽略的 `reference/` 或根目录 `PDS/`。本轮沿用 FPGA 专属分支，不切换、不回退、不推送其他分支。

## 原生 IP 清单与边界

| 配置实例 | 本轮候选配置 / 用途 |
| --- | --- |
| sys_pll | 125 MHz → 100 / 150 / 125 MHz |
| video_pll | 27 MHz → 371.25 MHz；原生 IOCLKDIV_E2 /5 产生同源 74.25 MHz、40% 占空比像素时钟 |
| ddr3_controller | 32-bit DDR3，1000 MT/s 候选，256-bit 用户接口 |
| raw_async_fifo | 8-bit × 2048 异步入口队列 |
| net_tx_fifo | 8-bit × 4096 异步发送队列 |
| display_fifo | 32-bit × 2048 显示跨域队列 |
| ddr_write_fifo | 32-bit × 4096 → 256-bit × 512 异步打包 |
| ddr_read_fifo | 256-bit × 512 → 32-bit × 4096 异步解包 |
| isp_line_ram | 32-bit × 2048 行存储；后续按窗口复制 |
| tile_cache_ram | 32-bit × 32768，128 KiB 原生深度候选；不是最终 cache banking 实现 |
| parameter_ram | 32-bit × 1024 真双口参数存储 |
| gamma_rom | 8-bit × 512，两页 identity 初始化，非校准结果 |
| geometry_mult | 有符号 25 × 18，带流水寄存 |
| bilinear_multadd | 两路 18 × 9 乘积相加，带流水寄存 |
| statistics_mac | 16 × 16 乘法，48-bit 累加 |

各 IP 均通过 `.idf` 原生加入工程并在自有 RTL 中实例化。PDS 统一综合时可正常优化未使用的端口、常量路径及原生内部逻辑，不把实例清单当作最终资源占用。

另外实例化 GTP 差分输入、全局/区域时钟缓冲、IOCLKDIV_E2 分频器、RGMII IDDR/ODDR 和 HDMI DDR10TO1 OSERDES/差分输出原语。本机目录没有可直接替代完整 Ethernet MAC/ARP/IPv4/UDP 或视频 TMDS 编码的同名原生模块，因此不虚构协议 IP。摄像头 SCCB/DVP、帧池 DMA、网络协议、完整 ISP、几何/倒数算法、视频时序与控制协议仍待实现。

## 已处理的问题

1. 旧 `.pds` 的手工语法风险：由当前安装版本原生生成 `_timespec`、IP 依赖及任务语法；直接调用原生 `.pds` 读取器进行构建。
2. PDS 转换/保存把实现目录写成 `.`：仅校正目录选项到 `../../build/pango_video_top`，不修改其余工程语法。
3. DDR 命令行 PAD 枚举不包含 MINI 板卡完整 CA 引脚。原生生成器还会把导入 FDC 的 LOC 再替换成 PAD 默认值，造成 DDR 与 HDMI/PHY 引脚和 Bank 电压冲突。主工程保留原生 DDR 时序、内部放置约束，单独加载已核对的板级引脚约束；没有改动原始资料或工具安装文件。
4. 根据 UG042003 第 2.8.5 节保留原生 `ddr3_controller.rcf` 两条优先布线约束。当前 PDS 只保留一个活动 RCF，因此在工程内派生 `constraints/routing.rcf`，原样合并 DDR 两条与 HDMI 复位四条命令；审计逐条检查 PDS 执行成功。未改写原生 DDR RCF，也未丢弃 DDR 约束。该约束本身不能修复第 7 项的专用级联输入误接。
5. 参数双口 RAM 的原生 18K 模式地址位宽门槛、PLL 分数分频与同步端口参数、OSERDES TI 端口位宽均在原生生成/编译反馈下修正。
6. PDS 在报错时可能返回 0。构建脚本额外检查日志、实际依赖、各阶段新鲜产物，禁止用退出码或历史位流冒充成功。
7. HDMI 从串行器的未使用 `OSHIFTIN0/1` 被接常量 0，PDS `Route-2014` 明确报告普通逻辑地无法布到这些专用级联引脚。先通过去串行器隔离构建完成布线，随后按 MINI 原生 `outputserdes.v` 的接法将这两个从串行器输入留空；主从之间真正使用的级联连接保持不变。完整失败定位日志保留在 `build/route_diagnostic/place_route/run.log`。
8. 取消自有控制/视频/网络时钟域之间的整域异步例外。依据 PDS UCE 手册第 2.2.4.1 节，对五个原生异步 FIFO 的两个灰码方向，仅源指针到第一级同步寄存器施加 `set_max_delay 6.0 -datapath_only`，小于最短参与时钟周期 6.667 ns；仅这些 CDC 第一级的 hold 检查被豁免，后续同步级和逻辑仍正常分析。状态观察量先在来源域寄存，再进入两级同步器，第一同步级采用同样有界约束。保留 IP 原生的 DDR 特殊时钟关系。
9. HDMI 串行时钟来自视频 PLL 唯一输出 371.25 MHz；像素时钟通过原生 `GTP_IOCLKDIV_E2` /5 得到，PDS 原生推导为 13.4680 ns 周期、5.3870 ns 高电平，父时钟为 `serial_clk`。显式区域时钟让本地释放寄存器与对应 I/O 共用支路，原生 `PAP_REGION` 与四条优先布线限制复位连线。先在串行域同步释放分频器，再经过三个像素周期的复位链及每通道本地像素上升沿释放寄存器。OSERDES 最终采用 MINI 原参考的 `ASYNC_RESET`，保留全部恢复/移除检查和 GRS。先前独立 PLL 输出、串行域释放、像素下降沿释放及同步数据复位方案没有全面闭合，已撤回；没有用时序例外掩盖这些路径。

## 通过结果与边界

八个原生任务的本轮产物均通过非空、时间新鲜性、日志错误与依赖审计；PDS 退出码 0，原生日志 error 0，审计 issues 为空。已核对 99 个管脚、15 个 IP 的器件/封装/速度等级与源码实例、六条 RCF 命令执行成功，以及像素时钟的真实父子关系和 40% 占空比。各输入 SHA-256 见 [input_manifest.json](../build/pango_video_top/input_manifest.json)。

已通过构建的最终 STA 最差裕量如下（ns，均为工具静态分析，不是实测）：

| 检查 | Slow corner | Fast corner | 违例端点 |
| --- | ---: | ---: | ---: |
| Setup | 1.133 | 2.084 | 0 |
| Hold | 0.158 | 0.101 | 0 |
| Recovery | 0.023 | 0.491 | 0 |
| Removal | 0.194 | 0.126 | 0 |

最小恢复裕量仅 0.023 ns。当前约束下通过不代表后续业务逻辑加入后仍然通过；更改布局、时钟、复位、IP 参数或 RTL 后必须重新完整构建。外部 IO 未签核，不能将 `All Constraints Met` 理解为整块板卡全部时序已经验证。

资源依据正式主工程 PDS 报告：Device Map 为 LUT 3653、FF 3527；布线后物理 CLMA/CLMS 表合计 LUT 3602（2565 + 1037）、FF 3527。布线后 APM 4/240、DRM 47/155、IO 99/300、GPLL 4/6、PPLL 2/6。PDS 模块层级表的 LUT 统计为 3601，本文明确区分其与物理表口径。这只是 IP 集成底座，不是完整视频应用的资源结果。

原生 IP 生成无告警，但主工程并非“零 warning”：该次 Compile 2923、Synthesize 3864、Device Map 31、Timing 127；PnR、网表、位流、功耗任务为 0。已分类核对原生 IP 通用源码中的参数裁剪、未使用端口/寄存器优化、专用未用端口断开，以及外部 IO 未设置输入/输出延迟的告警；未发现自有 RTL 的位宽/未驱动端口告警。完整日志保留，不通过改写生成 IP 消除厂商通用源码告警。功耗文件仅为默认活动率和工具模型下的估算，未进行功耗测量。

正式位流是 [pango_video_top.sbit](../build/pango_video_top/generate_bitstream/pango_video_top.sbit)，只保留在构建区，`release/` 未发布已批准烧录版本。最终复现：2026-09-10 12:47:06–12:51:46（Asia/Shanghai），执行 `build.ps1 -GenerateIps -LicenseFile <本机许可证路径>`；`all_result.json.passed=true`、`all_audit.json.flow_passed=true`。最终 `.sbit` 的 SHA-256：

```text
9f8154ff16ee63f8182761a2a02805f555475d4373e5aae7e9e5c1e76de2bb33
```

本轮更改范围仅 `fpga/`，包括替换用户已清空的旧工程/产物；其他开发区与规划文档不改动。FPGA 目录内的 `.gitattributes` 仅禁用相关输入/产物的换行转换，以保留原生字节与校验记录，不新增忽略项。根目录许可证不提交、不移动、不修改。既有备份脚本要求整个工作区干净；不通过调整忽略规则或隐藏许可证来绕过此检查。

## 参考与待签核项

只读查阅 PDS 安装目录 `doc/` 中的 PDS、IP Compiler、ADS、Timing Analyzer、Route Constraint Editor 手册，以及安装目录 IP 文档 `UG042003_Logos2_HMIC_S_IP.pdf`。DDR 参数种子及来源校验见 [config/ip_seeds/README.md](../config/ip_seeds/README.md)。

板卡交叉核对来源为 `reference/盘古100K200K MINI开发板/` 下硬件指导手册 V1.3（时钟、DDR、RGMII、HDMI、按键 LED）、`3_Hardware/FPGA管脚分配/mini-base管脚映射.xlsx` 的 `新底板` 工作表，以及 HDMI/RGMII 例程。读取表格用于核对 HDMI L5 管脚和共享复位，未修改原表。

烧录前仍须另行确认：实板版本与 DDR 颗粒/容量、DQS 极性、板级供电与 TMDS 电气适配、PHY 延时配置及 RGMII 两沿时序、外部 IO 输入输出延迟和完整 CDC 签核。本轮不编造未知 IO 延迟，不把静态功耗估计、时钟目标或工具编译结果称为实测成绩。PHY 保持复位，DDR 用户地址请求保持空闲，HDMI 仅输出空白符号；任何生成位流均不自动获准烧录。
