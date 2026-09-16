# 2026-09-10 PG2L100H 过温报警离线排查

## 结论与边界

本次只查阅本机 PDS 2022.2-SP6.4 build 146967 手册、默认库、MINI 板参考资料及已有构建/下载日志；没有连接硬件、重新下载、修改阈值或解除下载暂停。以下是默认值与离线证据，不是板上温度或寄存器实测。

**Logos2 ADC 默认 OT 阈值为 125°C，解除阈值为 50°C，触发约有 10 ms 去抖。实际板上阈值尚未读回，不能由 over_temp=1 单独证明当时真实结温达到 125°C。**

## 阈值与使能

| 项目 | 依据及结果 |
| --- | --- |
| 状态位 | 安装版 Fabric Configuration 手册 §5.2.3，PDF 101–102 页：Logos2 的 bit 27 为 over_temp；不是 Logos 的 bit 29。 |
| OT 触发阈值 | GTP_ADC_E2 的 CREG_2AH 默认 12'hCC2；对应 125°C。 |
| OT 解除阈值 | GTP_ADC_E2 的 CREG_2BH 默认 12'hA5B；对应 50°C，具有滞回，降到 125°C 以下并不立即解除。 |
| 阈值寄存器含义 | 安装版 Fabric Debugger 手册 §5.9.2，PDF 62–63 页：Alm_2Ah 是 OT alarm limit，Alm_2Bh 是 OT alarm reset。 |
| ADC OT 使能 | 原语 CREG_00H 默认 16'h0001；安装版 Debugger 手册 PDF 60 页说明 bit 0 为 OT 高有效使能。原语默认不等于已读取板上配置。 |
| 一般温度报警 | ALARM[0] 使用 0x20/0x21；与 OT 的 0x2A/0x2B 分开，不能混用。 |
| 过温自动关断 | 安装版 PDS User Guide PDF 152 页说明 Over Temperature Shut Off 默认不勾选；目标器件 Logos2-PG2L100H.ini 第 69 行默认 disable，第 181–182 行映射 ctrl0_data[22]。工程 PDS 配置中未找到显式覆盖，但本次未解码位流/读回控制寄存器，不能将其写成板上已核实值。 |

码值到摄氏度的关系为 T = code × 0.1219 − 273.15；0xCC2 和 0xA5B 分别约为 124.96°C、50.01°C。厂商《UG040009 Logos2 ADC User Guide》V1.6，第 14–15 页明确给出 125°C/50°C 默认值、滞回和约 10 ms 去抖。本机默认码值与其一致。该在线手册是补充交叉核对，不冒充安装版随附文件；官网 PDF 直接下载失败，阈值和相关段落由搜索工具检索到的官方原文核对，未声称完成在线 PDF 视觉复核。

[厂商 ADC 指南 V1.6](https://www.pangomicro.com/en/uploads/48016937_1729131871.pdf)

## 已有事件证据

- [下载日志](../build/board_validation_20260910/jtag/log/jtagserver.log)第 133 行：21:18:35 状态十进制 135330944，即 0x0810FC80，bit 27 为 1。
- [先前只读探测](../build/board_validation_20260910/jtag/probe_console.log)：下载前 bit 27 为 0。
- 报警状态在 21:18:37 开始回读校验之前已记录，不能把后续长时间回读当成首次置位的原因；后续持续运行是否增加温升没有测量依据。
- 没有 ADC 当前温度、峰值、实际阈值、板端电压或输入电流记录。状态位支持保留报警，但不足以区分真实过热与采样/配置/读取异常。

## 优先排查的可能原因

### 1. 散热条件与功耗估算假设不一致

[实际下载版本的功耗估算](../build/board_validation_20260910/workspace/fpga/build/pango_video_top/report_power/pango_video_top.ppf)使用环境 25°C、Medium 风量、Medium 散热片、热阻 7.92°C/W，估算芯片总功耗 4.067 W、结温 57.131°C。IO 估算 2.582 W（约 63.5%），PLL 0.713 W，静态 0.376 W。

这些均为工具估算，不是实测。若实际无风扇、散热片接触不良或环境更热，57.1°C 不能用于排除过温。按固定 4.067 W 作粗略敏感性计算，25°C 环境升至 125°C 对应约 24.6°C/W；这不是对当前板卡热阻或稳态温度的测量，功耗本身也会随温度和活动变化。

### 2. 无视频业务仍有时钟与 IO 活动

[集成顶层](../rtl/board/pango_video_top.v)开启系统/处理/发送时钟，并产生 371.25 MHz HDMI 串行时钟与 74.25 MHz 像素时钟，持续发送固定 TMDS 符号；DDR 控制器自身接板级复位，不因 AXI 地址 valid=0 就保持整体复位。初始化、校准及刷新是否实际成功尚未验证。网口外部 PHY 被复位，不等于 DDR PHY 被复位。

[IP 集成模块](../rtl/memory/ip_integration_bank.v)中部分运算 CE 固定为 1；是否产生明显动态活动仍取决于输入与综合结果，不能直接当成高负载证据。上述设计可解释下载后功耗增加，但尚不能单独解释 125°C 报警。

### 3. 供电、IO 电压或负载异常

MINI 硬件 V1.3 第 41 页要求底板电源输入 +12V；底板转换出 +5V 给核心板。J20/J24 会影响 BANK_L6/L7 的供电选择，应核对实物跳线和所接电源入口，不能把底板 +12V 要求套到核心板 +5V 入口。

目标 FPGA 数据手册 DS04001 V1.5 第 17 页：VCC/VCC_DRM 推荐 0.95–1.05 V，VCCA 推荐 1.71–1.89 V。工程 DDR IO 为 1.5 V，RGMII 等为 3.3 V；是否与实物各 Bank 电压一致仍需测量。过压、供电异常、IO 争用或终端负载异常都是待排查项，当前没有证据确认其中某项发生。

### 4. ADC 阈值、校准或状态读取异常

自有 RTL、配置及工程中未发现 GTP_ADC_E2 的用户实例或 CREG_2AH/2BH 覆盖，也未发现用户逻辑访问 ADC 的路径；这不能证明未实例化 ADC 时片上所有寄存器必然保持原语默认值。需要读回 ADC 控制/阈值/采样结果才能判断。

DS04001 V1.5 第 38 页给出温度检测精度：−40°C 至 100°C 为 ±4°C，100°C 至 125°C 为 ±6°C；并注明 -5 不支持温度传感器。本项目目标 -6，不能用 -5 的限制直接否定报警。传感器有效性、模拟电源、校准数据与 JTAG 读值稳定性仍需验证。

## 后续最小取证集合（本次未执行）

在原上板暂停条件处理后，以受控短时测量核对：

1. 实际供电、输入电流、散热片/风扇状态；同时区分芯片表面温度与片上结温。
2. ADC 0x00（使能/模式）、0x2A/0x2B（OT 阈值）、0x20/0x21（一般温度报警阈值）。
3. ADC 0x40 当前温度、0x65 历史最高温、0x6A 历史最低温；0x41–0x44 为芯片各电源转换值。寄存器位置来自安装版 Debugger PDF 67–68 页，转换码的有效位与读取协议需按对应指南核对后使用。
4. 对照状态寄存器 bit 27；必要时与受控低活动率诊断设计比较温升。避免重新加载当前集成位流来反复复现报警，也不以抬高阈值或屏蔽报警替代排查。

## 本地来源

- `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Fabric_Configuration_User_Guide.pdf`
- `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Fabric_Debugger_User_Guide.pdf`
- `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Pango_Design_Suite_User_Guide.pdf`
- `E:/PDS_Pangu/PDS_2022.2-SP6.4/arch/vendor/pango/logos2/common/lib/gtp_lib.v` 第 10–36 行。
- `E:/PDS_Pangu/PDS_2022.2-SP6.4/arch/vendor/pango/logos2/pg2l100h/data/config/ini_data/Logos2-PG2L100H.ini`
- `reference/盘古100K200K MINI开发板/4_IC_datasheet/FPGA/DS04001_Logos2系列FPGA器件数据手册.pdf`
- `fpga/build/board_validation_20260910/manuals/MINI_Hardware_V1.3.pdf`（已有板卡手册副本）。

官方和原始参考文件均未修改。现有硬件暂停记录与下载入口保持原状。
