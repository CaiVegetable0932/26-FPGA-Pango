# FPGA 开发区

这里直接开发 PG2L100H FPGA 本体相关实现。当前仅建立目录骨架，尚无正式 RTL 工程。

| 目录 | 内容 |
| --- | --- |
| `rtl/` | 视频输入、ISP、几何变换、帧缓存、控制接口等 RTL |
| `ip/` | IP 配置、必要生成源码、依赖及来源说明 |
| `constraints/` | 管脚和时序约束 |
| `config/` | 器件、板卡、工具和源文件配置 |
| `project/` | PDS 工程及工程重建入口 |
| `sim/` | Testbench、仿真输入和预期结果 |
| `model/` | 浮点和位精确算法参考模型 |
| `scripts/` | 仿真、综合、布局布线、位流生成及下载脚本 |
| `build/` | 本开发区的构建结果和中间文件 |
| `reports/` | 仿真、资源、时序及 FPGA 实测报告 |
| `release/` | 阶段位流、配置、版本与校验记录 |

需求、设计和计划写在 [output](../output/README.md)，实现和生成结果写在本目录。云台、电机与光照设备端控制写在 [mcu](../mcu/README.md)，PC 上位机及测评软件写在 [host](../host/README.md)。在项目根目录打开 VS Code，PDS 引用本目录同一份源码。

旧开发方案中的 `rtl/`、`ip/`、`sim/`、`model/`、`constraints/`、`config/`、`build/` 等 FPGA 路径，现统一加 `fpga/` 前缀。本区脚本应根据自身位置解析路径，避免依赖终端当前目录。

所有子目录均受当前 Git 规则管理；`.gitkeep` 只用于保留空目录，可在添加实际文件后移除。
