`timescale 1ns/1ps
// 用途：初始化和运行期有界 SCCB 仲裁；写必须在采集关闭且03/04在途事务已排空时执行。
// Generic writes retain read/modify/verify and the quiesced guard. Only the
// dedicated group FSM may request ACK-only whitelisted exposure writes.
module ov5640_register_service #(
 parameter SYS_CLK=27000000,SCCB_CLK=100000,STRETCH_TIMEOUT=270000,
 parameter SERVICE_TIMEOUT=2700000,
 // Optional identify-before-write initialization reads. Existing analog-table
 // callers keep write-only initialization through the default zero parameter.
 parameter INIT_READ_ENABLE=0, parameter GROUP_EXPOSURE_ENABLE=0
)(
 input wire clk,rst_n,input wire init_finished,init_start,input wire [23:0] init_data,
 input wire init_read,output wire [7:0] init_read_value,
 output wire init_end,output reg init_failed,
 // Trusted group writer is instantiated only behind the fixed exposure FSM.
 input wire cmd_group, input wire quiesced,input wire cmd_valid,output wire cmd_ready,
 input wire cmd_write,input wire [15:0] cmd_addr,input wire [7:0] cmd_value,cmd_mask,
 input wire [31:0] cmd_cookie,
 output reg cmd_rejected,rsp_valid,output reg [2:0] rsp_status,
 output reg [7:0] rsp_value,output reg [15:0] rsp_addr,output reg [31:0] rsp_cookie,
 inout wire SCL,SDA
);
 localparam IDLE=0,READ_SEND=1,READ_WAIT=2,WRITE_SEND=3,WRITE_WAIT=4,
  VERIFY_SEND=5,VERIFY_WAIT=6;
 reg [2:0] state;reg start,read_op,abort_bus;
 reg [23:0] payload;
 reg group_latched;
 // Privileged path excludes timing, stream control and arbitrary registers.
 wire group_requested=GROUP_EXPOSURE_ENABLE && cmd_group;
 wire group_allowed=(cmd_addr>=16'h3500 && cmd_addr<=16'h3502) || cmd_addr==16'h350a || cmd_addr==16'h350b ||
  (cmd_addr==16'h3212 && (cmd_value==0 || cmd_value==8'h10 || cmd_value==8'ha0));
 reg write_latched;reg [7:0] value_latched,mask_latched,target;
 reg [31:0] deadline;
 wire done,error,busy;wire [7:0] returned;wire [1:0] bus_status;
 assign init_read_value=returned;
 assign cmd_ready=init_finished && !init_failed && state==IDLE && !busy && !abort_bus;
 assign init_end=!init_finished && done && !error;
 SCCB #(.SYS_CLK(SYS_CLK),.SCCB_CLK(SCCB_CLK),.STRETCH_TIMEOUT(STRETCH_TIMEOUT)) bus(
  .clk(clk),.rst_n(rst_n && !abort_bus),
  .sccb_start(init_finished ? start : (init_start && !init_failed)),
  .data_in(init_finished ? payload : init_data),
  .sccb_read(init_finished ? read_op : (INIT_READ_ENABLE ? init_read : 1'b0)),
  .SCL(SCL),.SDA(SDA),.sccb_done(done),.sccb_error(error),.busy(busy),
  .read_data(returned),.error_code(bus_status));
 // 状态0成功、1NACK、2超时/占用、3回读不符、5无效mask、6未排空、7只读/写专用寄存器。
 // cmd_valid 为脉冲；忙时仅 rejected，不污染正在返回的 cookie/地址。
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=IDLE;start<=0;read_op<=0;abort_bus<=0;payload<=0;deadline<=0;
   init_failed<=0;cmd_rejected<=0;rsp_valid<=0;rsp_status<=0;rsp_value<=0;
   rsp_addr<=0;rsp_cookie<=0;group_latched<=0;write_latched<=0;value_latched<=0;mask_latched<=0;target<=0;
  end else begin
   start<=0;abort_bus<=0;rsp_valid<=0;cmd_rejected<=cmd_valid && !cmd_ready;
   if(!init_finished && done && error)init_failed<=1;
   if(state!=IDLE)deadline<=deadline+1'b1;else deadline<=0;
   if(state!=IDLE && deadline>=SERVICE_TIMEOUT-1)begin
    // 看门狗复位总线主机，释放开漏线；不在等待状态永久挂起。
    abort_bus<=1;state<=IDLE;rsp_valid<=1;rsp_status<=2;
   end else case(state)
   IDLE:if(cmd_valid && cmd_ready)begin
    rsp_addr<=cmd_addr;rsp_cookie<=cmd_cookie;rsp_status<=0;rsp_value<=0;
    group_latched<=group_requested;write_latched<=cmd_write;value_latched<=cmd_value;mask_latched<=cmd_mask;
    if(group_requested && cmd_write)begin
     if(!group_allowed || cmd_mask!=8'hff)begin rsp_valid<=1;rsp_status<=7;end
     else begin target<=cmd_value;state<=WRITE_SEND;end
    end else if(cmd_write && !quiesced)begin rsp_valid<=1;rsp_status<=6;end
    else if(cmd_write && (cmd_addr==16'h300a || cmd_addr==16'h300b || cmd_addr==16'h3212))begin
     rsp_valid<=1;rsp_status<=7;
    end else if(cmd_write && cmd_mask==0)begin rsp_valid<=1;rsp_status<=5;end
    else state<=READ_SEND;
   end
   READ_SEND:begin payload<={rsp_addr,8'b0};read_op<=1;start<=1;state<=READ_WAIT;end
   READ_WAIT:if(done)begin
    rsp_value<=returned;
    if(error)begin rsp_valid<=1;rsp_status<={1'b0,bus_status};state<=IDLE;end
    else if(!write_latched)begin rsp_valid<=1;state<=IDLE;end
    else if(!quiesced)begin rsp_valid<=1;rsp_status<=6;state<=IDLE;end
    else begin target<=(returned & ~mask_latched) | (value_latched & mask_latched);state<=WRITE_SEND;end
   end
   WRITE_SEND:begin
    if(!quiesced && !group_latched)begin rsp_valid<=1;rsp_status<=6;state<=IDLE;end
    else begin payload<={rsp_addr,target};read_op<=0;start<=1;state<=WRITE_WAIT;end
   end
   WRITE_WAIT:if(done)begin
    if(error)begin rsp_valid<=1;rsp_status<={1'b0,bus_status};state<=IDLE;end
    // Group writes are only ACKed here; owner verifies after group launch.
    else if(group_latched)begin rsp_valid<=1;rsp_value<=target;state<=IDLE;end
    else state<=VERIFY_SEND;
   end
   VERIFY_SEND:begin payload<={rsp_addr,8'b0};read_op<=1;start<=1;state<=VERIFY_WAIT;end
   VERIFY_WAIT:if(done)begin
    rsp_value<=returned;rsp_valid<=1;state<=IDLE;
    if(error)rsp_status<={1'b0,bus_status};
    else if(!quiesced)rsp_status<=6;
    else if(returned!=target)rsp_status<=3;
   end
   default:begin state<=IDLE;abort_bus<=1;rsp_valid<=1;rsp_status<=2;end
   endcase
  end
 end
endmodule
