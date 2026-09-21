// Purpose: OV5640 16-bit-address SCCB write/read engine; open-drain, ACK checked, bounded SCL stretch.
// Derived from the project SCCB writer. Reads use address-write STOP, read-address, data, NA, STOP.
`timescale 1ns/1ps
module ov5640_sccb #(
    parameter DEV_ADDR = 8'h78,
    parameter SYS_CLK = 27000000,
    parameter SCCB_CLK = 100000,
    parameter STRETCH_TIMEOUT = 270000
)(
    input wire clk, input wire rst_n, input wire sccb_start,
    input wire [23:0] data_in, input wire read_enable, output reg [7:0] read_data,
    inout wire SCL, inout wire SDA,
    output reg sccb_done, output reg sccb_error, output reg busy
);
    // 四个阶段构成一个数据位；向上取整保证实际 SCL 不高于指定频率。
    localparam Q = (SYS_CLK + 4*SCCB_CLK - 1)/(4*SCCB_CLK);
    localparam IDLE=0, START=1, BIT_SETUP=2, BIT_RISE=3, BIT_HIGH=4, BIT_FALL=5,
               ACK_SETUP=6, ACK_RISE=7, ACK_HIGH=8, ACK_FALL=9,
               STOP_SETUP=10, STOP_HIGH=11, STOP_RELEASE=12, READ_SETUP=13, READ_RISE=14, READ_HIGH=15, READ_FALL=16,
               NACK_SETUP=17, NACK_RISE=18, NACK_HIGH=19, NACK_FALL=20;
    reg [4:0] state; reg read_request, read_phase;
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
            ACK_SETUP, ACK_FALL, READ_SETUP, READ_FALL, NACK_SETUP, NACK_FALL: scl_low=1'b1;
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
            state<=IDLE; divider<=0; stalled<=0; payload<=0; read_request<=0; read_phase<=0; read_data<=0;
            bit_index<=7; byte_index<=0; sccb_done<=0; sccb_error<=0; busy<=0;
        end else begin
            sccb_done<=0;
            if (state==IDLE) begin
                divider<=0; stalled<=0; busy<=0;
                if (sccb_start) begin
                    sccb_error<=0;
                    if (scl_sync && sda_sync) begin
                        payload<={DEV_ADDR, data_in}; bit_index<=7; byte_index<=0;
                        read_request<=read_enable; read_phase<=0; read_data<=0;
                        state<=START; busy<=1;
                    end else begin sccb_error<=1; sccb_done<=1; end
                end
            end else if (!scl_low && !scl_sync) begin
                // SCL 尚未上升时冻结相位；故障超过上限即释放两线并报告失败。
                divider<=0;
                if (stalled>=STRETCH_TIMEOUT-1) begin
                    state<=IDLE; busy<=0; sccb_error<=1; sccb_done<=1; stalled<=0;
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
                                default: sccb_error<=1;
                            endcase
                            state<=ACK_FALL;
                        end
                        ACK_FALL: begin
                            // 用途：NACK 立即停止；写入发四字节，读前地址阶段发三字节。
                            if (sccb_error) state<=STOP_SETUP;
                            else if (read_phase) begin bit_index<=7; state<=READ_SETUP; end
                            else if (byte_index==(read_request ? 2 : 3)) state<=STOP_SETUP;
                            else begin byte_index<=byte_index+1; bit_index<=7; state<=BIT_SETUP; end
                        end
                        STOP_SETUP: state<=STOP_HIGH;
                        STOP_HIGH: state<=STOP_RELEASE;
                        // Purpose: terminate the 16-bit address write before starting a separate read cycle.
                        STOP_RELEASE: begin
                            if (read_request && !read_phase && !sccb_error) begin
                                read_phase<=1; payload<={DEV_ADDR[7:1],1'b1,24'b0};
                                bit_index<=7; byte_index<=0; state<=START;
                            end else begin state<=IDLE; busy<=0; sccb_done<=1; end
                        end
                        // Purpose: release SDA for all eight sensor bits, then send a high NA/NACK bit.
                        READ_SETUP: state<=READ_RISE;
                        READ_RISE: state<=READ_HIGH;
                        READ_HIGH: begin read_data<={read_data[6:0],sda_sync}; state<=READ_FALL; end
                        READ_FALL: begin
                            if (bit_index==0) state<=NACK_SETUP;
                            else begin bit_index<=bit_index-1; state<=READ_SETUP; end
                        end
                        NACK_SETUP: state<=NACK_RISE;
                        NACK_RISE: state<=NACK_HIGH;
                        NACK_HIGH: state<=NACK_FALL;
                        NACK_FALL: state<=STOP_SETUP;
                        default: begin state<=IDLE; busy<=0; sccb_error<=1; sccb_done<=1; end
                    endcase
                end
            end
        end
    end
endmodule
