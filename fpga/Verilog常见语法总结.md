# Verilog 常见语法总结

本文以 Verilog-2001 为主，整理 FPGA RTL 设计和仿真中常用的语法。

## 1. 模块定义

    module counter #(
        parameter WIDTH = 8
    )(
        input  wire             clk,
        input  wire             rst_n,
        input  wire             en,
        output reg  [WIDTH-1:0] count
    );
    endmodule

常见端口类型：

    input  wire a;
    output wire y;
    output reg  q;
    inout  wire io;

参数化模块：

    module adder #(
        parameter WIDTH = 8
    )(
        input  wire [WIDTH-1:0] a,
        input  wire [WIDTH-1:0] b,
        output wire [WIDTH:0]   y
    );

## 2. 数值、位宽与信号

基本格式为：位宽'进制数值。

    8'b1010_0101   // 二进制
    8'd165         // 十进制
    8'hA5          // 十六进制
    8'o245         // 八进制
    1'b0           // 0
    1'b1           // 1
    1'bx           // 未知
    1'bz           // 高阻

wire 用于连续赋值或模块连接，reg 用于过程块中的赋值：

    wire [7:0]  data;
    reg  [15:0] result;
    reg  [7:0]  memory [0:255]; // 256 个 8 位存储单元

位选和部分选择：

    data[3]       // 第 3 位
    data[7:4]     // 第 7 位到第 4 位
    data[3:0]     // 低 4 位

有符号数应显式声明：

    reg signed [7:0] a;

## 3. 常用运算符

    +  -  *  /  %             // 算术
    <  <=  >  >=              // 比较
    == !=                     // 逻辑相等
    === !==                   // case 相等，x/z 也参与比较
    && || !                   // 逻辑
    &  |  ^  ~                // 按位
    << >> <<< >>>             // 移位
    {a, b}                    // 拼接
    {4{1'b1}}                 // 重复，结果为 4'b1111

## 4. 连续赋值

assign 通常用于组合逻辑，左侧一般为 wire：

    assign y     = a & b;
    assign sum   = a + b;
    assign valid = en && ready;
    assign out   = sel ? a : b;

## 5. always 过程块

### 5.1 组合逻辑

    reg [7:0] y;

    always @(*) begin
        y = a + b;
    end

组合逻辑应给输出设置默认值，保证所有路径都有赋值，避免意外产生锁存器：

    always @(*) begin
        y = 8'd0;

        if (sel)
            y = a;
        else
            y = b;
    end

### 5.2 时序逻辑

异步低有效复位：

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            q <= 1'b0;
        else
            q <= d;
    end

同步低有效复位：

    always @(posedge clk) begin
        if (!rst_n)
            q <= 1'b0;
        else
            q <= d;
    end

## 6. 阻塞赋值与非阻塞赋值

阻塞赋值 = 通常用于组合逻辑，语句按顺序立即生效：

    always @(*) begin
        tmp = a + b;
        y   = tmp + c;
    end

非阻塞赋值 <= 通常用于时序逻辑，寄存器在同一个时钟沿更新：

    always @(posedge clk) begin
        q1 <= d;
        q2 <= q1;
    end

常用原则：

    组合逻辑：使用 =
    时序逻辑：使用 <=

## 7. if 与 case

    always @(*) begin
        if (mode == 2'd0)
            y = a;
        else if (mode == 2'd1)
            y = b;
        else
            y = 8'd0;
    end

    always @(*) begin
        case (sel)
            2'b00: y = a;
            2'b01: y = b;
            2'b10: y = c;
            default: y = 8'd0;
        endcase
    end

casez 可以把 z 或 ? 作为通配符：

    casez (irq)
        4'b1???: priority = 2'd3;
        4'b01??: priority = 2'd2;
        4'b001?: priority = 2'd1;
        default: priority = 2'd0;
    endcase

casex 会把 x 和 z 都作为通配符，可能掩盖仿真中的未知状态，RTL 中应谨慎使用。

## 8. 循环语句

    integer i;

    always @(*) begin
        for (i = 0; i < 8; i = i + 1) begin
            y[i] = a[i] & b[i];
        end
    end

while 和 repeat 更多用于仿真，能否综合取决于工具和具体写法：

    while (condition) begin
        ...
    end

    repeat (4) begin
        ...
    end

## 9. 模块例化

推荐使用显式端口连接：

    adder #(
        .WIDTH(8)
    ) u_adder (
        .a(a),
        .b(b),
        .y(y)
    );

不建议过度依赖位置连接：

    u_adder (a, b, y);

## 10. 状态机

    localparam IDLE = 2'd0,
               RUN  = 2'd1,
               DONE = 2'd2;

    reg [1:0] state;
    reg [1:0] next_state;

    // 状态寄存器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end

    // 次态逻辑
    always @(*) begin
        next_state = state;

        case (state)
            IDLE: begin
                if (start)
                    next_state = RUN;
            end
            RUN: begin
                if (finish)
                    next_state = DONE;
            end
            DONE: begin
                next_state = IDLE;
            end
            default:
                next_state = IDLE;
        endcase
    end

## 11. 计数器

    reg [7:0] count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            count <= 8'd0;
        else if (en) begin
            if (count == 8'd99)
                count <= 8'd0;
            else
                count <= count + 8'd1;
        end
    end

## 12. 锁存器、触发器与 RAM

D 触发器：

    always @(posedge clk) begin
        q <= d;
    end

带使能的触发器：

    always @(posedge clk) begin
        if (en)
            q <= d;
    end

下面的代码会产生锁存器：

    always @(*) begin
        if (en)
            q = d;
    end

简单 RAM：

    reg [7:0] mem [0:255];

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    assign rd_data = mem[rd_addr];

是否能够推断为 FPGA 块 RAM，取决于目标器件、综合工具和 RAM 描述方式。

## 13. function、task 与 generate

    function [7:0] add_one;
        input [7:0] data;
        begin
            add_one = data + 8'd1;
        end
    endfunction

    assign y = add_one(a);

    task display_data;
        input [7:0] data;
        begin
            $display("data = %h", data);
        end
    endtask

task 常用于测试平台，是否可综合应根据目标工具确认。

    genvar i;

    generate
        for (i = 0; i < 8; i = i + 1) begin : gen_and
            assign y[i] = a[i] & b[i];
        end
    endgenerate

## 14. 编译指令与仿真

    `timescale 1ns/1ps
    `define WIDTH 8
    wire [`WIDTH-1:0] data;

条件编译和常见系统任务：

    `ifdef SIMULATION
        initial begin
            $display("simulation only");
        end
    `endif

    $monitor("time=%t value=%h", $time, value);
    $finish;

#delay、initial、$display 等通常只用于仿真，不参与综合。

## 15. Testbench 基本结构

    `timescale 1ns/1ps

    module tb_counter;
        reg clk;
        reg rst_n;
        reg en;
        wire [7:0] count;

        counter u_counter (
            .clk(clk), .rst_n(rst_n), .en(en), .count(count)
        );

        initial begin
            clk = 1'b0;
            forever #5 clk = ~clk;
        end

        initial begin
            rst_n = 1'b0;
            en    = 1'b0;
            #20 rst_n = 1'b1;
            en = 1'b1;
            #100 $finish;
        end
    endmodule

## 16. 常见注意事项

1. 组合逻辑使用 always @(*)，时序逻辑使用 always @(posedge clk ...)。
2. 组合逻辑通常使用 =，时序逻辑通常使用 <=。
3. 组合逻辑必须覆盖所有赋值路径，避免意外产生锁存器。
4. 一个寄存器信号通常只应在一个 always 块中赋值。
5. 注意信号位宽，避免无意的截断或扩展。
6. 不要使用多个不同时钟驱动同一个时序逻辑。
7. 跨时钟域信号应使用同步器、握手协议或异步 FIFO。
8. 统一复位方式，明确使用同步复位还是异步复位。
9. case 语句最好包含 default 分支。
10. 位宽应尽量明确，例如 count <= count + 8'd1。
11. 注意 == 与 === 的差异，仿真中的未知值可能导致不同结果。
