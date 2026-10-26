`timescale 1ns/1ps
// 用途：仅依据 SCL/SDA 边沿模拟 OV5640 寄存器读写，验证 repeated START 和末字节 NACK。
// Optional group latch is synthetic; optical response and real frame timing are not modeled.
module ov5640_sccb_model #(parameter GROUP_MODEL=0,FRAME_NS=50000)(
    input wire reset_n, scl, inout wire sda,
    input wire [3:0] nack_byte, input wire nack_read_address,
    output integer starts, stops, writes, reads, master_nacks
);
    reg [7:0] memory [0:65535];
    // Optional synthetic frame latch models the documented buffered group,
    // not the board's actual optical exposure timing. Tests may hold launch.
    reg group_holding=0,group_ended=0,group_pending=0,group_latch_enable=1;
    reg [7:0] group_value[0:4];reg [4:0] group_written=0;
    integer group_latches=0;
    task store_byte(input [15:0] addr,input [7:0] val);
      integer slot;
      begin
        if(GROUP_MODEL && addr==16'h3212)begin
          if(val==0)begin group_holding=1;group_ended=0;group_written=0;memory[16'h3213]=8'h20;end
          else if(val==8'h10 && group_holding)begin group_holding=0;group_ended=1;memory[16'h3213]=0;end
          else if(val==8'ha0 && group_ended)begin group_pending=1;memory[16'h3213]=8'h10;end
          else $fatal(1,"MODEL illegal group ordering");
        end else if(GROUP_MODEL && group_holding)begin
          case(addr)16'h3500:slot=0;16'h3501:slot=1;16'h3502:slot=2;16'h350a:slot=3;16'h350b:slot=4;
            default:begin slot=0;$fatal(1,"MODEL non-exposure write in group");end endcase
          group_value[slot]=val;group_written[slot]=1;
        end else memory[addr]=val;
      end
    endtask
    always begin
      #(FRAME_NS);
      if(GROUP_MODEL && reset_n && group_pending && group_latch_enable)begin
        if(group_written!=31)$fatal(1,"MODEL incomplete exposure group launch");
        memory[16'h3500]=group_value[0];memory[16'h3501]=group_value[1];memory[16'h3502]=group_value[2];
        memory[16'h350a]=group_value[3];memory[16'h350b]=group_value[4];
        group_pending=0;group_ended=0;memory[16'h3213]=0;group_latches=group_latches+1;
      end
    end
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
                4:if(nack_byte!=4)begin store_byte(pointer,shift); writes=writes+1; end
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
        group_holding=0;group_ended=0;group_pending=0;group_written=0;group_latches=0;
        active=0;drive=0;sending=0;starts=0;stops=0;writes=0;reads=0;master_nacks=0;
    end
endmodule
