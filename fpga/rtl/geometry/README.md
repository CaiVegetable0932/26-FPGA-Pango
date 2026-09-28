# 几何矫正独立单元（开发中）

本目录按 `output/PG2L100H_1080p畸变矫正详细设计方案.md` §6 的输出坐标逆映射实现。当前是可仿真的 RTL 算法单元，**没有接入 `mini_raw8_dual`、DDR 图块缓存或 HDMI 输出，不是已上板实时矫正版本**。稳定 RAW8 双路板级位流保持不变。参考模型位于 `fpga/model/geometry_reference.py`，测试脚本为 `fpga/scripts/sim_geometry.ps1`。

## 数据和计算合同

1. `geometry_frame_control` 接受 14 个小端意义的 32 位有符号参数字：`a00,a01,a02,a10,a11,a12,k1,k2,p1,p2,fx,fy,cx,cy`，在 `config_words` 中从最低位到最高位依次排列。前 10 个为 S(32,26)，末 4 个为 S(32,16)。仿射系数把输出像素坐标映射到理想归一化源坐标；畸变系数和源相机内参作用于该坐标。有效载荷只进入影子寄存器，下一次 `frame_start` 才替换整组活动参数和版本。拒绝非正/过大焦距、越域主点及畸变系数。当前并未实现 PC UART 参数命令的字段解析、长度/CRC、完整标定范围审查或读回 ACK；不能把并行载荷接口视为外部控制协议已交付。
2. `geometry_inverse_map` 用径向 `k1,k2` 与切向 `p1,p2` 计算源坐标，再输出双线性所需的 `x0,x1,y0,y1` 和两个 12 位小数。源坐标必须在 `[0,W-1]×[0,H-1]` 内；最后一行/列重复邻居；越界给 `source_valid=0`，不允许由无效输出访问 DDR。`result_valid` 对应一次输入请求的下一拍。未来顶层必须使 `frame_start` **至少早于本帧首个 `request_valid` 一拍**，并在整帧保持参数不变。归一化坐标当前限制 `|x|,|y|≤4`，未对所有合法参数组合做乘法中间值/单调性的完整审查。
3. `geometry_bilinear_rgb` 使用同一源帧的四个 RGB888 邻域做各通道 12+12 位双线性，仅最终舍入一次。`source_valid=0` 时输出黑色并保留无效标记。四邻域必须由将来的缓存/DDR 调度器提供，本模块不处理 RAW8 Bayer 去马赛克、随机存储访问、强缩小时的预滤波、帧描述符或有效掩码导出。

目前映射乘法为正确性优先的宽位组合实现，尚未流水化或完成 PDS 综合/布局布线/时序验收。不能据独立仿真声称满足 150 MHz 或 1080p30。正式接入前须先产生同帧 S1 RGB888，完成四邻域图块缓存和仲裁，给 S2/S3 独立帧池/描述符及 HDMI 读出，并在 PDS 检查资源、时序、带宽和实拍画质。

## 偏转角度 / MCU 留口

`geometry_frame_control` 的 `env_*` 端口对应现有 `output/FPGA_MCU通信协议V1.md` 的 `SUBMIT_ENVIRONMENT`：`angle_mdeg` 是有符号毫度，`measurement_valid[1]` 表示实测角度有效，`epoch/session_id/event_seq` 表示来源与顺序，`board_time_us` 是 FPGA 接受时刻。`mcu_context_valid/mcu_epoch/mcu_session_id` 必须由当前会话状态提供；epoch 或 session 改变会撤销旧角度，即使还没有新的环境事件。已有 `mcu_protocol.v` 会做 UART 帧、CRC、会话和事件检查，但其当前对外端口尚未暴露当前 session_id；将来连接时需增加只读会话输出或等价适配。实际 MINI 顶层当前仍将环境事件输出悬空。独立 MCU UART 还必须明确器件 IO 电平/引脚并完成 CDC，不得与板载 CP2102 控制口无仲裁并接。

有效/失效角度事件只在帧边界更新活动元数据，失效事件会清除 `active_angle_valid`。当前**不使用该角度旋转图像**：MCU 实测轴向/零位尚未标定，接受时间也不是相机曝光中心；直接作为逆映射角会给出错误补偿。后续需冻结轴与正方向、标定延迟/曝光时刻、按源帧配对或插值姿态，再把经验证的逆旋转仿射系数装载到参数影子寄存器，同时记录生效帧号。PC 手动演示角度可由参考模型生成系数，但同样不能冒充 MCU 实测同步补偿。

## 验证范围与参考

运行 `./fpga/scripts/sim_geometry.ps1`：ModelSim 验证恒等映射末行/末列、`k1/k2/p1/p2`、仿射旋转、越界和黑色掩码、RGB 插值与按帧提交；独立 Python 浮点参考在真实 1080p 参数域抽样比较定点量化误差。该参考仅用于离线验证，不能放在 host 实时矫正路径。已只读核对 PDS 2022.2-SP6.4 的 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Simulation_User_Guide.pdf`（ModelSim vlog/vsim 参数用法）与 `reference/盘古100K200K MINI开发板/1_Demo_document/实验例程说明篇/教程1_盘古MINI系列开发板硬件指导手册_V1.3.pdf`（PG2L100H MINI 器件）；两处原始资料均未写入。
