# H 组合冻结源低内存恢复回归

2026-10-14 22:14。基线为 `fpga/build/full_integration_20261013/delay_20261014_220546_195131/source`。本次仅使用正式Icarus入口，顺序执行四项已指定小回归；没有运行PDS、重跑全帧、查询root的MAP/Verilator sessions，或修改live/board/model来源。

四项全部实际PASS，会话27215自然退出0：

| 测试 | 实际原始日志 |
| --- | --- |
| tb_frame_memory_fabric | FRAME_MEMORY_FABRIC_PASS checks=28 |
| tb_frame_ticket_rollover | TB_FRAME_TICKET_ROLLOVER_PASS checks=6 |
| tb_geometry_frame_processor | GEOMETRY_FRAME_PROCESSOR_PASS frames=3 verified_result_bytes=608256 cycles=8717 |
| tb_video_memory_core | TB_VIDEO_MEMORY_CORE_PASS bytes=3465 good=3 processed=2 geometry_cycles=3792 |

实际命令：

```text
python -B fpga/scripts/sim_full_integration.py --rtl-snapshot fpga/build/full_integration_20261013/delay_20261014_220546_195131/source --cases tb_frame_memory_fabric tb_frame_ticket_rollover tb_geometry_frame_processor tb_video_memory_core --network-test
```

编译的core VVP实际 `NETWORK_TEST=1`。正式runner原result未记录network_test字段，本次保持原JSON不变，由实际命令、保存的simulation_script.py与compiled VVP参数三者绑定；并在独立 `recovery_review_evidence.json` 记录。

fabric场景覆盖全掩码readback排空后publication、done保持至ACK、读背压、读取消保持存储帧、首beat损坏隔离、写取消等待readback、非法范围/stale generation拒绝、七路payload/唯一ticket并发完成。ticket场景跨旧32bit上限、拒绝截断completion、接受完整64bit值以及最终64bit耗尽拒绝回卷。core先验证截断帧cancel/drain，再在在途网络传输断链并等待释放，恢复link后完成新正常帧。geometry场景保留现有三帧/整结果内存检查；608256为原台架计数，不能当作新增真实视频有效吞吐。

前置证明：H全部290份native来源实际SHA与manifest一致，记录在build根 `recovery_source_identity_before.json`。回归后再次重哈希：H290份前后不变；本次81份RTL/测试输入全部与实际保存源匹配；其中62份共同RTL逐文件与H实际源一致。没有依赖live RTL来代替H。

H manifest SHA：`71ed8b1c37ceacb7242a7880d967411c9a3ba97c203af53b491e7f357137752a`。本次sim manifest SHA：`e9d8706b2b813622553b356ed5719212a75ea014445a3e93e8201825422f8ba9`。三个组合改动文件的实际身份为：

- frame_pool_bank.sv：`f445700f24a71e203e31fe20849965ccb15885d4b17fe383e39fc3ecf5f8b1b1`
- rgb_tile_cache.sv：`04a409b3ef18fb4631f9c388440c8d66fe89d437a446e6d96c2dda28006b9c06`
- geometry_rgb_pipeline.sv：`c62ba0ae3d03e3b7f17ef36b4fd8360e69e1ab230796c147d36f2e9211f76654`

没有出现白盒夹具引用已删除token_gen的编译失败，所以未适配、删减或修改任何台架断言。原始编译/运行日志、四份VVP、来源副本及实际SHA证明均保留。

结果目录：[sim_20261014_221314_020623](D:/XDU/concept/26-FPGA-Pango/fpga/build/full_integration_20261013/sim_20261014_221314_020623/result.json)；[完整恢复证据](D:/XDU/concept/26-FPGA-Pango/fpga/build/full_integration_20261013/sim_20261014_221314_020623/recovery_review_evidence.json)。这是小尺寸合成RTL恢复回归，full_frame_simulation=false、hardware_tested=false，不代替root正在执行的完整功能/性能模型、真实routed min/max、bitgen或后续烧录测试。本次到此结束，不追加优化或测试探索。
