"""Keep experimental entry points and rejected alternatives unambiguous."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4]
p=ROOT/'fpga/experiments/proc150/README.md'
p.write_text('''# 150 MHz 处理域设计实验

2026-10-20 04:57。项目 `D:\\XDU\\concept\\26-FPGA-Pango`，分支 `codex/fpga-pds-project`，云端 <https://github.com/CaiVegetable0932/26-FPGA-Pango>。生产主设计仍125MHz、13项选定修改；本目录未接入生产RTL收集路径。整体PnR和位流门槛关闭。

## 当前待选边界

`rtl/geometry_processing_domain_external_refill.sv`：DDR域保持scheduler/帧池、输入ISP、网络、显示、逐行tile回填；150MHz域运行实际几何/四bank缓存/双线性/pre或post Gamma以及结果writer。

- `processing_job_cdc.sv`：单作业toggle邮箱，借用调度器持有到作业完成的原始总线，处理器原有准入寄存器捕获；不额外复制整份宽描述符。返回失败位后DDR域才退休源/结果引用。
- `tile_refill_cdc.sv`：tile坐标保持总线/双级toggle跨域，130位quad流通过既有 `async_stream_fifo(WIDTH=130,ADDRESS_BITS=4)`。每项包含96位RGB、last、error、32位实际bus字节计数。一个32×8 tile正常64个quad。每行通常仅3个DDR beat，留在DDR域可消除逐行CDC往返；没有增加native在途事务。
- `geometry_frame_processor_external_refill.sv`：由当前处理器窄变换产生，只把refill实例移到外部接口；数值流水、缓存、增强顺序、writer和排空逻辑保留。
- `dma_write_cdc.sv`：1～16拍完整burst收集后转发，数据/掩码双时钟RAM；内存侧连续预取II=1，错误/取消/坏tag计数检查完整。共同冷复位必需。
- `processing_domain_reset.sv`：native初始化不等待processing PLL锁定；所有health同步后先arm再开放业务。arm后任一失锁同时断言controller和所有客户冷复位，fault锁存至外部板复位。native reset必须异步清初始化ready，独立行为模型验证此既有控制器契约，不等于官方PHY硬件验证。

实际板级候选 `fpga/build/route_optimization/proc150_board_20261020_044427_625524` 包含已有125MHz参考的sys_pll OUT1 150MHz、CLKBUFG、共同复位与窄CDC约束；官方DDR IP未改。`board_20261020_044551_218517` 原生任务只Compile/SYN/MAP，预算20分钟，未终结前不计通过。

## 已有证明与待验收

- 写CDC四组时钟/相位各32场景通过；作业邮箱四组各82作业通过；quad CDC四组比例/相位×有无背压，共八组、每组21个tile通过，含停止客户钟/错误末拍/带未读数据共同复位。
- 真实几何+native DDR字节模型三组通过，每组三种增强模式608256结果/保护区字节。六类完成错误/取消/坏tag和逐帧恢复模型另列，九个好帧每字节检查、六个坏帧排空失败。
- 该故障恢复模型暴露原125MHz设计的上一帧cache fault残留竞态。单行 `!cache_start` 修正已让同步原版及三组双时钟15帧恢复检查通过；主设计尚未合入，需原帧池组成的完整帧确认。
- 最终不含帧池优化候选、包含恢复修正的输入闭包：`proc150_video_model_20261020_043529_242103`；小模型 `verilator_20261020_043626_233147` PASS；全1080p控制/同帧快照/真实显示模型 `verilator_20261020_044250_609135` 正在运行，预算预先3600秒，可随账户reserve停止。
- 首个tile域全帧实测几何作业3948091 DDR周期，低于旧同场景4073517及每帧4166666.67周期预算；三个完整场景尚未终结，不作整机1080p30结论。
- projective原生子系统SYN `proc150_mapping_20261020_043616_243611` PASS：LUT10975、FF9043、APM117、物理DRM41。它是动态端口子系统，不是整机预算，也没有routed/STA/CDC或硬件签核。

所有上述短名均位于 `fpga/build/route_optimization/`，仿真`verilator_*`、`board_*`位于 `fpga/build/full_integration_20261013/`。详细证据以progress/handoff及对应manifest/result为准。

## 已拒绝替代

`geometry_processing_domain.sv`、`dma_read_cdc_prefetch.sv` 保留低层读burst CDC的两种历史实验。整段转发首个作业4470577 DDR周期；逐拍预取4323516，均慢于原设计且超服务预算。后者完整模型2400秒TIMEOUT，不重标PASS。不要将这些模块误选为当前tile边界方案。

## 接入门槛

先完成实际板级PLL/时钟网和MAP资源核对、CDC非空匹配/首级连接与其后普通计时、精确150MHz三个全帧期限及主机原始字节/身份，再选择最终文件组合。UCE安装版手册印刷p83确认max-delay支持clock端点；仅从命名的DDR作业保持寄存器到处理捕获域应用6ns界限和该跨域hold例外，不做整域false path。Gray与toggle仅到首级，保持总线到捕获端；不能把FDC草案当签核。

最终设计/仿真通过后通知用户，由用户安排其他智能体监控整体布线。本实验没有下载硬件或生成完整位流。
''',encoding='utf-8',newline='\n')
