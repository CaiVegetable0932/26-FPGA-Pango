# D frame_memory_fabric 共享数据存储限定只读审查

2026-10-14。基线 `fpga/build/full_integration_20261013/delay_20261014_171555`。本次只读取冻结RTL、已完成SNR/综合网表、既有测试源码与日志；不生成候选，不运行PDS/仿真，不修改live/frozen，不停止或改变任何路由。

结论：没有发现可以直接合并的重复响应寄存器。当前已在**每客户端内部复用同一个读/写payload bank**；不同客户端可同时持有完整响应、独立背压，并可同时加载写payload。把它们缩成一个burst缓冲或只有单读/单写能力的共享RAM会破坏容量、并发、保持、取消drain或当前时序合同；本次不生成共享bank后备。

## 宽度与资源事实

当前每客户端读/写数据均为**256bit**，七路总线为1792bit：冻结 `memory/frame_memory_fabric.sv:19,21`、`memory/ddr_native_dma.v:24,26,33,37`、`board/video_memory_core.sv:89`。`r_data[512+:256]`（video_memory_core235行）的512是客户端2的切片起点，不是512bit宽度。native IP包装 `source/ip/ddr3_controller/ddr3_controller.v:45,58`为8×MEM_DQ_WIDTH，同当前x32目标匹配。

同一冻结SNR的包含子层级计数：

| 层级 | LUT | FF | Distributed RAM | SNR行 |
| --- | ---: | ---: | ---: | ---: |
| core.fabric | 12328 | 6619 | 1546 | 291 |
| core.fabric.dma | 3493 | 644 | 945 | 292 |
| core.fabric.frames | 6352 | 3880 | 601 | 293 |

父子统计不能相加。扣除两个直接子层级后，fabric本层为2483 LUT、2095 FF、0 RAM，这是表的算术差额，不能把全部fabric资源当作读/写数据重复存储。实际DMA综合网表为945个GTP_RAM32X2DP、589个GTP_DFF_CE、48个GTP_DFF_C、7个GTP_DFF_PE，FF合计644，与SNR一致。RTL中的r_data仅在组合块赋值，没有额外的七路响应FF寄存副本。

内部frame_response也不是512bit像素数据：`memory/frame_manager_layout.vh:6,55,67`规定META=616、每bank RSP=2889、acquire_meta=4×616；五bank响应为14445bit的metadata/ACK/ownership/诊断组合总线。`frame_memory_fabric.sv:75,88–91`直接转接response，只单独抽取3bit token和64bit ticket，并不登记一份宽像素响应。

## 并发和保持决定了存储不能收缩

- `ddr_native_dma.v:49–54,74,151–158`为每客户端独立pending/returned/descriptor，req_ready依据本客户端pending；完成须done&&done_ready后才释放。global state/owner一次只发一个native事务，**不代表只允许一个客户端pending或returned**。
- `v:98–109`每客户端有16×256bit payload与16×32bit masks。该客户端读事务用consumed索引，写事务/全掩码readback用native beat_index索引，已经共用payload数组。不是另存一份读响应和一份写数据。
- `v:126–129,180–182,226–237`允许多个returned客户端分别r_valid=1、分别由r_ready推进。一个客户的读burst完全进入本地bank后，native state回到IDLE，即使该客户r_ready=0，也可继续完成其他客户native读；其他客户returned后可同时输出。全burst数据必须保持到各自消费完成/取消和ACK。
- `v:101–106,126,169–170`允许多个write客户同周期w_valid&&w_ready写各自bank，同时一个其他read owner接native_rvalid。写客户必须loaded==beats才eligible（v96–97）。把数据汇总到单写口会使同周期多次接受冲突；仲裁并压低w_ready会改变当前并发/吞吐，增加管线会改变既有延迟。
- `v:76–84,195–224`写payload及mask保留到完整逐字节readback结束；写输送完就复用该存储会破坏VERIFY_WRITES与帧publication证明。fabric实际固定VERIFY_WRITES=1（frame_memory_fabric265行）。
- `v:175–178,212–224,234–236`取消已经native发出的读/写仍需drain；fabric `sv:248–258`也保留token/ticket至银行完成及用户ACK。取消不是立刻借走数据bank的授权。`frame_manager.sv:6–7`的fabric_ready是startup gate，不能代替联合cold reset前的排空。

即使物理上把七个bank拼进同一更大的地址空间，若保持所有当前并发端口、容量和独立索引，仍需banking/多端口实现；不能凭“共享一个RAM”的命名推导资源减少。现有单客户端复用已经实现本次可直接证明的共享边界。

## 失效payload与实际消费者

`ddr_native_dma.v:128`不以r_valid屏蔽r_data；v72同样直出native_wdata。cold reset不清payload/masks，invalid payload可保留旧值或X。`video_memory_core.sv:328`也直出display_r_data；不能声称这些接口失效时恒为零，更不能用“未消费”证明它们逐周期值相同。

实际有效采样边界：

| 消费者 | 冻结source/rtl下行号 | 约束 |
| --- | --- | --- |
| RAW网络reader | network/raw_dma_reader.sv:40–47；memory/dma_byte_unpack.v:36–37,66–79 | READ且!cancel/!aborted的beat_valid，并在beat_valid&&beat_ready采样 |
| 几何refill | memory/geometry_tile_refill.sv:47,118–126 | RECEIVE内if(r_valid)写row；该状态r_ready=1 |
| snapshot复制 | memory/snapshot_copy_dma.sv:29,41 | r_valid&&r_ready捕获buffer，写valid另受状态/取消约束 |
| HDMI跨域/预取 | memory/dma_read_cdc.sv:32–42；video/rgb888_line_prefetch.v:44,85–87,138–145 | 双边握手写存储，完整成功burst后才置full |
| HDMI像素输出 | video/hdmi_display.v:74–75 | consume&&pv&&!dma_fault才输出像素，否则黑色 |

PC没有直接读取DMA像素bank的状态入口：`control/pc_video_boot.sv:11,13,108–114`只分页冻结control/geometry/snapshot状态；`video_memory_core.sv:287–292`完整control_status拼接包含计数、统计、模式和身份；`control/video_snapshot_service.sv:70–77`是描述符/metadata/保留geometry参数。统计来自有效S1流，不能把它与无效DMA r_data混为一谈。这是本次静态范围内的采样核对，未做新的四态穷尽或实板测试。

frame_bank metadata还要求独立并行读：`frame_pool_bank.sv:199–214`按四个消费者各自pending/exact条件选择槽，同一时钟可acquire不同槽；`sv:281–293`多槽动态读、单个accepted allocation写，单槽已有共享held_descriptor（266–279行）。`sv:173,247–257`无有效acquire的metadata为零，fabric_ready=0时ACK/descriptor清零但诊断保留。串行化这些读或合并跨bank descriptor lifetime同样不能直接保留当前延迟和ownership。

## 既有证据与限制

本次没有运行测试。现有 `fpga/sim/tb_ddr_native_dma.sv:167–170`明确断言一个r_ready=0的返回客户端不阻塞其他客户端；189–219行有七路写及混合读写/随机消费停顿fixture。`tb_frame_memory_fabric.sv:98–127,137–151`覆盖全字节readback、读背压、done保持、取消drain和七客户独立payload/ticket。D匹配小回归 `sim_20261014_175002_330425/tb_frame_memory_fabric.run.log`实际记录PASS checks=28；不得把通用DMA旧版本测试或静态源码当作新D硬件验证。

冻结关键SHA：frame_memory_fabric `d4937b0cc5f1fd7840e6abfae37ee7bc0293e2671a1a6114d0cc7d9c2da777cd`；ddr_native_dma `ca0227adde553fdf33f87f8a0a5d9a4d9ae5324de2ac011ec63dc1b58d409c71`；frame_pool_bank `37f5830798d3a5ad57987401a862a1221cbb7cbb13278e6d3dca20b714e5131e`；video_memory_core `6739552fd0a18ecbde87fabe914fa0c5d817cf896f9cea06d659df05a23defe7`。未改变接口/宽度、事务数、票据、计数、约束或任何源码。
