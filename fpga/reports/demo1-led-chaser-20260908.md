# demo1 五路流水灯离线验证报告

日期：2026-09-08。项目：`D:/XDU/concept/26-FPGA-Pango-test/demo1`。

**已完成 Verilog、管脚约束、功能仿真、综合、布局布线、静态时序分析和位流生成；没有烧录或上板。** 正式速度的 RTL、综合后和布线后网表均通过真实分频周期测试。SDF 回标成功且功能比较通过，但存在厂商模型时序检查告警，严格 SDF 验收仍受限。

## 实现与引脚

目标为 **PG2L100H / -6 / FBG676**，核心板 D18 输入 27 MHz。LED0→LED1→LED2→LED3→LED4→LED0，每 **13,500,000** 个时钟换灯，即每灯 0.5 秒、一圈 2.5 秒。KEY0（C22，低有效）经两级同步后复位到 LED0；计数与灯状态使用同一时钟。LED 高有效，LVCMOS33、3.3 V、8 mA、慢沿。

| 输出 | LED0 | LED1 | LED2 | LED3 | LED4 |
| --- | --- | --- | --- | --- | --- |
| 引脚 | A20 | C18 | C19 | E18 | A17 |

按用户确认采用 **5 路可编程用户 LED**。板卡管脚表与硬件手册第 35 页电路图均列出 5 路；旧例程有 8 路，其额外 A18/C17/B17 在管脚表中为 N/A，未使用。手册文字表将 LED1/LED2 对调，本项目采用管脚表与旧例程一致的 C18/C19。电源、网口等状态灯不作为可编程流水灯。实物版本和连通性未测量。

## 实际验证结果

| 环节 | 结果与覆盖 |
| --- | --- |
| 工具与许可证 | PDS 2022.2-SP6.4 build 146967、ModelSim SE-64 10.1c；实际综合成功 |
| Verilog 编译与参数边界 | 通过；1 灯/1 周期、5 灯/1 周期、5 灯/3 周期，含复位、回绕 |
| 正式 RTL 功能仿真 | 通过；6 次真实 13,500,000 周期换灯，检查切换前后边界、完整循环和复位，约 3 秒仿真时间 |
| 正式综合后功能仿真 | 通过；同一真实周期测试，不强制修改计数器 |
| 正式布线后功能仿真 | 通过；同一真实周期测试，不强制修改计数器 |
| 综合、映射、布局布线 | 通过；新目录实际运行，检查错误、阶段完成标记和产物 |
| 正式静态时序分析 | 通过；27 MHz，快/慢角 setup、hold 四组均无违例端点 |
| 快速配置 RTL、综合后、布线后仿真 | 全部通过；每项 722 次比较、43 次状态变化，覆盖全部 5 灯及中途复位 |
| 快速配置 SDF min/max | 回标成功、每项 722 次功能比较通过；严格时序检查受模型告警限制 |
| 位流、网表、SDF、功耗报告 | 已生成；功耗仅为默认活动率估算，非实测 |
| 证据一致性 | 正式 RTL/约束、仿真输入、网表/SDF、发布位流的 SHA-256 关联检查通过 |
| 硬件烧录与实测 | 未执行 |

正式配置资源：**31 LUT、31 FF，0 DRM、0 APM**。最差 setup 裕量 **34.482 ns**，最差 hold 裕量 **0.229 ns**；四组时序检查各覆盖 48 个端点，违例端点均为 0。

## 保留的限制与修正记录

- `rstn` 是异步输入，仅从端口到首级同步器设置 false path；LED 无同步外部接收器，输出设置 false path。内部路径正常计时。PDS 的 Timing-4086/4087 提示保留，不能称为“所有 I/O 均有同步延迟约束”。
- SDF min/max 均出现 **vsim-8756**：官方 `V_FFSYN.v` 对负时序检查值缺少延迟参考/数据副本。未修改模型、未屏蔽告警，因此不能报告严格门级时序仿真完全通过；时序合格结论依据本次四组 STA。后续可向厂商核对兼容模型/仿真器组合。
- 综合的 `Loop was found during constant probe` 和仿真库的宏重定义提示保留。RTL 是寄存器反馈，无组合环；正式综合后、布线后功能测试均通过。
- 已修正仿真信号优化导致波形不可记录、看门狗大整数提示，以及 PDS 文件级加速宏未改变综合网表参数的问题。加速配置改为显式参数测试顶层，独立重建后验证通过。早期失败日志保留于 `build/rtl_production`、`build/gate_fast` 等目录，不计入通过结果。
- 正式 0.5 秒配置与 16 周期快速配置分别构建；快速配置仅供后仿，没有作为正式发布位流。各环节已逐步执行；一键入口另完成语法与参数检查，未再完整重复一遍所有环节。

## 代码、产物与复现

全部实现及产物保留于新空间 `demo1/fpga/`：`rtl`、`constraints`、`config`、`sim`、`scripts`、`project`、`build`、`release`、`reference`、`reports`。没有把实现放入 `output/` 或项目根目录。

- [工程与复现说明](D:/XDU/concept/26-FPGA-Pango-test/demo1/fpga/README.md)
- [Verilog 核心](D:/XDU/concept/26-FPGA-Pango-test/demo1/fpga/rtl/led_chaser.v)；[板级顶层](D:/XDU/concept/26-FPGA-Pango-test/demo1/fpga/rtl/led_chaser_top.v)；[管脚约束](D:/XDU/concept/26-FPGA-Pango-test/demo1/fpga/constraints/mini_100k.fdc)
- [正常速度 PDS 工程](D:/XDU/concept/26-FPGA-Pango-test/demo1/fpga/build/production/demo1.pds)
- [本次机器结果](D:/XDU/concept/26-FPGA-Pango-test/demo1/fpga/build/summary.json)，原始日志及波形位于各测试目录
- [正常速度位流](D:/XDU/concept/26-FPGA-Pango-test/demo1/fpga/release/demo1_led5_27MHz_500ms.sbit)，**3,791,112 bytes**；[发布清单](D:/XDU/concept/26-FPGA-Pango-test/demo1/fpga/release/manifest.json)

位流 SHA-256：`9d4883bdde2e096c1e8dd5ec0ccc955c35f51b4057b364ea17021c569b62b429`。

在 demo1 目录运行 `.\fpga\scripts\run.ps1`，会创建新构建目录并执行离线流程；不会访问下载器。严格 SDF 告警会使最终返回非零，具体功能/时序结果分别见 JSON。

## 依据与保存范围

参考原项目已验证工具脚本，来源分支 `codex/mcu-test-system`、读取时提交 `d33b7b36e40b0b4ab7ef525cc2faf2d3555bce1d`。板卡依据为 MINI 硬件手册 V1.3（第 6、12～14、34～35 页）、`mini-base管脚映射.xlsx` 和 2_7 按键 LED 例程。安装版 PDS User Guide 第 248、250、255 页通过页面查看核对；官方目录全程只读。详细来源、单元格与冲突处理见 [SOURCES.md](D:/XDU/concept/26-FPGA-Pango-test/demo1/fpga/reference/SOURCES.md)。

按用户要求，**新空间不提交或推送；仅此报告纳入原项目 Git**。代码、日志和位流的上述链接是本机路径，云端只有报告。原项目已有未跟踪文件 `reference.zip` 保持原样，未纳入本次提交。
