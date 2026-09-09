# `pango_video_top` 工程集成记录

日期：2026-09-09  
目标：Logos2 / PG2L100H / -6 / FBG676  
工具：PDS 2022.2-SP6.4 build 146967

## 已落地内容

- 在 `fpga/project/pango_video_top/` 建立 PDS 原生工程文件。
- 在 `fpga/scripts/build_video.tcl` 建立显式源文件、`.idf` IP、约束和流程动作的重建入口。
- 在 `fpga/scripts/build_video.ps1` 建立隔离构建目录和阶段标记判定；该脚本不会把 PDS 的错误返回码 0 当作成功。
- 加入并由顶层调用 PLL、异步 FIFO、双口 RAM；DDR3 HMIC_S 1.10 已加入 PDS IP 清单，等待 MINI 实物 DDR 参数核对后再实例化。
- 复制的 IP 仅保留 `.idf`、模板、生成 RTL 和 IP 必需依赖；没有复制参考工程的历史 PNR、位流或数据库结果。

## 实际检查

| 检查 | 结果 |
| --- | --- |
| 4 个 IDF 的器件/封装/速度等级 | 通过：均为 PG2L100H / FBG676 / -6 |
| IDF source 文件存在性 | 通过：4/4，缺失 0 |
| 工程源、约束、IP 相对路径 | 通过：全部位于 `fpga/` 开发区 |
| PDS 版本 | 通过：2022.2-SP6.4 build 146967 |
| PDS 原生批处理入口 | 已调用，未进入 compile 阶段 |
| PDS 编译/综合/布局布线/位流 | 未通过：License 阻断，尚未执行 |
| 硬件、DDR、HDMI、RGMII、OV5640 | 未执行 |

## 阻断证据

执行 `fpga/scripts/build_video.ps1 -OutDir fpga/build/pango_video_top_20260909_c` 的结果：PDS 进程返回码为 0，但输出包含 `Flow-0183`、`Check license failed`；包装脚本将 `license_blocked=true`、所有阶段标记为 false，并以非零状态结束。IP Generator 的独立探针同样返回 `IPCompiler 0009`，因此没有在本机重新生成覆盖 IP 实例。

下一步只需提供有效的 PDS/IP Compiler License（不修改工程脚本即可），重新运行该入口；首次通过后再按实际 MINI DDR 颗粒、容量、管脚和 HDMI/RGMII 资料更新 IP 与约束。本记录不代表视频功能、综合、位流或上板验证已经完成。
