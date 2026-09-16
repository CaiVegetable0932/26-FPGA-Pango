`timescale 1ns/1ps
// 模块用途：reset_sync 为单个目标时钟域生成低有效复位，异步置位复位、同步解除复位。
// 接口约定：async_reset_n 拉低后立即拉低 reset_n；释放后需经过 STAGES 个 clk 上升沿。
// 参数限制：当前移位写法要求 STAGES >= 2，默认 3；调用方应结合时钟锁定/就绪信号控制输入。
// 每个目标时钟域应分别实例化本模块；它不是通用的数据跨时钟域同步器。
module reset_sync #(parameter STAGES = 3)(input wire clk, input wire async_reset_n, output wire reset_n);
    // 保留同步链寄存器：复位时全清零，随后逐级移入 1，避免复位撤销直接传到域内逻辑。
    (* syn_preserve = 1 *) reg [STAGES-1:0] stages;
    always @(posedge clk or negedge async_reset_n)
        if (!async_reset_n) stages <= {STAGES{1'b0}};
        else stages <= {stages[STAGES-2:0], 1'b1};
    // 仅最后一级对外释放复位，使使用者共享经过完整同步链的复位输出。
    assign reset_n = stages[STAGES-1];
endmodule
