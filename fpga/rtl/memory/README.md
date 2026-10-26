# 正式帧管理与内部历史引用

2026-10-12。实现范围为专项 03 的 DDR 域控制逻辑；原 `mini_frame_pool.v` 保持诊断用途。当前板级核心使用三银行和六个 DMA 客户端。布局、外部 epoch/frame_id、网络头及 HDMI 来源规则沿用 `output/OV5640_RAW8千兆网与HDMI双路回传方案.md`。

## 文件与边界

- `frame_manager_pkg.sv`：内部命令、回应与描述符类型；不是网络/UART 序列化格式。
- `frame_manager_layout.vh`：由 `fpga/scripts/generate_frame_manager_layout.py` 从上述类型生成的同宽字段偏移，供综合核心使用；仿真/构建入口先重新生成它。
- `frame_pool_bank.sv`：独立槽所有权、消费者待领取位/引用位、分配顺序、generation、事务 token/ticket 与栅栏。
- `frame_manager.sv`：三个独立 bank，固定 SRC/DST/RAW 各三槽。

全部端口属于同一个 DDR 用户时钟域。输入合法性来自 02，实际处理参数与结果合法性来自 06，事务接受/完成/取消排空由 04 适配，显示场边界由 05 提供，网络会话与实体回读由 07 提供。跨域应使用完整事务握手或 FIFO，不能把总线拆成单 bit 同步。

## 布局及描述符

| bank / 内部序号 | 槽数 | 首地址（byte） | 槽大小 | DDR stride（byte） |
| --- | --- | --- | --- | --- |
| SRC / 0 | 3 | 0x00000000 | 8 MiB | 6144 |
| DST / 1 | 3 | 0x01800000 | 8 MiB | 6144 |
| RAW / 2 | 3 | 0x03000000 | 4 MiB | 2048 |

总区间结束于 0x03C00000，描述符/参数实体/有效掩码另算。实际 DDR 容量及原生接口可见性仍须验收。所有地址都是 byte 地址；适配器负责唯一的 beat 地址转换。基线接受非零且不超过 1920×1080 的尺寸、固定对应 stride，以及 RAW8=1/RGB888=2 的现有格式值；不包含裁剪/缩放实现。非法尺寸/格式会拒绝分配，不能写超槽。

描述符记录 u64 epoch/frame_id、采集首末时间，ISP/几何/增强实际版本，标定/参数/姿态实体引用，模式、stride、宽高、格式、stage、增强位置、姿态关联状态及错误。字段由上游锁定，`seal` 只提交最后时间与错误；处理中途不能修改版本。消费者获取时返回整份原子描述符。

实体编号必须指向集成方维护、可读回且保留足够寿命的不可变实体内容；本模块没有参数实体数据库，也不分配外部 descriptor_id。内部 bank、消费者、owner 编号不是外部协议枚举。stage/增强位置/姿态状态从上游原样携带，不另定义不兼容编码。

## 命令及所有权

扁平总线第 `bank` 份切片为 `[bank*CMD_BITS +: CMD_BITS]` / `[bank*RSP_BITS +: RSP_BITS]`，按 package 的 packed 类型解释。每条操作 lane 在上升沿采样；`valid && 对应接受信号` 才执行一次。持续 valid 每次接受代表一个新事务，不代表重试前一笔。

| 操作 | 接受信号 | 契约 |
| --- | --- | --- |
| alloc | alloc_ready | 锁住元数据与消费者待领取位，返回槽、generation、byte 首地址 |
| seal | seal_ok | 生产者不再提交新写事务；合法帧且全部写 drain 后才可 READY |
| cancel | cancel_ok | 阻止新读写，清待领取位，保留已持有引用和全部在途事务 |
| acquire[消费者] | acquire_ok[消费者] | 清该槽待领取位、置该消费者引用位，返回槽/代次/描述符 |
| release_mask[消费者] | release_ok[消费者] | 清确切槽/代次的已持有引用；在途事务仍保护该槽 |
| skip_mask[消费者] | skip_ok[消费者] | 只允许网络/内部历史显式放弃尚未领取的副本，计入 skipped |
| issue | issue_ready | 接受一笔属于当前槽/代次/owner 的事务，返回 token/ticket |
| complete | complete_ok | 唯一 token/ticket 对应事务达到 drain 栅栏；重复/迟到响应拒绝 |

消费者 0/1/2/3 分别为处理/显示/网络/内部历史；事务 owner=0 为生产者写，owner=消费者+1 为消费者读。每槽每消费者只有一个 pending 和一个 owned 位；同一消费者不能重复领取同一槽，重复释放会拒绝。不同消费者可同周期领取同一 READY 槽。

普通 acquire 选择该消费者最早分配且仍待领取的帧；前帧尚未 READY 时等待，不能跳到后一个先完成的帧。内部 u64 分配序号不替代源 frame_id，跨源 epoch 切换也保留真实入池顺序。HISTORY 也遵守最早待领取顺序，旧精确槽选择字段已删除。

显示 acquire 还需 `display_boundary=1`，该信号必须是已正确跨域的真实输出场边界。释放旧显示槽后仍需等它的读 drain；场边界和预取到场边界的服务期限由 05 验证。普通 HDMI 回采来源继续 null/unverified。

READY、消费者领取及槽回收互相独立。分配、提交、多个消费者领取/释放、issue/complete 可以重叠，不由一个跨帧长 FSM 串行处理；各池独立推进。当前无“释放当拍直接重分配”旁路：最后引用/响应消失后，先注册回收，再接受新分配，避免组合环路。

## 04 必须落实的事务契约

每 bank 默认最多 8 笔在途事务，可配置 1..8；槽数只能配置 1..3。8 是控制表上限，适配器仍须限制到原生控制器已证明支持的实际能力。`issue` 接受发生在适配器开始允许 DDR 访问之前，适配器随后保存 bank、slot、generation、owner、token、ticket。不能先发 DDR 请求再补记账，也不能只计最后一笔突发。

`complete` 的含义是该事务所有数据/错误/取消响应已排空，写数据达到允许后续消费者观察的可见性栅栏。它不是地址 ready、最后像素、最后发送触发或常量 BVALID。每笔唯一退休一次；允许不同 token 的响应乱序只说明控制层可以对应，不能据此声称原生 DDR 支持乱序。

事务 ticket 在每次 token 复用时增加，即使同一槽 generation 没变也可识别重复完成。slot generation、token ticket、分配顺序均不回绕：到全 1 后停止复用，须报告维护状态并在全 fabric 排空后重启。32 bit ticket 的寿命按实际事务粒度/速率验收，不能默认无限持续运行。bank 通过精确 token 表归约在途读写数，避免 issue 与 complete 同周期更新同一计数导致丢数。

非法 seal/cancel/issue/complete/release/skip 会置 `rejected`，每个错误周期递增 rejected_cycles，不作用于其他槽。队列满/无空槽/尚未 READY 属于等待，不能伪装成功；网络或不可暂停输入如何判整帧失败由集成层明确计数。错误响应使整槽无效、清 pending，并保留旧引用直到消费端释放。

`reset_n` 仅用于全 fabric 冷复位。必须停止新请求、排空或硬件清除所有 DDR/CDC 旧响应后，再复位并释放 `fabric_ready`。运行中不能仅复位帧池或把 fabric_ready 拉低而继续响应；本模块不会凭本地复位证明外部事务消失。PC 重连不是冷复位，不更新源 epoch，不伪造历史源身份。

## 内部 HISTORY 引用

消费者 3 为 HISTORY，只保留 SRC 上一帧 S1，不分配专用 bank，也没有 PC 触发或网络导出。
调度器按本帧配置登记 pending；正常处理结束后释放旧引用、核对 FIFO 领取的当前源身份，
在源 PROCESS 引用释放前转为历史持有。失效或取消在几何读取排空后 release/skip，
不能因开关变化提前回收在途历史 DMA。源序号不连续、配置/epoch 改变则拒绝使用旧历史。
空闲且帧池有压力时优先释放历史；历史丢弃计数不能冒充 DVP 完整帧率。

每条命令 lane 仍只有一个写入者，DMA fabric 独占 issue/complete，主调度独占生命周期。
帧池的 generation、64-bit ticket、所有权与取消排空语义不变。

## 回归及接入顺序

```powershell
./fpga/scripts/sim_frame_manager.ps1
./fpga/scripts/sim_frame_manager.ps1 -Case manager -Seed 7
./fpga/scripts/build_frame_manager_bench.ps1 -Stage synthesize
```

Icarus 路径可用 `-IcarusHome` 指定。脚本保存实际编译/仿真退出码、seed、源码 SHA256 与日志；编译器异常退出即使生成可运行文件也不算完整通过。Windows 沙箱若导致工具异常，应在已授权的正常本机执行环境核验，不能忽略退出码。

正式接入前：04 证明原生 drain/cancel/字节地址转换 → 02/06 绑定合法性和按帧身份/参数 → 05 场边界消费者与服务期限 → 07 网络整帧失败、快照 BUSY、实体回读 → 同配置目标器件综合/PnR/整机回归。专项独立 benchmark 只保留控制字段，没有原生 DDR/IP、快照控制器、板级引脚或跨域链路，不生成位流、不解除既有下载/温度告警条件。
