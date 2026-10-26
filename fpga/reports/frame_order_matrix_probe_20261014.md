# 相对先后矩阵隔离单位验证（2026-10-14）

已完成唯一候选的全部单位验证。原 `order_id[slot]` 仅在分配时写入、消费者 oldest 选择时比较；其余用途是测试内省。候选将这项内部载荷替换为相对先后矩阵，完整 `next_order` 64 位耗尽计数、generation 32 位、ticket 64 位以及外部 616 位元数据均保持原实现。

当唯一 ALLOC 接受时，新槽的行清零，其列写入其他槽的 pre-edge busy。已有忙槽均比新槽老，其他关系保留。释放/复位使 busy=0，从比较中屏蔽旧关系；后续分配先重建行列再暴露 ownership。刚在本周期释放的槽不会在同周期被重分配，故 SEAL、acquire、release、issue/complete 的原同时事件规则保持。

| 相同原生 SYN 台架 | 原 LUT | 候选 LUT | 原 FF | 候选 FF | 原/候选 RAM |
| --- | ---: | ---: | ---: | ---: | ---: |
| SLOTS3/TXNS4/四动态消费者/616 bit/8 ns | 6655 | 6566 | 5184 | 4996 | 1072/1072 |
| SLOTS1/相同接口与约束 | 3805 | 3805 | 5161 | 5161 | 0/0 |

三槽台架实际减少 89 LUT、188 FF，控制集 27→26。pool 层减少 219 LUT、188 FF；与顶层 LUT 差异来自观察台架优化，不外推为整板收益。两组全部原生执行 exit=0、errors=[]，目标 PG2L100H/-6/FBG676，PDS 2022.2-SP6.4。没有通过单位 SYN 声称实际布线或硬件通过。

原 manager、512 帧 pressure、snapshot、四消费者全字段、多槽/单槽、64 位 ticket 边界在两副本上全部 PASS。独立原 64 位排序参考比较完整 2889 位响应和所有忙槽关系，共 12013 周期/234303 次检查，覆盖 682 次低编号洞复用、1629 同时事件、7 次 joint reset/flush、484 readiness 隔离周期、186183 次 live-pair 比较。另验证次序计数 ffff...fffe→ffff...ffff 后即使仍有空槽也拒绝新分配。

候选：[frame_pool_bank.sv](/D:/XDU/concept/26-FPGA-Pango/fpga/build/full_integration_20261013/ord_20261014_1705/candidate/source/frame_pool_bank.sv)。SHA256 为 `37f5830798d3a5ad57987401a862a1221cbb7cbb13278e6d3dca20b714e5131e`。原组合冻结、正式银行 SHA 均仍为 `2885a5979bdf5d60f444cc82ec340d7e65e39da768109dc4bc2a3e6f2a860f71`，未改动。

[完整证据](/D:/XDU/concept/26-FPGA-Pango/fpga/build/full_integration_20261013/ord_20261014_1705/evidence.json) 核对原生输入、所有复制源、既有冻结与正式银行完整。来源、排序不变量和测试适配说明见同目录 README.md。单位审查时点 2026-10-14 17:13:47 +08:00。

## 授权的唯一整板后备结果

单位全部通过后，根代理授权从 `delay_20261014_153410` 创建一个仅银行差异的 compile/SYN/MAP 后备。新 build 为 `delay_20261014_171555`，银行为上述候选 SHA；sources.json SHA256 为 `62c8bf2d79ca1c17fdd23e7742f4f6ecf0bef879a0a76bf8d956b4165369b1b5`。完整模型为 `verilator_20261014_171627_099539`。没有改变其它模块、约束、时钟或精度。

| 实际整板资源 | 组合基线 | 排序后备 | 差异 |
| --- | ---: | ---: | ---: |
| SYN LUT | 46505 | 45941 | −564 |
| SYN FF | 43939 | 43362 | −577 |
| SYN 控制集 | 741 | 735 | −6 |
| MAP LUT | 46491 | 45925 | −566 |
| MAP FF | 43928 | 43351 | −577 |
| MAP RAM/APM/DRM/IO | 2929/125/58/115 | 2929/125/58/115 | 均不变 |

原生 compile/SYN/MAP 自然完成，session 63574 exit=0、errors=[]，耗时 1304.279 秒。完整 1080p/snapshot/control 模型 session 93606 exit=0，3 good/3 processed，6220800 字节检查，geometry_cycles=4014191。

[Host 验证](/D:/XDU/concept/26-FPGA-Pango/host/reports/fpga_rgb_vectors_20261014_172833_401973.json) 对 8888 个包、12441600 个 RGB 字节和两份同源描述符核对 PASS。两份二进制输出 SHA 与原组合完全一致：datagrams `f42a234194de8b85d182f6e4d1ae089d3f02266d8e1918fb0a027853e5c01669`；descriptors `1f7791da07114603493586ee16181dae243ab13a38b9085d15da53d887666366`。

[最终整板证据](/D:/XDU/concept/26-FPGA-Pango/fpga/build/full_integration_20261013/delay_20261014_171555/ordering_board_evidence.json) 在原生和模型完成后，实际逐文件核对全部 290 个 native 来源、71 个 model 来源、70 个共同 RTL 及原组合全部 290 个来源完整；差异仅为银行文件。主工程与此前冻结来源未修改，子任务没有启动新的 PnR 或生成位流。整板测量完成记录时点 2026-10-14 17:37:24 +08:00；资源收益不等于实际布线、时序或硬件验证通过。
