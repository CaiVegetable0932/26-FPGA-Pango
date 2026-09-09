# PDS IP 实例

| 实例目录 | PDS IP | 作用 | 当前状态 |
| --- | --- | --- | --- |
| `pll_100h/` | 28nm PLL 1.5 | 时钟域基线 | 已加入并由顶层调用 |
| `line_fifo_100h/` | DRM FIFO 1.10 | DVP/网络/处理有界队列候选 | 已加入并由顶层调用 |
| `line_ram_100h/` | DRM simple dual-port RAM 1.10 | 行缓存/小图块缓存候选 | 已加入并由顶层调用 |
| `ddr3_100h/` | Logos2 HMIC_S 1.10 | S0/S1/结果帧池外部 DDR 控制器候选 | 已加入 PDS 清单，待实物参数确认，暂不实例化 |

这些目录保留 PDS `.idf`、实例模板及生成 RTL，来源和重生成方式记录在 `fpga/project/pango_video_top/README.md`。PDS 工程通过 `add_design <instance>.idf` 加入 IP；不要把安装目录或 `reference/` 作为正式工程的运行时依赖。
