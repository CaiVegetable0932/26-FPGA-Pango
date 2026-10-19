// 用途：OV5640 单字节读写；请求锁存、双线开漏、ACK/NACK 与有界拉伸。
// 读使用 0x78 + 16-bit 地址 + repeated START + 0x79 + 数据 + 主机 NACK。
// 参考 Linux OV5640 两消息读事务；实物响应与电平尚需验证。
`timescale 1ns/1ps
module SCCB #(
    parameter DEV_ADDR = 8'h78,
    parameter SYS_CLK = 27000000,
    parameter SCCB_CLK = 100000,
    parameter STRETCH_TIMEOUT = 270000
)(
    input wire clk, input wire rst_n, input wire sccb_start,
    input wire [23:0] data_in, input wire sccb_read,
    inout wire SCL, inout wire SDA,
    output reg sccb_done, output reg sccb_error, output reg busy,
    output reg [7:0] read_data, output reg [1:0] error_code
);
    // 四个阶段构成一个数据位；向上取整保证实际 SCL 不高于指定频率。
    localparam Q = (SYS_CLK + 4*SCCB_CLK - 1)/(4*SCCB_CLK);
    localparam IDLE=0, START=1, BIT_SETUP=2, BIT_RISE=3, BIT_HIGH=4, BIT_FALL=5,
               ACK_SETUP=6, ACK_RISE=7, ACK_HIGH=8, ACK_FALL=9,
               STOP_SETUP=10, STOP_HIGH=11, STOP_RELEASE=12,
               RESTART_SETUP=13, RESTART_HIGH=14,
               RX_SETUP=15, RX_RISE=16, RX_HIGH=17, RX_FALL=18,
               NACK_SETUP=19, NACK_RISE=20, NACK_HIGH=21, NACK_FALL=22;
    reg [4:0] state;
    reg read_latched, read_address;
    reg [31:0] divider, stalled;
    reg [31:0] payload;
    reg [2:0] bit_index;
    reg [1:0] byte_index;
    reg scl_low, sda_low;
    (* syn_preserve=1 *) reg scl_meta, scl_sync, sda_meta, sda_sync;

    // 只下拉或者释放，绝不主动驱动高电平；依赖模组现有上拉，复位时释放总线。
    assign SCL = rst_n && scl_low ? 1'b0 : 1'bz;
    assign SDA = rst_n && sda_low ? 1'b0 : 1'bz;
    always @* begin
        scl_low = 1'b0; sda_low = 1'b0;
        case (state)
            START: sda_low = 1'b1;
            BIT_SETUP, BIT_FALL: begin scl_low=1'b1; sda_low=~payload[31]; end
            BIT_RISE, BIT_HIGH: sda_low=~payload[31];
            ACK_SETUP, ACK_FALL: scl_low=1'b1;
            RESTART_SETUP, RX_SETUP, RX_FALL, NACK_SETUP, NACK_FALL: scl_low=1'b1;
            STOP_SETUP: begin scl_low=1'b1; sda_low=1'b1; end
            STOP_HIGH: sda_low=1'b1;
            default: begin scl_low=1'b0; sda_low=1'b0; end
        endcase
    end

    // 外部开漏电平先同步再判定。字节 ACK 在高电平后半段采样，留出同步延迟。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_meta<=1; scl_sync<=1; sda_meta<=1; sda_sync<=1;
        end else begin
            scl_meta<=SCL; scl_sync<=scl_meta; sda_meta<=SDA; sda_sync<=sda_meta;
        end
    end

    // 空闲且总线已释放才能接受新请求；busy 期间不改变已锁存的数据。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; divider<=0; stalled<=0; payload<=0;
            bit_index<=7; byte_index<=0; sccb_done<=0; sccb_error<=0; busy<=0;
            read_latched<=0; read_address<=0; read_data<=0; error_code<=0;
        end else begin
            sccb_done<=0;
            if (state==IDLE) begin
                divider<=0; stalled<=0; busy<=0;
                if (sccb_start) begin
                    sccb_error<=0; error_code<=0; read_data<=0;
                    if (scl_sync && sda_sync) begin
                        payload<={DEV_ADDR, data_in}; bit_index<=7; byte_index<=0;
                        read_latched<=sccb_read; read_address<=0;
                        state<=START; busy<=1;
                    end else begin sccb_error<=1; error_code<=2; sccb_done<=1; end
                end
            end else if (!scl_low && !scl_sync) begin
                // SCL 尚未上升时冻结相位；故障超过上限即释放两线并报告失败。
                divider<=0;
                if (stalled>=STRETCH_TIMEOUT-1) begin
                    state<=IDLE; busy<=0; sccb_error<=1; sccb_done<=1; stalled<=0; error_code<=2;
                end else stalled<=stalled+1;
            end else begin
                stalled<=0;
                if (divider<Q-1) divider<=divider+1;
                else begin
                    divider<=0;
                    case (state)
                        START: state<=BIT_SETUP;
                        BIT_SETUP: state<=BIT_RISE;
                        BIT_RISE: state<=BIT_HIGH;
                        BIT_HIGH: state<=BIT_FALL;
                        BIT_FALL: begin
                            payload<=payload<<1;
                            if (bit_index==0) state<=ACK_SETUP;
                            else begin bit_index<=bit_index-1; state<=BIT_SETUP; end
                        end
                        ACK_SETUP: state<=ACK_RISE;
                        ACK_RISE: state<=ACK_HIGH;
                        ACK_HIGH: begin
                            case (sda_sync)
                                1'b0: sccb_error<=sccb_error;
                                default: begin sccb_error<=1; error_code<=1; end
                            endcase
                            state<=ACK_FALL;
                        end
                        ACK_FALL: begin
                            // 读指针阶段发三个字节，重复 START 后只发读设备地址。
                            if(sccb_error) state<=STOP_SETUP;
                            else if(read_latched && read_address) begin
                                bit_index<=7; state<=RX_SETUP;
                            end else if(read_latched && byte_index==2) begin
                                payload<={DEV_ADDR[7:1],1'b1,24'b0};
                                bit_index<=7; read_address<=1; state<=RESTART_SETUP;
                            end else if(byte_index==3) state<=STOP_SETUP;
                            else begin byte_index<=byte_index+1; bit_index<=7; state<=BIT_SETUP; end
                        end
                        // 低电平释放 SDA，再升 SCL，最后下拉 SDA 构成重复 START。
                        RESTART_SETUP: state<=RESTART_HIGH;
                        RESTART_HIGH: state<=START;
                        RX_SETUP: state<=RX_RISE;
                        RX_RISE: state<=RX_HIGH;
                        RX_HIGH: begin read_data<={read_data[6:0],sda_sync}; state<=RX_FALL; end
                        RX_FALL: begin
                            if(bit_index==0) state<=NACK_SETUP;
                            else begin bit_index<=bit_index-1; state<=RX_SETUP; end
                        end
                        // 第九拍释放 SDA，主机对最后一个读字节发送 NACK。
                        NACK_SETUP: state<=NACK_RISE;
                        NACK_RISE: state<=NACK_HIGH;
                        NACK_HIGH: state<=NACK_FALL;
                        NACK_FALL: state<=STOP_SETUP;
                        STOP_SETUP: state<=STOP_HIGH;
                        STOP_HIGH: state<=STOP_RELEASE;
                        STOP_RELEASE: begin state<=IDLE; busy<=0; sccb_done<=1; end
                        default: begin state<=IDLE; busy<=0; sccb_error<=1; error_code<=2; sccb_done<=1; end
                    endcase
                end
            end
        end
    end
endmodule

