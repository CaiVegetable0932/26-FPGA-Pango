# 环形 LUT RAM 与帧元数据只读复核（2026-10-14）

审查完成时点：2026-10-14 16:36:04 +08:00。以下 SHA 为根代理修正历史引用注释前，本审查实际读取的 frozen/live 原始字节身份；后续正式源码的单独注释修订不属于上述哈希，正在运行的冻结来源、模型与数据库保持原始身份。

复核结论：在本次三个受影响模块及实际集成连接中，未发现新增功能问题。此结论来自源码审查和已有验证证据的核对，不代表布线后时序或实板验证通过。本次没有修改实现，没有启动综合、仿真、PnR，也没有停止进程。

## 实际源码身份

以下文件的正式源码、`delay_20261014_153410/source` 和 `verilator_20261014_153449_518851/source` 三处 SHA256 全部相同：

| 文件（相对 fpga/） | SHA256 |
| --- | --- |
| rtl/memory/frame_pool_bank.sv | 2885a5979bdf5d60f444cc82ec340d7e65e39da768109dc4bc2a3e6f2a860f71 |
| rtl/geometry/perspective_divide.sv | 7284d8bb312cad515d08795383435472a84988b5b946dd80daa5609e1f890ec4 |
| rtl/geometry/lens_inverse_map.sv | 6d35de5389983a1af174cb7f7ffc81a6bf94a058c280bfafa9f555842b5a6b28 |

## 延迟、停顿与复位

两个模块的写指针均为 5 bit；减法结果也限定为 5 bit，因此地址按模 32 回卷。各读地址与同时写地址的差始终非零，不依赖同址读写的器件行为。注册 RAM 读输出恰好替换原移位链末级：

| 通道 | 读地址 | 对应原移位链长度（CE 推进次数） |
| --- | --- | --- |
| 透视 q0/q1 | write−20 | 21 |
| 透视 tag | write−25 | 26 |
| 镜头 x/y | write−13 | 14 |
| 镜头 tag | write−22 | 23 |
| 镜头切向量 tx/ty | write−6 | 7 |

每次 `advance` 都推进，包含 `in_valid=0` 的气泡；没有错误地改成只按有效事务推进。非阻塞赋值使注册输出在第 L 次 CE 后取得第 1 次 CE 写入的数据，与原长 L 的移位链一致。镜头保留独立 `x_first/y_first`，故首级平方乘法也保留原输入延迟。

输出有效且下游未 ready 时，`advance=0`；指针、RAM 写、RAM 读输出、valid/ok 和原算术链保持。复位异步清除指针及原 valid/ok；RAM 和读输出不清零，且 RAM 读写在复位期间由 `rst_n && advance` 禁止。复位后的第一个有效输出必须先经过完整 26/23 次 CE 推进，相关读位置已由复位后的对应输入覆盖。

原乘法子模块仍只接 `advance`，复位期间内部无 reset 乘积可继续更新，这与替换前一致；不能表述为所有算术寄存器在复位时均停止。valid 清零及完整流水线暖机防止这些内部值成为有效输出。

## 失效数据和元数据遮挡

公开 `out_ok/out_mask` 没有与 `out_valid` 相与，这是已有 ready/valid 合同。实际连接遵守该合同：透视输出通过 `step_v` 输入镜头；缓存仅在 `map_v && map_r` 入队；缓存 refill 选择还受已入队的 query_valid、mask 等条件控制。不存在凭无效 tag/坐标直接发出 refill 的新增路径。数值错误但 valid 的像素保持 token 身份，`ok/mask` 屏蔽其采样，且 `geometry_rgb_pipeline` 在 `map_v && map_r && !map_ok` 记整帧失败。

`frame_pool_bank` 压缩及展开覆盖当前 `frame_meta_t` 的全部 19 个字段：17 个 immutable 字段合计 520 bit，另有 capture_last 64 bit 和 errors 32 bit，共 616 bit。拼接与展开使用同名宏和 `$bits`，没有裸位号错配；公开 cmd/rsp ABI 不变。schema 宽度检查会拒绝遗漏新增字段的总宽度变化。

多槽各消费者直接动态读取实际 RAM；单槽所有合法访问为地址 0，使用共享 held_descriptor。busy、sealed、legal、pending、refs、generation 在复位时清除；分配写入所有 immutable 和 mutable 字段后才安装有效 ownership。SEAL 和 acquisition 分别受 slot/generation/busy 及 frame_ready 等检查约束，非法或未选择地址的未知读值不进入有效响应。fabric_ready=0 时所有操作 ACK 和 descriptor payload 清零，只有原诊断信息保留。

## 已有证据核对

- `srl_20261014_152717/simulation`：9988 次透视差分事务和 4096 点深度域日志 PASS；candidate SHA 与正式透视源码相同。
- `lens_delay_20261014_153232/simulation`：9939 次镜头差分事务 PASS，包含长停顿、气泡、地址回卷及两次中途复位。该单元 candidate SHA 为 ee4a375f52cba5dc711714376c0cdfff54107dbaa9417c15a817f5562d1e8e93；与正式源码的唯一差别为默认 TAG_BITS=32/192。测试双方以及实际集成均显式使用 TAG_BITS=32，默认值恢复没有改变这些实例的硬件。
- `sim_20261014_153554_333469/result.json`：透视域、projective stepper、geometry frame processor、frame memory fabric、ticket rollover 和 video memory core 共 6 项 PASS。
- `verilator_20261014_153449_518851/result.json` 和 run.log：full_frame/snapshot/control/snapshot_intact 为 true，3 good/3 processed，6220800 字节检查，geometry_cycles=4014191。hardware_tested=false。
- `host/reports/fpga_rgb_vectors_20261014_154849_807880.json`：8888 包、12441600 RGB 字节和两份同源描述符核对 PASS；hardware_tested=false，hdmi_source_verified=false。没有把合成模型结果当作硬件验证。

## 一处非功能性引用残留

正式 `perspective_divide.sv` 第 16 行注释仍引用 ADS §5.19，隔离探针 result.json 的 official_section 也保留该历史字段；当前环形实现实际使用 `syn_ramstyle="lut_ram"`，应引用 §5.16。安装版本官方 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/ADS_Synthesis_User_Guide.pdf` 的既有只读摘录 `fpga/build/full_integration_20261013/reference/ADS_Synthesis_User_Guide.txt` 确认 §5.16 为 SYN_RAMSTYLE，§5.19 为 SYN_SRLSTYLE。本审查仅记录该注释问题，不改变冻结源码或历史测量证据。
