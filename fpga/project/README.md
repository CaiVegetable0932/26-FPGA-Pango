# 最小离线 PDS 工程

`../scripts/build.tcl` 是完整工程重建入口，显式导入 RTL、约束和 testbench。PDS 自动在每次指定的新 `fpga/build/` 目录中生成 `flow_smoke.pds`，可直接打开查看。正式构建不依赖根目录 `reference/` 或 `PDS/` 中的任何源码、数据库或位流。

目标为 Logos2 / PG2L100H / -6 / FBG676，工具为 PDS 2022.2-SP6.4 build 146967。板卡型号、时钟和引脚的资料核对见 `../config/board.json`。实物 PCB 版本与供电没有测量，本工程不作为上板发布。

设计参考来自 `reference/盘古100K200K MINI开发板/2_Demo/2_7_key_led_test/2_7_key_led_test/source/key_led_test.v` 及同目录 `.fdc`。本次重新实现单 LED 的 32 周期分频与按键使能，使用两个两级同步器和端口级自检；没有复制参考目录中的历史工程结果。单 LED 选择避免沿用示例与硬件手册不一致的 LED1/LED2 编号。

PDS Tcl 命令依据只读安装资料 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc` 内的 User Guide、Simulation Guide、Timing Analyzer、UCE 和 ADS Synthesis 手册。仿真库由本次安装工具生成，其生成脚本、日志、版本和前后仿用例均保留在 `fpga/build/`；没有更改厂商模型。

已确认的限制：ModelSim 10.1c 与官方 V_FFSYN 模型在 SDF 负时序检查处出现 vsim-8756；回标和功能比较完成，但严格后仿状态保留为未通过。后续应向厂商确认支持的模型/仿真器组合。不得用关闭时序检查、屏蔽告警或改写原模型制造通过结论。
