# seed 13 后续热点与候选选择

核查时点：2026-10-20 19:09:38，亚洲/上海。只读检查当前任务；未修改RTL、约束、配置或任何运行状态。

## 运行范围

绑定工程为 `fpga/build/full_integration_20261013/handoff_20261020_053147_229875`，本轮证据目录为 `resume_20261020_175734_931652`，启动会话为 `fpga/build/route_optimization/deepseek_route_20261020_175732_8933723`。监控记录为RUNNING、4323.235秒、90分钟上限；第17轮剩36,842子网，单轮CPU300.078125秒。尚无本轮完成的result.json及routed STA。

本次只比较已经完整输出的第15、16、17轮。未布通数依次38,704、37,734、36,842，仍在改善；不根据这些点外推完成时间或判定不可布通。

## 连续热点

下表数值为对应网络族在完整CongestionNetInfo中出现的最大原始值；每轮最大值可能属于该族不同网络，不代表同一根网连续变化。

| 对象 | iter15 | iter16 | iter17 | 结论 |
| --- | ---: | ---: | ---: | --- |
| memory_refill网络族 | 53 | 58 | 59 | 三轮持续，优先审查局部取样、写地址与选择互连 |
| geo_src_slot网络族 | 54 | 40 | 51 | 三轮均突出，支持作业参数预选锁存方向 |
| 主reader local_capture[2].capture_enable | 14 | 64 | 63 | 最近两轮最高热点；加入下一轮专项审查，不与snapshot reader同名信号混淆 |
| geometry/u_result网络族 | 11 | 16 | 16 | 本轮暂不支持将Gamma列为第一批改动 |
| tone_cursor网络族 | 7 | 9 | 9 | 同上，保留后备，不依据旧seed热点强行推进 |

第17轮refill还包括write_beat_6=58、N1341[4]=55、quad[0]=47、write_beat_2=46。第16轮帧池bank4 N410_0=63，第17轮降至49；按bank专项调查，不能重跑已失败的统一代次分块方案。

## 冻结源码关联及限制

以下路径相对绑定工程的 `source/`：

- `rtl/memory/geometry_tile_refill.sv:33–42`：两组256位LUTRAM、512位窗口及48位抽取；48–64行已有奇偶行本地写使能。后续应比较读侧常量切片/分组选择，先排除与旧拒绝候选相同的实现；不能重复宣称新增了已有WE局部化。
- `rtl/board/video_memory_core.sv:76,239`：3份544位source_geometry由geo_src_slot选择；`rtl/memory/processing_job_cdc.sv:24`直接借用source_job。支持将作业预选锁存与跨域首次捕获分离的候选。
- `rtl/memory/dma_byte_unpack.v:45–51`：主reader按4组64位保存数据，每组capture_enable仍依赖beat_valid、局部状态与chunk_ready。新研究应比较真实负载范围和更局部的数据/握手组织，不能只重复添加同样的四组CE副本；不得随意删除payload复位或给ready加拍而无保留空间。

参考综合网表为 `fpga/build/route_optimization/proc150_board_mapping_20261020_050951_080852/synthesize/pango_video_system_syn.vm`，已确认存在geo_src_slot派生网络。N1341等综合自动名尚未完成逐引脚锥回溯；上述RTL关联依据模块层次与命名信号，不能断言某个自动名一定就是动态移位器。候选实施前必须补做驱动/负载及原语映射审查。

## 本次确定的研究优先级

1. **第一批A：refill局部抽取网络**。先比较固定16种位置切片与现有综合网络；若映射等价、与旧拒绝候选等价、线长/时序恶化，否决。保持quad 5/10跨beat、边缘、背压、取消和last语义。
2. **第一批B：DDR域作业参数预选锁存**。先锁存所选544位再发布request；参数生命周期、同帧绑定、reset/drain与CDC端点必须同步验证。保持6ns数据约束，不通过放宽约束取得收益。
3. **第二批：主reader的局部捕获控制**。先追踪capture_enable[2]为何跨两轮变成最高热点，再选择进一步分组或弹性隔离。原局部夹具的收益不能代表当前整机收益；没有新结构依据时不再复制更多寄存器。
4. Gamma/tone退到后备，DMA浅宽payload映射仍为资源布局后备。帧池失败候选不重跑。

选择的是下一轮研究方向，不是已经证明能改善布线的实现。当前seed13继续由原执行者管理。本跟进的“等待进一步热点并确定方向”已完成，停止该热点分析心跳；不停止PDS、不更改运行预算，也不接管原执行者的终态监控。

## 证据校验

原始文件均位于绑定工程 `place_route/CongestionNetInfo/`：

| 文件 | SHA256 |
| --- | --- |
| CongestionNetInfo_15.txt | D4377D52882CEFAB5C9CED0691DCF7C365701766CCBB030687551EA2028B644E |
| CongestionNetInfo_16.txt | CF7B7FB01AF6ACAA65B7B84C4E29A3B7F4C61A3E7FB78D93DA8D6575B2E0B529 |
| CongestionNetInfo_17.txt | 91CB47AB0D35A5BAD02D651CAF965D849BC7DF406FC1B322CAA81E7E88886A02 |

同一工程后续任务可能重用活动输出路径，应通过以上哈希与原执行者终态归档核对，不能只凭文件名关联本次证据。
