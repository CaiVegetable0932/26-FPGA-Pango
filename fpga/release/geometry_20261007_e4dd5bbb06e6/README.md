# 时序闭合的 FPGA 灰度矫正 / 20 点标记候选

2026-10-07，分支 `codex/fpga-geometry-correction`。
目标盘古100K MINI，PG2L100H-6FBG676，PDS 2022.2-SP6.4 build146967。
本目录是下一轮上板候选：已完成综合、布线、独立STA及离线镜像转换；
没有执行烧录、Flash回读、冷启动或硬件验收，未提交/推送本轮修改。

## 文件和身份

| 文件 | 大小 B | SHA-256 |
| --- | ---: | --- |
| mini_raw8_geometry.sbit | 3791112 | E4DD5BBB06E659C55ECB87B7A4F66385D0680A2D1C4DE46F838830B7AFA180A2 |
| mini_raw8_geometry.sfc | 3791112 | E4DD5BBB06E659C55ECB87B7A4F66385D0680A2D1C4DE46F838830B7AFA180A2 |
| stage_report.rtr | 5060650 | 2C287EB3680A1C2656B7D8DD0F4ECDF29D570EFAB559A45A55464AE6A2F0791D |

SFC使用PDS原生cfg_gen_sfc：XT25F128、opcode=0x0B、SPI x1、起始地址0，
两次独立转换长度与SHA完全一致。它不代表已经写入硬件。
`generation_evidence.json`把本次独立STA和SBIT绑定到同一冻结路由DB；
`conversion_evidence.json`、`manifest.json`及`main_release_review.json`
保存转换、归档和主代理532项来源/输出的复核。DB SHA为
`8993304BECF0FA3703CB7D7174757651A4905CEC7ECD235B96310DF8A59EBBAA`。

## 时序结果（原有约束不放宽）

| 检查 | Slow最差余量ns | Fast最差余量ns |
| --- | ---: | ---: |
| Setup | +0.087 | +0.148 |
| Hold | +0.140 | +0.103 |
| Recovery | +0.022 | +0.490 |
| Removal | +0.174 | +0.108 |
| Minimum pulse width | +0.035 | +0.035 |

十张汇总均TNS=0、失败端点=0。最终39906 LUT、50816 FF、66.5 DRM、
103 APM、113 IO；保留为时序增加的并行逻辑，不以面积优先重新串行化。
最小裕量仍有限，以上仅表示安装版模型和当前约束内闭合，不保证未约束
摄像头pad、实际PCB/PHY时序、所有温度工况或真实1080p30已经验证。

## 功能与使用

沿用现有host“FPGA几何与显示控制”：上传矫正参数；选择原图或FPGA
矫正图、显示/隐藏标记、直径4～32（默认10），然后应用板端显示。
模式和参数按帧生效，ACK仅表示请求被接受，须回读实际显示版本。
本轮只优化物理实现，不更改鱼眼方法、20点坐标/编号/颜色、帧边界或
RAW8网络字节；两种显示模式均来自同一灰度ISP阶段。

UART 0x35：24B，epoch LE64、session LE32、revision LE32、flags LE32、
diameter LE32；flags bit0=原图，bit1=标记。0x34 bank2返回实际显示
revision、参数版本、generation、可见掩码和每点源坐标/目标Q12/RGB24。
完整接口见 `host/docs/FPGA几何与显示Web接口.md` 和
`fpga/reports/geometry_markers_20261006.md`；参数协议见
`output/FPGA灰度鱼眼矫正参数接口.md`，本轮没有改动其控制语义。

HDMI末端叠加不写入缓存采样源或网络数据。网口仍是既有增强Bayer
RAW8 / RENH v2，不冒充传感器未经处理的S0；计算机软件参考仍独立，
不代替FPGA结果。HDMI source_frame_id必须保持null、pairing_status为
unverified，不能按到达顺序配对。

## 验证及修改落点

18组功能/控制/完整1080p栅格回归来源436项复核无漂移；受新cache影响
的7组均实际重跑PASS。网络完整帧2帧/4147200字节和2073600 HDMI有效
像素在原图/鱼眼模式分别检查，首结果周期与前版相同。专用cache
40项逐周期miter共3357067cycles PASS，包含背压、fill、replay、invalidate、
复位和故障处理；这是bounded simulation，不是无界formal。

本轮关键实现为 `fpga/rtl/geometry/geometry_window_cache.v`：请求/replay
有效位同拍并行采样，局部FF后选位；保留既有RAM、FSM、延迟和四态
初始化约定。已保留的前序时序改造包括board内ETH fabric/TX同PLL独立
全局支路及boot稳定epoch专用控制。新增验证bench/runner/checker和
资源、发布门禁在 `fpga/sim/`、`fpga/scripts/`，历史证明不重标为新RTL。
完整改造、资源/时序及局限记录于
`fpga/reports/geometry_timing_priority_20261007.md`。

本目录归档57项新cache证明和boot/resource来源。PS5.1/7资源45项、
新cache发布10项、保留资源发布10项、boot发布24项均由主代理独立
重跑PASS；最终STA门禁255项也分别通过，均不冒充硬件测试。

真实源帧率、完整网口帧率、FPGA有效输出帧率、网页显示帧率、外部
DVP电气时序及浏览器图像审校均未执行本候选实测。下次烧录需本轮
重新授权；整片擦写、回读后必须先请用户彻底冷启动，确认后再测试。
