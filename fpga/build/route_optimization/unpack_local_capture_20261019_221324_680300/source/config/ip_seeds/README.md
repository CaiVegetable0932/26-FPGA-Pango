# 只读来源的项目内副本

`ddr3_100h_profile.idf` 原始来源：

`reference/OV5640双目摄像头资料/实验例程4-基于100Pro+开发板/FMC+双目Demo/2_Demo/HDMI_DDR3_OV5640_100H/ipcore/ddr3_test/ddr3_test.idf`

仅复制参数种子，原始参考文件未修改。生成时使用当前安装的 PDS 2022.2-SP6.4 IP Compiler，重新生成全部控制器/PHY HDL；不复制旧生成 HDL。种子目标为 PG2L100H / FBG676 / -6，DDR3 32-bit / 1000 MT/s / 125 MHz reference / 256-bit UI。

种子并非 MINI 板的接线权威。实际 MINI 引脚来自硬件指导手册 V1.3，在 `board.json` 中记录，通过原生 `USER_PINS_CON_EN` / `USER_FDC_PATH` 导入。不过当前版本的 `createFiles.tcl` 仍会把导入文件的 LOC 替换成 PAD 参数，无界面模式的动态枚举不能可靠恢复 GUI 选项。因而主工程仅采用生成文件中的专用时序和布局部分，引脚单独加载 `constraints/ddr_board_pins.fdc`，不加载默认 PAD 生成的位置。不得把 `ip/ddr3_controller/pnr/ddr_test.fdc` 整份再次加入主工程。

更换目标板必须重新核对器件、DQS 分组/极性、封装、存储器参数和电源，不能沿用本副本作为已通过硬件测试的依据。

复制后的种子仅作为配置数据，不直接加入 PDS 工程。实际 PDS 工程不引用被 Git 忽略的 `reference/` 或 `PDS/`。
