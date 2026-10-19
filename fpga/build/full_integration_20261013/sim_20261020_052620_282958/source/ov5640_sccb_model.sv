`timescale 1ns/1ps
// 用途：仅依据 SCL/SDA 边沿模拟 OV5640 寄存器读写，验证 repeated START 和末字节 NACK。
// 不模拟光学响应、自动曝光或真正的帧锁存行为。
module ov5640_sccb_model(
    input wire reset_n, scl, inout wire sda,
    input wire [3:0] nack_byte, input wire nack_read_address,
    output integer starts, stops, writes, reads, master_nacks
);
    reg [7:0] memory [0:65535];
    reg active=0, drive=0, sending=0, read_address=0;
    integer bits=0, bytes=0, sent=0;
    reg [7:0] shift=0;
    reg [15:0] pointer=0;
    assign sda=drive ? 1'b0 : 1'bz;
    initial begin starts=0;stops=0;writes=0;reads=0;master_nacks=0;end
    always @(negedge sda) if(reset_n && scl===1'b1) begin
        active=1; sending=0; bits=0; bytes=0; shift=0; read_address=0; starts=starts+1;
    end
    always @(posedge sda) if(reset_n && active && scl===1'b1) begin
        active=0; stops=stops+1;
    end
    always @(posedge scl) if(reset_n && active) begin
        if(sending) begin
            if(sent==8) begin
                if(sda!==1'b1) $fatal(1,"OV5640_MODEL_EXPECTED_MASTER_NACK");
                master_nacks=master_nacks+1; reads=reads+1;
            end
            sent=sent+1;
        end else if(bits<8) begin
            shift={shift[6:0],sda}; bits=bits+1;
            if(bits==8) begin
                bytes=bytes+1;
                case(bytes)
                1: begin
                    if(shift!=8'h78 && shift!=8'h79) $fatal(1,"OV5640_MODEL_DEVICE_ADDRESS");
                    read_address=(shift==8'h79);
                end
                2:pointer[15:8]=shift;
                3:pointer[7:0]=shift;
                4:begin memory[pointer]=shift; writes=writes+1; end
                endcase
            end
        end else bits=0;
    end
    always @(negedge scl) begin
        if(!reset_n || !active) drive=0;
        else if(sending) begin
            if(sent<8) drive=~memory[pointer][7-sent]; else drive=0;
        end else if(bits==8) drive=(bytes!=nack_byte) && !(read_address && nack_read_address);
        else if(read_address && bytes==1) begin
            sending=1; sent=0; drive=~memory[pointer][7];
        end else drive=0;
    end
    always @(negedge reset_n) begin
        active=0;drive=0;sending=0;starts=0;stops=0;writes=0;reads=0;master_nacks=0;
    end
endmodule
