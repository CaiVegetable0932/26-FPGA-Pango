# 原生路由选项补充证据

2026-10-14；仅补充安装版集成帮助与原生选项核查。本次没有启动PDS/PnR、修改RTL/FDC/工程或停止任务。此前失败/布线进度分析不在此重复。

## 新增安装帮助来源

只读核查 `E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/configurehelp.xml`，其Place & Route入口明确指向 `Pango_Design_Suite_User_Guide.htm#Place_Route_settings`。使用SQLite `mode=ro&immutable=1`读取同安装目录 `helpDoc_pango.qch`，没有生成journal或向安装目录写入。扫描18份HTML正文（排除style/script/head）没有effort、router_effort、routing_effort、4022文字命中。

PDS用户指南是FileId556；原始HTML有效UTF-8，中文和√完整。曾出现的乱码来自未转义工具输出显示，已经用ASCII转义码点复核，不能归因于官方源损坏。其独立来源再次明示：PG2L100H是单线程器件，General/Router按Logos列。集成帮助与官方PDF参数表一致，没有额外独立routing effort字段。

来源SHA：QCH=`ca2d9a07db35d49fbf9bb582200845e6f32430798fade1b40506bfab7640e577`；指南HTML=`b2bd0a9d04ba7131f156c1cb5f69042000606c15b9ab6a026c85b2e9208eb330`。文件名、码点/参数行及检索范围见同目录 `installed_router_help_supplement_20261014.json`。这项负面检索只覆盖公开正文，不声称工具内部不存在未公开参数。

## 明确适用与限制

结合官方PDF印刷p109、p113、p117–119及已保存2022.2-SP6.4/build146967 `pnr -help`语法记录，PG2L100H明确可核对以下设置：

| 原生选项 | 官方含义/适用性 | 已说明的默认值 |
|---|---|---|
| `-mode fast/normal/performance` | General的整个PnR运行模式；performance偏重性能且用时较长。不是独立详细router effort参数 | normal |
| `-slack_weight` | 路由过程时序因素权重，整数语法 | 90 |
| `-pin_cost_increasing_speed` | 拥塞端口代价值增长速度，整数语法 | 300 |
| `-congest_overlap_limit` | 拥塞模式最大迭代次数，整数语法 | 200 |
| `-fast_router TRUE/FALSE` | 是否使用全局布线 | TRUE |
| `-slack_prior_in_global_router TRUE/FALSE` | 官方称控制布线优先全局布线器，依赖fast_router开启 | TRUE |

其中两个cost/weight设置的可接受数值范围、调参效果及与提前停止的关系，所查文档未说明。不能自行编造有效范围、推荐倍数，或将slack_weight=90解释成90%而宣称得到对应优化。

新的交叉核对也明确排除误套用：PDF/安装help的Logos列中 **Fast Router Mode** 和 **Multi-thread routing thread size** 均为“无该选项”。因此不能给PG2L100H套Titan的Auto/Mode1/Mode2或PG2L25H/50H/200H的线程数。保存的全局pnr帮助即使列出某选项，也不能越过该设备支持表。

## Route-4022仍未说明的内容

官方PDF、18份安装HTML及保存的pnr帮助都未给出详细路由Route-4022的数值阈值、连续无改进判停次数、bucket阈值或可关闭提前停止的命令。公开的200是拥塞模式上限，不能被解释为保证执行200轮。未找到可据官方依据使用的 `router_effort`、`routing_effort`、`high_effort` 或“禁用拥塞早停”接口；不得把臆测参数交给当前任务。

本次可读日志快照仍为D detailed20=51630、E detailed14=49984、G detailed6=68527；仅证明已输出这些轮次，不作收敛/完成时间推断，没有用不同轮次排序优劣。未进行任何新参数试验。

官方目录 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc` 保持只读；本补充依赖其 `Pango_Design_Suite_User_Guide.pdf` 设备规则及同目录既有官方文本抽取。命令帮助语法来自 `fpga/build/isp_geometry/pnr_help.log`，其help工程为PGL12G，仅作同安装版语法记录，设备适用性仍按上述PG2L100H规则判断。
