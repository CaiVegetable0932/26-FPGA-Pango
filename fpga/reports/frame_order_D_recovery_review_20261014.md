# D 冻结排序银行集成复核与网络恢复小回归

审查时点：2026-10-14 17:53:52 +08:00。D 为 `delay_20261014_171555`，B 按 D 的 variant_origin.json 指定为 `delay_20261014_153410`。本次只读检查现有冻结来源，并使用现有 sim_full_integration.py 执行指定三项小回归；没有修改 live/frozen source、启动 PDS 或重跑全帧模型。

结论：实际差异及生命周期审查未发现新增功能问题，三项小回归全部 PASS。

## 实际差异与来源

B 银行 SHA256：`2885a5979bdf5d60f444cc82ec340d7e65e39da768109dc4bc2a3e6f2a860f71`。D 银行 SHA256：`37f5830798d3a5ad57987401a862a1221cbb7cbb13278e6d3dca20b714e5131e`。

忽略 CRLF/LF 格式差异后，功能改动只包含：保留 next_order64，声明关系矩阵 older；oldest 比较替换为对应关系位；移除分配时 order_id[slot] 的绝对值写入；新增仅对 accepted ALLOC 更新行列的 clock-only 块。公开端口、参数、完整元数据、ownership/token/generation/ticket、SEAL/CANCEL/完成错误优先级及计数器块保持不变。

审查后实际逐文件核对 B、D 全部 290 个 native 来源完整，且唯一本源差异仍为银行文件；本次小回归复制的全部来源也按实际字节核对，62 份 RTL 与 D 冻结源一致。完整 normalized diff、源哈希和日志哈希保存在本次回归目录。

## 排序与生命周期核对

- 选择仍先比较 busy 且 pending 的槽，再对最老槽检查 frame_ready、drain_error 和取消条件。没有改成绕过未完成老帧去选 ready 的新帧；SNAP_EXACT 的 slot/generation 限定也保留。
- 接受 ALLOC 的唯一槽 s 在 pre-edge 必须空闲。新行写 0，新列记录其他槽的 pre-edge busy，表示全部既有忙槽均比新槽老；其他忙槽间关系不变。同一时钟的 NBA 更新与 ownership 安装同时发生，没有添加响应延迟。
- 回收仍要求 busy/sealed 且 inflight、pending、refs 都为 0。当前边沿才释放/回收的槽不能在同一边沿被选作 pre-free 槽。复用空槽时，其完整行列被重建，因此低编号洞不会被误认为最老。
- 矩阵与原 order_id 载荷一样不复位。cold reset 异步清除 busy/pending/refs 等有效控制；无效关系不参与选择。复位后第一次分配在暴露新 ownership 前重建全部有关关系。ready-high 且 reset 仍有效时可能写载荷，但 busy 保持清零，后续有效分配再次初始化；保持 B 的 reset/载荷合同。
- `frame_pool_bank` 没有独立 flush 端口。fabric_ready=0 清除操作 ACK 和描述符响应，并停止矩阵及所有正常状态提交，不替代 DDR draining。实际 frame_memory_fabric 以 controller_ready && !fault 门控；frame_manager 保持“全 fabric cold reset、释放前先 flush”的原合同。本改动不引入局部 reset 或未排空复用。
- next_order 仍为 64 bit，复位为 0；free_slot 的原 `next_order != 64'hffffffffffffffff` 条件和 accepted ALLOC 的完整增量保留。故达到 ffff...ffff 后拒绝分配，不回卷；仍活跃的槽关系保持有效。generation32、ticket64 的饱和隔离也未修改。

上述矩阵不变量还与已有精确同 SHA 候选的独立原 u64 排序参考差分证据一致：原报告记录 12013 周期、234303 次检查及 reset/洞/同时事件/u64 耗尽边界。本次没有重复运行该差分或全帧回归。

## 本次真实执行结果

实际命令：

```text
python fpga/scripts/sim_full_integration.py --rtl-snapshot fpga/build/full_integration_20261013/delay_20261014_171555/source --cases tb_frame_memory_fabric tb_frame_ticket_rollover tb_video_memory_core --network-test
```

会话 51686 自然退出 0。产物为 `fpga/build/full_integration_20261013/sim_20261014_175002_330425`：

| 测试 | 原始日志结果 |
| --- | --- |
| tb_frame_memory_fabric | FRAME_MEMORY_FABRIC_PASS checks=28 |
| tb_frame_ticket_rollover | TB_FRAME_TICKET_ROLLOVER_PASS checks=6 |
| tb_video_memory_core | TB_VIDEO_MEMORY_CORE_PASS bytes=3465 good=3 processed=2 geometry_cycles=3792 |

网络场景为 35×33 小尺寸 fixture。原 runner 的 result.json 没有 network_test 字段，本审查没有改写原结果；实际命令、保存的 simulation_script.py 及 compiled VVP 中 `NETWORK_TEST=1` 三者共同证明该场景已启用。full_frame_simulation=false、hardware_tested=false，不把小回归或来源校验当作 routed STA/硬件验收。

[原始结果](/D:/XDU/concept/26-FPGA-Pango/fpga/build/full_integration_20261013/sim_20261014_175002_330425/result.json) · [复核完整证据](/D:/XDU/concept/26-FPGA-Pango/fpga/build/full_integration_20261013/sim_20261014_175002_330425/recovery_review_evidence.json) · [规范化实际差异](/D:/XDU/concept/26-FPGA-Pango/fpga/build/full_integration_20261013/sim_20261014_175002_330425/bank_normalized.diff)

本次没有失败案例。所有原始编译/运行日志、compiled images 和来源副本均保留，也没有清理此前任何失败证据。
