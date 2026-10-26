# B原生失败后的限定后备审查

2026-10-14 20:04–20:10；PDS2022.2-SP6.4 Build146967，PG2L100H/-6/FBG676。只读查阅已结束B的日志/最终拥塞图/CNI/prr、观察器记录、已完成MAP及安装版官方RCE/Route Iterate说明。没有启动PDS/仿真，没有创建RCF、修改源或约束，没有停止/改变D/E/F，也没有读取其写入中的PNR/fail DB。下述命令是未来独立副本中的待验证步骤，本次未执行。

## B退出与证据完整性

B=`delay_20261014_153410/resume_20261014_160518_945164`。持续持有原进程HANDLE的观察器记录child11256/parent42128真实退出码1，UTC `2026-10-14T11:25:57.931487+00:00`（北京19:25:57.931487）。CIM创建时间/命令/父PID/MAP/工程guard通过，前后实际290项source SHA均匹配，changed_inputs=[]，final_evidence_error为空。观察JSON SHA为`217db412d8b5d9462c2b0c40c3c880aae9f0a8566bdf7ea765116031e2e97982`。

两份日志均明确W:Route-4022拥塞失败及E:Route-0008不能布通。最后详细iteration11为61744/110713未布通，单轮CPU2254.28125s，detailed9821.42s、total routing10042.37s。CLMA10380/11675、CLMS4421/4975各显示89%，LUT45838、FF44046、Distributed RAM2929；资源尚有余量不能证明路由必可收敛。它在wrapper240分钟期限前自然退出，属于原生拥塞失败，区别于A的host timeout。

已保留fail_pnr SHA `1fe39d526bec76675aa62e0783769de0533a9257b171361111d8d492d1be3fcc`、PLC SHA `2332c8f0a5b585f9c1a5e997f5e43d7bc109bc1271e5b7f22752b38b552fe356`、prr SHA `2f479efc3326d2c9b7613bef5ac633b1a66755cce0e97f0a7cb2d76833c61e38`。没有成功PNR DB或时序签核。本agent会话64984已经收到B child_exited输出，CIM中observer32024、B11256/42128均不存在；A/B退出观察已自然完成，未重启观察器。

## 最终iteration11实际拥塞

SRB图10550个非负有效格、8974个正值格、≥20为2255格、≥40为1格，最大值41，非负值总和124797。相较B8（max63/sum157810），图中冲突下降，但本轮仍自然失败。此总和不是官方归一化拥塞率，也不能换成完成比例或ETA。

CNI11有60895条记录、50227个独立net name，总value154990，与日志61744不相等。geometry value21626、frames21089、DMA13216、DDR PHY10970、network7195、snapshot5877、refill5107；细分cache8527、projective step6441、bank0 7671、bank1 5120。最高单条bank0/N768=199@CLMA_231_564:Y0，其次bank0/N9580=113、bank4/N956=96、bank0/N3253=91、bank2/N1119=89。SRB最大值和单条CNI value含义不同，不应混称。

这些记录表明多层级压力持续，不能指定唯一根因。尤其B的最高生成名N768与D中相对次序矩阵的不同实现之间没有对象对应证明。B MAP SHA为`28bf22ff10a8ff38c56f3147a7e70c98f711adf90000ad29fd82840095c648af`，当前D/E/F共用另一MAP `d77373411015c61d83b0d5216df68d169e5303fe6f4c466dec40ae4d15d2d993`，**不得把B的N768/N9580或旧物理位置直接加入D的RCF**。

## 共同前置条件与只读定位

若选定的最新候选也自然失败，确认其MAP/PCF/FDC已冻结并与仍在运行的任务输出隔离后，才开展该后备试验。为每个试验建立短路径独立build/工作目录，复制必要源/IP/工程/PLC证据，记录全部输入SHA；原始失败证据保留。从该候选已验证resume Tcl复制add_design及add_constraint前缀，**将第2行set_dir的impl_directory改为试验目录**，保持目标、输入次序、IP/FDC/原RCF和PCF。不能只改pds_shell的work_dir而让set_dir仍指向原任务。

RCE官方p7–9说明加载PLC、必要时会完成布局，并且打开时新建/替换RCF会改变工程状态；因此只在副本中打开。p36说明save_adif写当前PLC且-file_name尚不支持另存，不能依赖该参数保护原件。p10–11支持Show Placement、Show Rats、Show Routes及Device/Pin搜索；p19–20的Design Browser可核对Site、Fanout、Bounding Box。对**该副本当前MAP/PLC中实际存在且driver/load可对应的net**，可在RCE Console使用：

```tcl
# Purpose: inspect one exact net in this trial's loaded PLC; no route mutation.
select -design_net {VERIFIED_NET_NAME}
show -design_net {VERIFIED_NET_NAME}
```

官方p36–37定义select/show，返回路径/支路/资源信息。VERIFIED_NET_NAME是当前候选实际解析的完整名称，不是字面占位符或B旧生成名；存在/driver/load/fanout尚未核实的对象不能进入优先约束。保留稳定后续轮SRB图与CNI，判断热点是否持续，再选一个对象。

## 独立试验1：单参数关闭布局复制

官方PDS指南p112说明Design Cells Duplication是自适应插入/复制单元的时序优化，p118在Logos2列支持该项；现有同版本pnr -help记录提供-dc_duplication TRUE/FALSE。若需要区分复制对路由压力的影响，可固定选定MAP、PCF、原FDC、decon1/seed11/normal/500/200，只把duplication改为FALSE：

```tcl
# Purpose: one-factor placement-duplication trial in a separate FPGA build.
pnr -force_to_run -input_db_file {TRIAL_MAP_PATH} \
    -action_timeout 0 -max_ctrl_chain_length 500 \
    -plc_decongestion 1 -gplace_seed 11 -mode normal \
    -congest_overlap_limit 200 -dump_router_congestion_plot TRUE \
    -dc_duplication FALSE
```

所有占位路径先替换为该独立副本已核对的真实路径。比较相同基线的实际复制数量、CLMA/CLMS、LUT–FF pairing、最终SRB/CNI、路由结果和完整routed min/max STA。关闭该时序优化可能使时序变差；没有证据保证减少拥塞或成功。不要将此开关与另一packing/decon/priority变化叠加后称为单因素结果。

## 独立试验2：一个已核实名称的优先net

RCE官方p29支持Prior Route Nets，p30支持取消及placed Inst优先，但当前不需要成组扩大范围。使用选定基线默认duplication，保留原routing.rcf中两条DDR IOCLKGATE优先约束，在**新的试验RCF**中只新增一个通过上节定位核对的net：

```tcl
# Purpose: route one verified persistent-conflict net before ordinary nets.
def_route -prior_net {VERIFIED_NET_NAME}
```

该语法由当前正式routing.rcf及B日志1096–1099行在PG2L100H原生成功执行的两条DDR优先net证实；RCE用户手册只给GUI优先操作，未直接列出-prior_net语法。因此这里区分“官方功能说明”和“同目标同版本实际语法证据”。不要猜测未查到的prior_inst或删除指令名称。

在该副本Tcl中保持原约束及PCF注册，随后注册新增RCF并运行原基线pnr命令：

```tcl
# Purpose: add only this trial's physical priority file after original constraints.
add_constraint {TRIAL_PRIORITY_RCF_PATH}
# Then run the baseline pnr command unchanged; no -dc_duplication FALSE here.
```

核对原生日志明确执行这一条def_route且成功，检查目标存在及实际匹配，不能只看RCF文件存在。若名字仅为某次PLC复制/重写产物而新运行不能解析，应停止这一候选解释并重新映射，不能放大通配符。优先布线会改变资源竞争，可能把困难转移到其他net；尚无成功保证。

## Route Constraint Iterate：有完整route/setup证据后再考虑

PDS指南p116–117说明该功能按**setup slack**选net，每轮生成route_constraint_ite.rcf并累计到all_route_constraint_ite.rcf，重新进行PR，直到迭代次数或setup阈值条件满足；它不是router detailed iteration，也不是按CNI最大拥塞值自动选net。安装官方没有说明首次Route-0008中止后能继续产生这一迭代输入；当前B无完整route/setup报告，所以不能宣称它可直接续接B失败。

如果独立试验已经得到完整PNR DB、真实setup违例及其他时序项审查，则可另建独立副本，基线参数不变，增加一个enable功能标志；默认times10/slack0ns/maxpaths3由指南p119表及同版本-help记录支持：

```tcl
# Purpose: an independent setup-priority iteration trial after complete routing.
pnr -force_to_run -input_db_file {TRIAL_MAP_PATH} \
    -action_timeout 0 -max_ctrl_chain_length 500 \
    -plc_decongestion 1 -gplace_seed 11 -mode normal \
    -congest_overlap_limit 200 -dump_router_congestion_plot TRUE \
    -enable_route_constraint_iterate
```

如果需显式配置，受支持的确切选项为 `-route_constraint_iterate_times 10 -route_constraint_slack 0 -route_constraint_max_timing_path 3`，上述默认数值不是放宽FDC，仍须最终完整min/max检查。仅生成/保存RCF不等于完成时序收敛。原有user_rcf与自动累积rcf会共同使用；官方要求重跑完整PR时手动汇总到user_rcf，避免漏掉原两条DDR优先或使用另一个MAP的旧累积约束。

物理手动固定路径的`manual_route`或`def_route {net} {pin:device;...}`不是本阶段优先后备。RCE p35、p39–41要求支路未布线、driver/load的inst在PCF约束、有效连接顺序、原PCF不被dev_map覆盖。本项目尚缺当前D MAP具体有效分支/资源/固定端点证据；不能将其他器件示例路线或B位置直接照搬。

## 尚缺证据与当前状态

缺最新D/E/F的最终原生结果、最终热点是否持续、当前对象的driver/load/fanout及实际优先匹配、复制关闭试验的真实结果、完整routed min/max时序与所有约束报告、Route Iterate首次失败处理行为。每个成功布线候选仍须针对其真实PNR DB执行原约束下的检查，例如：

```tcl
# Purpose: validate all original timing checks against this exact routed DB.
report_timing -force_to_run -input_db_file {TRIAL_PNR_DB_PATH} \
    -delay_type min_max -max_path 30 -report_exception TRUE
```

路径替换、输入SHA、原生exit0且无E、完整route以及真实All Constraints Met均须核实；拥塞值或自动RCF完成不能替代这一步。当前20:09只读日志：D iteration16=54407，E=`phys_20261014_191736_199955` iteration7=62171，F=`phys_20261014_192840_623962` iteration0=86814；三路继续。现有证据不保证任何后备路径必然成功，当前不实施。

## 实际资料

- 官方只读 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Route_Constraint_Editor_User_Guide.pdf`，本次SHA `d768f9a4b75bed2f78e8d50f5b8d3533ab9747a2057eddb2d3cc16dc67a8dc6a`；既有抽取 `fpga/build/clock_reset_20261012/reference/Route_Constraint_Editor_User_Guide.txt`。引用印刷p7–11、p19–20、p29–31、p35–41。
- 同安装版PDS指南抽取 `fpga/build/full_integration_20261013/reference/Pango_Design_Suite_User_Guide.txt`，引用p112–113、p116–120；原件SHA已在前项审查确认。
- 既有 `fpga/build/isp_geometry/pnr_help.log` 明确Version2022.2-SP6.4/build146967，为全局命令语法记录；该help工程目标是PGL12G，不能把它当成PG2L100H试验通过。设备支持仍据PG2L100H特例和Logos2/Logos对应官方参数列核对。
- B退出JSON、place_route/run.log（1233–1251/1263–1267/1314行）、CongestionPlot_11.txt、CongestionNetInfo_11.txt、pango_video_system.prr；当前正式routing.rcf。上述失败证据仅阅读，未重写原生文件。
