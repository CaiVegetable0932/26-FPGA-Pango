# Pango 原生 RGMII TX 单元仿真报告（2026-09-21）

结论：`pango_rgmii_tx` 已使用安装版官方 `GTP_ODDR_E1`、`GTP_GRS` 模型在 ModelSim 中运行并通过自检。共完成 3,072 个完整字节/控制组合、56,080 次检查，错误为 0。这是原生 GTP 功能仿真结果，尚未板级签核。

## 文件与集成合同

工作树：`C:/Users/ROG/.codex/worktrees/fpga-camera-main-publish/26-FPGA-Pango`；分支：`codex/fpga-mcu-praw-protocol`。

本项源码与报告仅涉及四个指定文件，运行产物另存 `fpga/build/rgmii_tx_*`：

- [RTL](../rtl/network/pango_rgmii_tx.v)
- [自检 Testbench](../sim/tb_pango_rgmii_tx.sv)
- [ModelSim 运行脚本](../scripts/sim_pango_rgmii_tx.ps1)
- 本报告

模块名 `pango_rgmii_tx`，无可配置参数，无握手或背压，工作在固定 125 MHz 的千兆发送模式。

| 端口 | 方向/位宽 | 合同 |
| --- | --- | --- |
| `clk125` | 输入 1 | GMII 采样及数据/CTL ODDR 时钟，周期 8 ns |
| `clk125_90` | 输入 1 | 板级 PLL 提供，与 `clk125` 同源、同频，边沿滞后 2 ns |
| `reset_n` | 输入 1 | 低有效异步复位；PLL 锁定后须对两个时钟安全释放 |
| `gmii_data` | 输入 8 | 在 `clk125` 上升沿满足建立/保持要求的完整字节 |
| `gmii_en` | 输入 1 | 同拍 TX_EN |
| `gmii_error` | 输入 1 | 同拍 TX_ER |
| `rgmii_txc` | 输出 1 | 由 `clk125_90` ODDR 的 D0=1、D1=0 前推 |
| `rgmii_ctl` | 输出 1 | 上升沿发 EN，下降沿发 EN XOR ER |
| `rgmii_data` | 输出 4 | 上升沿发字节低半，下降沿发字节高半 |

数据及 CTL 使用 `GTP_ODDR_E1` 的 `SAME_EDGE`、`GRS_EN="TRUE"`、`RS_TYPE="ASYNC_RESET"`、CE=1；四个数据原语加一个 CTL 原语、一个 TXC 原语，共六个实例。复位连接原语 RS，清除内部流水；不在输出端增加组合时钟门控。

安装版官方模型的 SAME_EDGE 具有一拍延迟：在第 N 个 `clk125` 上升沿采样的输入字节/EN/ER，从第 N+1 个上升沿及其后的下降沿输出。两半使用同一次采样，数据与 CTL 延迟一致。TXC 在复位释放后同样需要原语流水填充，首个 `clk125_90` 上升沿仍输出 0，第二个上升沿开始完整时钟脉冲；自检没有跳过这些启动周期。

与当前 MAC 端命名对接：`gmii_txd -> gmii_data`、`gmii_tx_en -> gmii_en`、`gmii_tx_er -> gmii_error`；适配器 `rgmii_ctl -> rgmii_tx_ctl`、`rgmii_data -> rgmii_txd`。

## 只读参考与模型来源

已阅读本机安装版 [Simulation_User_Guide.pdf](E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Simulation_User_Guide.pdf)，V1.0（2022-07-12）。采用第 1/2 节与 2.1 节的 GTP 前仿/`usim` 定义（印刷页 5-6），第 3.1 节的编译库输出位置设置（页 7-8），第 3.3 节的编译、展开与运行选项（页 11-14），以及第 4.2 节对功能仿真、综合后仿真和 PNR/SDF 时序仿真的区分（页 17-20）。本次只编译本单元实际依赖的两个 GTP，不声称完成全器件库编译。

MINI 参考原始文件：`D:/XDU/concept/26-FPGA-Pango/reference/盘古100K200K MINI开发板/2_Demo/2_11_ethernet_test/2_11_ethernet_test/source/rgmii_interface.v`。只借鉴 Pango 原生 SAME_EDGE ODDR 的低半 D0/高半 D1 接法及 CTL 双沿编码形式；此处将 ER 接入真实输入。没有复制其固定 IODELAY tap、RX 逻辑或板级 IO 属性。工作树 `fpga/config/board.json` 的目标为 `MES2L676-100HP-MINI / PG2L100H-6IFBG676`；单元本身不分配封装管脚，也不实例化 PLL。

官方模型根目录：`E:/PDS_Pangu/PDS_2022.2-SP6.4/arch/vendor/pango/verilog/simulation`。

| 直接编译的官方文件 | SHA-256 |
| --- | --- |
| `GTP_ODDR_E1.v` | `0FACD3433414CA667B27DFB15817151D433468E32440880E3C4855BEDC932705` |
| `GTP_GRS.v` | `DAE720BCC467DDB4FF99F2753368934E2649B87F6AC63B8A0D7219699BAC1DEC` |

Testbench 实例化官方 `GTP_GRS GRS_INST`，满足 ODDR 对 `GRS_INST.GRSNET` 的层次引用。没有自制 stub，没有复制、上传官方完整模型。编译前后官方文件 SHA-256 相同；指南、MINI 参考和模型原目录均未写入。

## 自检范围与实际结果

每轮连续发送 256 种字节与 4 种 EN/ER 组合，共 1,024 个向量。共三轮：初次启动、本地复位恢复、独立 GRS 复位恢复。每轮的每个组合都必须恰好检查一次，共 3,072 个完整向量。

独立记分板只观察 GMII 输入和 RGMII 输出，按固定一拍延迟检查低半、高半、EN、EN XOR ER，并由实际 CTL 两沿反解 ER。每次输入上升沿采样后 0.5 ns，激励故意反转整个字节和 EN，检验后续高半/CTL 不受本拍后续输入变化影响，避免仅用长时间不变的字节掩盖 SAME_EDGE 接法错误。

本地异步复位分别在 `clk125` 上升沿后的 0.7、2.7、4.7、6.7 ns 断言，覆盖两路时钟的四种电平区间，复位前用有效全 1 数据填充流水。另单独拉低 GRS，保持本地复位释放，验证官方全局复位路径。检查异步清零、保持复位期间输出及释放后的每个流水周期。功能仿真中的安全释放不能替代物理复位恢复/移除时序检查。

TXC 检查包括每个预期边沿的输出电平、实际输出边沿相对数据发射边沿滞后 2 ns、8 ns 周期和 4 ns 高电平宽度。所有比较采用四态检查，X/Z 会失败；设有 100 us 仿真超时，缺少完整结果、PASS 或官方模型加载证据都会使运行器返回失败。

最终通过目录：[rgmii_tx_20260921_224840_640](../build/rgmii_tx_20260921_224840_640)。完成时间：2026-09-21 22:48:44 +08:00。

| 项目 | 实际结果 |
| --- | --- |
| 仿真器 | ModelSim SE-64 10.1c，`E:/ModelsimSE/win64` |
| 原生模型安装版本 | PDS 2022.2-SP6.4 |
| 运行精度 | 1 ps |
| 完整组合 | 3,072 / 3,072 |
| 自检次数 / 错误 | 56,080 / 0 |
| 本地复位相位 / 独立 GRS 复位 | 4 / 1 |
| 实际 TXC 上升沿 / 正常下降沿计数 | 3,113 / 3,109 |
| 模拟结束时间 | 25.0242 us |
| 脚本退出码 | 0 |
| 官方模型文件前后哈希 | 相同 |

正常下降沿计数排除复位强制截断的脉冲；结束时尚未到达最后一个下降沿，因此两类边沿总数不要求相等。每个正常脉冲的高电平宽度及连续上升沿周期单独检查。

通过证据：[result.json](../build/rgmii_tx_20260921_224840_640/result.json)、[simulation.log](../build/rgmii_tx_20260921_224840_640/simulation.log)、[compile_native.log](../build/rgmii_tx_20260921_224840_640/compile_native.log)、[波形](../build/rgmii_tx_20260921_224840_640/rgmii_tx.wlf)。结果 JSON 还记录 RTL、Testbench 和运行脚本的 SHA-256。

日志明确含有 `Loading usim.GTP_GRS`、`Loading usim.GTP_ODDR_E1` 和 `RGMII_TX_PASS`。运行脚本使用 `-novopt` 保留原语实例可见性，并在运行目录的真实 `run.do` 中设置错误处理。

保留首轮 [rgmii_tx_20260921_224742_473/result.json](../build/rgmii_tx_20260921_224742_473/result.json) 作为调试记录：功能计分同样为零错误，但优化将 ODDR 内联，缺少独立加载记录，严格来源核验使该轮 `passed=false`。最终通过依据为上述关闭优化后的完整重跑，不把首轮标为总体通过。

## 复现与验证边界

在工作树根目录用 PowerShell 7 运行：

```powershell
pwsh -NoProfile -File ./fpga/scripts/sim_pango_rgmii_tx.ps1
```

脚本支持 `-ModelSimHome` 和 `-PdsHome` 覆盖；源码和输出根目录从脚本自身位置解析。每次建立新的 `fpga/build/rgmii_tx_<时间戳>`，`vlib` 的 `work/usim`、本地 `modelsim.ini`、日志、命令宏、波形与 JSON 全部位于该目录。结束时恢复调用方进程的 `MODELSIM` 环境变量。

本项没有执行 PDS 综合、布局布线、IO/时钟约束或 SDF 检查；顶层 `fpga_comms_top` 的原生 PDS 综合由主 agent 单独处理。原生可综合原语实现及 ModelSim 编译通过，不等同于顶层综合完成或物理时序签核。本项没有创建/启用物理管脚或板级 PLL，没有修改其他开发文件，没有 commit/push，也没有烧录。

板级接入前必须共同核对 RTL8211F 的 TXID strap/寄存器实际状态、板级 PLL 的外部时钟相位方向、PCB 时钟/数据偏斜及对应约束，避免 FPGA 已有 2 ns 相移后 PHY 再次增加 TX 延迟。`clk125_90` 的合同是滞后 2 ns，不能仅凭 PLL 参数中的“90”推断方向。本次未验证 RTL8211F 配置或引脚到引脚的建立/保持裕量，尚未板级签核。

本报告也不表示 PHY 链路、MAC 帧/FCS、真实千兆吞吐、摄像头源帧率或 10/100 Mb/s 模式已经验收；这些不在本单元范围内。
