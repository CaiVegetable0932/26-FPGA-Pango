# RAW8 摄像头至HDMI链路分段诊断

## 输入证据与范围

56f6f4版本冷启动两次STATUS=0x11F、published=0，旧WORD故障未复现。
证据位于host/reports/raw8-clock84-cold-20260923/。现有状态不能区分DVP停止、
几何坏帧或DDR写入等待；不据此宣称摄像头正常出帧或HDMI解码故障。

## 本轮实现

raw8_dvp_monitor独立统计采样后的PCLK、VS下降沿、两个VS相位的HREF行数、
低VS相位最短/最长行宽；同时捕获实际capture FSM标志及拒绝/溢出计数。
源域192位数据从ACK起保持至下一个请求；目的域经两级ACK后取样，周期约8.39ms。
请求/应答第一同步级及held至快照总线仅施加针对性6ns datapath最大延迟与hold例外；
第二级及源域计算正常计时，没有切断整组异步时钟。两域复位沿用板端共同复位条件。
摄像头时钟停下时不制造新数据，进度快照保持旧值。

mem_clk页统计接受的START/END/WORD和实际原生W握手，连同capture/HDMI/writer FSM。
UART只读07/08/09由capability6控制，默认关闭保证旧顶层兼容；命令06与PHY05不变。
协议和host Inspect同步维护注释及解释。不同命令响应不是同帧配对证明。

此轮不改TMDS编码、灰度样本映射、摄像头寄存器、DDR地址、坏帧检查或帧池锁；
不增加测试图回退。目标是下次冷启动用实测位置驱动修正，不把诊断版当成修复完成。

## 参考与边界

只读查阅PDS 2022.2-SP6.4/doc/Timing_Analyzer_User_Guide.pdf第16页的min/max例外
报告说明，结合已有本版本FDC语法；后续必须通过原生STA及对象匹配检查。
只读OV5640_DataSheet.pdf第132页表7-18，VSYNC模式与HREF不能仅凭初始化ACK推断。
官方参考目录无写入。所有实现/报告在FPGA和host区；当前分支codex/fpga-raw8-dual-output。

## 已执行离线验证

- raw8_dual_sim_20260923_183615_520：新增monitor及原有启动/采集/帧池/调度/接口合同/双路像素全部通过。
- raw8_board_sim_20260923_183645_387：正常6发布、5HDMI、6网络8892包；late_epoch为6发布、5HDMI、5网络7410包，实际host重组逐字节校验通过。使用原生FIFO与行为HMIC，不是实际摄像头或DDR PHY验证。
- mcu_protocol_20260923_183644_978：完整及125MHz UART回归通过，07..09字段与epoch/session/长度门禁已测试。
- native_20260923_183957_206：PDS原生编译、综合、布局布线、快慢角STA及同一PNR数据库位流导出通过，All Constraints Met。报告能定位新增held至geometry路径，未见约束对象缺失；271项源文件/IP/约束审计通过。
- 发布38f81c2bcfc3：SHA256 38F81C2BCFC36431ABA413ABC431C5173488835D6DC4385BF05B56A75B5B7814；SBIT/SFC均3791112字节。旧56f6f4和317733恢复镜像已复核保留。

官方Fabric Configuration手册第85页提供cfg_reset_fpga软复位；新增独立受门禁脚本
只在Flash回读成功后调用一次。软复位成功不直接证明重新加载，须另由UART新capability6
及新诊断命令确认；更不替代断电冷启动测试。只读预检raw8_chain_probe_20260923确认
FPGA00602899、Flash0B4018，over_temp仍1保留，未更改热保护或安全位。

## 板端根因定位与下一项受控修改

38f81c2bcfc3已写Flash并回读校验：擦除12.8s、写入91.1s、校验31.5s。
cfg_reset_fpga后1.5秒的DONE=0只是加载中；随后CRC有效RAW8 boot ACK、CAPS=0x7F
和07..09均成功，确认新版本运行，无SRAM临时下载。软复位后运行不等于断电冷启动验收。
证据host/reports/raw8-chain-softreset-20260923/，epoch独立新生成。

两次实测几何一致：1920列、1086行、VS高电平0行，无溢出；START/END/WORD和W
持续增长，拒绝帧随VS增长，published=0，HDMI FSM=1等待帧。因此直接阻断是
1086输入行与1080严格合同不符，不是RAW数据缺少PC解码，也不是DDR完全没有写入。

数据手册第120–121页表7-13定义4004为BLC处理行数，当前为6。多出的6行与该值吻合，
但尚不足以证明行位置或来源。下一受控候选只将4004从06改00，保持RAW mux、
摄像头窗口/输出1080、FPGA几何检查、DDR与HDMI通路不变；不猜测裁剪首尾行、不填充。
启动测试断言实际SCCB与回读为00；物理行数及真实画面必须另测，不能用寄存器模型证明。
黑电平/颜色精度仍未校准。软复位脚本等待改10秒并仍以UART能力确认，不以延时作为启动证明。

## 2026-09-23 冷启动复核及1086行处理

4004=00候选0d8f0353b749已整片擦除、Flash写入、回读校验；配置状态DONE=1。用户确认彻底断电重新上电后，通过UART RAW8 Boot和Inspect再次读得每帧1086行、每行1920列、published=0、无溢出，与软复位结果一致。证据为host/reports/raw8-blc0-warm-20260923/cold-boot.json及cold-status.json。因此撤回4004=00试验，恢复4004=06基线。

下一候选令采集端严格验证1086条完整1920像素HREF行，但只将前1080行写入DDR并发布给HDMI/网络；其余6行不得写入、填充或发送。此为明确记录的临时裁切位置假设，尚未证明多余行处于尾部，也未完成真实图像验收。行数/行宽不符仍拒整帧。离线raw8_dual_sim_20260923_211030_910已通过严格和额外行测试，原生FIFO/HMIC行为模型的raw8_board_sim_20260923_211837_724通过6帧发布、HDMI5帧、网络6帧/8892包与主机逐字节重组，并通过late-epoch5帧/7410包。此结果不代表实际DDR PHY或物理输出验证。

用户新增硬件流程约束：此后每次Flash写入并回读校验后，必须请用户彻底断电并重新上电，收到“已冷启动”确认后才能进行任何新版板端测试；cfg_reset_fpga、UART应答及DONE=1不能替代此步骤。
