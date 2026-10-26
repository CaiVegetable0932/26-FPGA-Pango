# 三份实现的详细路由 iteration8 比较

审查时间2026-10-14 18:43–18:48，PDS2022.2-SP6.4 Build146967，PG2L100H/-6/FBG676。只读比较完整第8轮SRB图/CNI、各自SNR/controlsets和源码实际字节；没有修改live/state/frozen，没有启动PDS/仿真，没有停止原生进程，没有读取正在写的PNR/fail数据库。

A=`hybr_b_20261014_143515`；B=`delay_20261014_153410`；D=`delay_20261014_171555`。三次实际Tcl均为decon1 / seed11 / normal / ctrl-chain500 / congest200 / dump TRUE。它们是不同MAP，不能当作decon或seed单因素试验。以下统一比较已完成的详细iteration8，不按不同绝对运行时长排序。

## 同轮实际路由与SRB图

| iteration8指标 | A | B | D |
|---|---:|---:|---:|
| 日志未布通 / total subnets | 62357 / 111464 | 66531 / 110713 | 64743 / 109660 |
| 该轮CPU(s) | 294.468750 | 1329.109375 | 303.515625 |
| SRB图最大值 | 50 | 63 | 50 |
| 正值网格数 | 9009 | 9178 | 8967 |
| 值≥20网格数 | 2816 | 3967 | 3218 |
| 值≥40网格数 | 40 | 63 | 24 |
| 全部非负网格值总和 | 131286 | 157810 | 138327 |

图格式相同：x_div/y_div=6，offset=0，204行、10550个非负有效格，-1哨兵不计入。上述sum/阈值数量是本次统计，官方未定义为归一化拥塞率。未布通计数不是完成百分比；CPU差异也不能换算ETA。PDS官方指南印刷p113–114定义CongestionPlot为各轮SRB拥塞显示、CongestionNetInfo为冲突net信息。

热区确有移动：最大SRB图网格位置（仅零基矩阵行/列，没有假定物理方向）A=(154,60)、B=(147,2)、D=(78,38)。B的其他高值点为(71,34)=51、(60,36)=50；D为(75,48)=48、(93,41)=47；A为(153,60)/(151,60)/(142,57)/(28,38)=47。热点不是固定在三图同一格。网格热点与某个驱动位置不能直接一一对应。

## CNI层级与主要网名

| 第8轮CNI统计 | A | B | D |
|---|---:|---:|---:|
| 原始记录条数 | 61508 | 65617 | 63884 |
| 独立design net name数 | 50822 | 53771 | 52273 |
| 文件congestion value总和 | 155217 | 170324 | 161024 |

记录数/独立名字数与日志未布通数均不相等。重复名字及生成名存在，不能把记录条数解释为独立逻辑网数量。下面给出对应层级value总和，同样属于文件内观测统计：

| 层级 | A | B | D |
|---|---:|---:|---:|
| geometry | 20514 | 24421 | 24018 |
| frame pools | 22163 | 22631 | 19444 |
| DMA | 12346 | 13756 | 12301 |
| DDR PHY | 11153 | 11985 | 11786 |
| network | 5456 | 8298 | 7386 |
| snapshot service | 6236 | 6241 | 6485 |
| geometry refill | 5620 | 5553 | 4847 |

geometry内部仍有多个热点：u_cache的A/B/D值总和7869/9720/9861，projective_path.u_step为5191/7217/7227，u_map为3866/3400/3525，u_result为1985/2362/1860。源码将u_result实例关联到rgb_enhance（geometry_rgb_pipeline.sv:97），u_map关联到lens_inverse_map(:83)。单个最大值不代表该模块总压力：D的refill/N23350单条为121，但refill整体value低于A/B。

frame pools从B到D的记录条数7179→6528、value22631→19444。各bank的A/B/D值总和分别：bank0=7291/8053/5863，bank1=5518/5578/4624，bank2=3825/3685/3122，bank3=2796/2829/3084，bank4=2671/2481/2751。前三个池下降，后两个池上升；不能写成所有帧池同时改善。

典型高值驱动记录也变化：A最高是u_result/N853=104@CLMA_261_607:Y2；B最高是bank0/N768=165@CLMA_231_564:Y0，随后bank0/N9580=143；D最高是refill/N23350=121@CLMA_243_1122:Y1，随后u_result/N853=106@CLMS_183_247:Y1。相同u_result/N853路径名在B为81@CLMA_249_522:Y1，驱动位置已不同。N编号是生成名，未经网表追踪不能假定跨版本同编号对应相同RTL表达式；此处仅报告路径名/位置，不推断根因。

## 源码与综合证据

本次逐一重算三份290项source快照的SHA256，全部匹配sources.json。A→B仅差 `rtl/geometry/perspective_divide.sv`、`lens_inverse_map.sv`：原来的纯payload/tag移位链替换为32深度环形LUT RAM、独立output寄存器，保留原advance停顿及valid/ok屏蔽策略。B→D仅差 `rtl/memory/frame_pool_bank.sv`：per-slot 64位order_id比较替换为older相对关系矩阵；每次分配更新相应行/列。全64位next_order及分配耗尽拒绝边界仍保留。此次没有重新执行功能等价性测试；功能回归结论应引用各候选已有验证报告。

| SYN/SNR资源，非MAP/物理最终资源 | A | B | D |
|---|---:|---:|---:|
| 整板LUT | 46168 | 46505 | 45941 |
| 整板FF | 48032 | 43939 | 43362 |
| Distributed RAM | 2801 | 2929 | 2929 |
| unique control sets | 744 | 741 | 735 |
| geometry LUT / FF / RAM | 7726 / 10796 / 781 | 7869 / 6702 / 909 | 7872 / 6701 / 909 |
| frame pools LUT / FF / RAM | 7047 / 4453 / 601 | 7191 / 4449 / 601 | 6352 / 3880 / 601 |

三份SNR均125APM、58DRM、115IO。A→B geometry减少4094FF并增加128RAM，但第8轮geometry/总体拥塞指标并未同时下降。B→D帧池SNR减少839LUT/569FF，整板减少564LUT/577FF；帧池第8轮压力下降与这些变化一致。资源统计与路由之间仍有布局、逻辑复制/打包及全局位置变化，不能由局部资源下降保证整体布通。未改源码的模块也有SNR计数/位置变化，不能只按RTL变更文件给所有拥塞变化作单一解释。

三份源约束、IP和配置相同（290项差异仅上述RTL）；clocks_cdc.fdc均SHA `ecce7782818ac02c24a39bb539c12654227f4f61e0494a9d9c27aeeb81f078b6`。各自生成PCF字节不同，A/B/D分别 `baf00caa654ddca777e001e7876f0b6d3a7b0372fc338a6178d1d22db61b0e34` / `8232194b097eba4d9cdda670d606a4ff319ae46fec1ce171cd5be8b51e003585` / `e4fbc6cfc3166dd9a57787de7a2105d86553f0459859d57f48e9964919912df8`；不把不同MAP的PCF宣称为同一物理实现。

## 可确认、待确认及失败后准备

可确认：同第8轮D比B总体SRB统计和帧池记录较低，geometry内部cache/step压力仍高；A在部分总体统计上仍低于D。D较快完成该轮，原生继续迭代。不能确认：D最终一定比A/B更易布通、谁满足最终时序、唯一拥塞根因、是否达到可下载位流以及剩余时间。

如果发生自然路由失败，先保留该实现最后完整轮CNI/图和原生Route错误，与这里第8轮证据对照，确认热区是持续还是迁移。然后对持续的具体driver/load核对实际fanout、control set、复制/packing和路由位置，优先调查geometry u_cache、step、frame pools、DMA/PHY这些已有多点证据，而非仅选最大单条。若需物理参数试验，应使用同一个冻结MAP及约束，只改一个官方支持因素并独立记录；本比较不支持跨A/B/D给decon/seed归因。当前三路继续，不进行任何例外扩张或时钟改动。

审查时最新日志为A iteration23=45977，B iteration10=62937，D iteration9=62780，均尚无route签核；这些最新阶段没有混入第8轮表格。

资料：各build的place_route/run.log、CongestionPlot_8.txt、CongestionNetInfo_8.txt、synthesize/pango_video_system.snr及controlsets、sources.json与source实际文件。官方只读原件 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Pango_Design_Suite_User_Guide.pdf` 本次SHA仍为`e2ac3f2ac7bb539cc51fe85cc239ea2249f4ee6790912b67c86cae23a3898ba2`，对应已提取文本；引用印刷p113–114。
