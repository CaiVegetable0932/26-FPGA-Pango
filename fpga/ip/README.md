# PDS 原生 IP

由 `config/ip_catalog.json` 和本机 PDS 2022.2-SP6.4 IP 目录生成。`prepare_ips.py` 只准备 IDF 参数输入及符号端口元数据；HDL、模板、源依赖清单、DDR 专用约束均由 `ip_generate -i ... -ads -disable-syn` 原生生成。独立 IP 综合关闭，统一在主工程 ADS 综合中处理全部实例。

候选配置共 15 个：系统 PLL、视频 PLL、DDR3 控制器及 PHY、RAW 异步 FIFO、网络发送 FIFO、显示 FIFO、DDR 写入位宽转换 FIFO、DDR 读出位宽转换 FIFO、ISP 行 RAM、Tile Cache RAM、参数双口 RAM、Gamma ROM、坐标乘法、插值双乘累加、统计乘累加。

原生调用的物理接口另外包括 GTP_INBUFDS、GTP_CLKBUFG、GTP_CLKBUFR、GTP_IOCLKDIV_E2、GTP_IDDR_E1、GTP_ODDR_E1、GTP_OSERDES_E2、GTP_OUTBUFDS。视频 PLL 仅输出 371.25 MHz，由原生区域 5 分频器产生同源 74.25 MHz 像素时钟（40% 占空比）；PDS 原生推导该时钟，再由审计核对父时钟、周期和波形。它们不是虚构的 Ethernet MAC 或 HDMI 协议 IP。ARP/IP/UDP、RAW 报文、TMDS 编码与视频时序、摄像头控制、完整 ISP、除法/倒数及几何算法仍属于后续 RTL 实现。

重建以 JSON 为参数权威；GUI 修改 IDF 后应先把参数同步回 JSON，避免下次重建覆盖。已存在的自动生成实例模板会移入 `build/ip_generation/template_archive/`，随后由 IP Compiler 重新生成，避免 PDS 跳过旧模板。

`example_design/`、原生 `_tb.v` 为工具伴随产物，不加入正式工程，也未运行。所有生成 IP 的实际源文件按各 `.idf` 的 `file_list/source/file/@pathname` 校验，不从目录通配收集示例或测试模块。

DDR 必须同时加载原生时序/内部放置约束和 `ddr3_controller/pnr/ddr3_controller.rcf` 优先布线约束（UG042003 第 2.8.4–2.8.5 节）。PDS 2022.2 只保留一个活动 RCF，故 `prepare_constraints.py` 保留该原文件，连同 HDMI 局部复位约束原样合并到 `constraints/routing.rcf` 后加入主工程；审计核对每条优先布线命令实际执行成功。主工程单独加载核对过的板级引脚 FDC；不能直接加入示例 `ddr_test.fdc` 的默认引脚。原生生成器会按 GUI 的 PAD 参数再次替换导入的引脚位置，因此命令行生成时不能把它生成的默认 IO 表当作 MINI 板卡引脚表。
