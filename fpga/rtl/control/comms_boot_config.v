// Purpose: CP2102-only commissioning gateway, separate from the MCU protocol.
// Before commissioning, accept one CRC-checked command 0x70 with 32 bytes:
// epoch LE64, source/destination MAC in wire order, source/destination IPv4
// in wire order, source/destination port LE16. Configuration is immutable until
// reset. The operator must provide a fresh epoch; no constant boot identity.
// After the complete ACK and idle guard, the physical UART belongs to the
// unchanged MCU endpoint (PC emulates an MCU). This is NOT confirmed MCU wiring.
// Purpose: keep TEST wire admission unchanged by default; the RAW8 board uses
// command 0x71 and marker RAW8 so old TEST commands cannot commission a camera.
module comms_boot_config #(parameter CLK_HZ=125000000,BAUD=115200,
 parameter [7:0] BOOT_COMMAND=8'h70,parameter [31:0] BOOT_MARKER=32'h54534554)(
 input wire clk,reset_n,uart_rx,input wire mcu_tx,
 output wire uart_tx,output reg configured,
 output reg [63:0] epoch,output reg [47:0] src_mac,dst_mac,
 output reg [31:0] src_ip,dst_ip,output reg [15:0] src_port,dst_port
);
 wire [7:0] rx_byte,command,error_code;
 wire [15:0] seq,length;wire [255:0] payload;
 wire byte_valid,framing_error,done,reply_allowed,tx_ready,config_tx;
 reg [2:0] state;
 localparam RECEIVE=0,SEND=1,DRAIN=2,GUARD=3,RUN=4;
 localparam integer GUARD_CYCLES=(CLK_HZ/BAUD+1)*24;
 reg [$clog2(GUARD_CYCLES)-1:0] guard_count;
 reg accepted,tx_valid;
 reg [7:0] reply_cmd;reg [15:0] reply_seq;reg [255:0] reply;
 wire flush=(state!=RECEIVE);
 assign uart_tx=configured?mcu_tx:config_tx;
 mcu_uart_rx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_rx(.clk(clk),.rst_n(reset_n),
  .flush(flush),.serial_rx(uart_rx),.data(rx_byte),.valid(byte_valid),.framing_error(framing_error));
 mcu_frame_rx #(.CLK_HZ(CLK_HZ)) u_parse(.clk(clk),.rst_n(reset_n),.flush(flush),
  .byte_data(rx_byte),.byte_valid(byte_valid),.framing_error(framing_error),
  .done(done),.reply_allowed(reply_allowed),.error_code(error_code),
  .command(command),.sequence_id(seq),.length(length),.payload(payload));
 mcu_frame_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_reply(.clk(clk),.rst_n(reset_n),
  .flush(1'b0),.valid(tx_valid),.ready(tx_ready),.command(reply_cmd),
  .sequence_id(reply_seq),.payload(reply),.serial_tx(config_tx));
 // Purpose: reject zero/multicast peers and malformed boot configuration;
 // no discovery packets or broadcasts are emitted to find a destination.
 reg [7:0] code;
 always @* begin
  code=error_code;
  if(error_code==0) begin
   if(command!=BOOT_COMMAND)code=6;
   else if(length!=32)code=3;
   else if(payload[63:0]==0 || payload[111:64]==0 || payload[159:112]==0 ||
      payload[64] || payload[112] ||
      payload[167:160]==0 || payload[167:160]>=224 ||
      payload[199:192]==0 || payload[199:192]>=224 ||
      payload[239:224]==0 || payload[255:240]==0)code=11;
  end
 end
 always @(posedge clk or negedge reset_n)begin
  if(!reset_n)begin
   state<=RECEIVE;configured<=0;accepted<=0;tx_valid<=0;guard_count<=0;
   epoch<=0;src_mac<=0;dst_mac<=0;src_ip<=0;dst_ip<=0;src_port<=0;dst_port<=0;
   reply<=0;reply_cmd<=0;reply_seq<=0;
  end else begin
   tx_valid<=0;
   case(state)
    RECEIVE:if(done && reply_allowed)begin
     reply<=0;reply[7:0]<=code;reply[15:8]<=command;reply[95:32]<=payload[63:0];
     // Marker identifies the built image/profile, not physical image-source proof.
     reply[191:160]<=BOOT_MARKER;reply_seq<=seq;reply_cmd<=(code==0)?8'h80:8'h81;
     accepted<=(code==0);state<=SEND;
     if(code==0)begin
      epoch<=payload[63:0];
      src_mac<={payload[71:64],payload[79:72],payload[87:80],payload[95:88],payload[103:96],payload[111:104]};
      dst_mac<={payload[119:112],payload[127:120],payload[135:128],payload[143:136],payload[151:144],payload[159:152]};
      src_ip<={payload[167:160],payload[175:168],payload[183:176],payload[191:184]};
      dst_ip<={payload[199:192],payload[207:200],payload[215:208],payload[223:216]};
      src_port<=payload[239:224];dst_port<=payload[255:240];
     end
    end
    SEND:if(tx_ready)begin tx_valid<=1;state<=DRAIN;end
    DRAIN:if(!tx_valid && tx_ready)begin guard_count<=0;state<=GUARD;end
    // frame_tx ready precedes the final UART stop bit; wait 24 whole bit times
    // before switching the output mux or allowing another configuration frame.
    GUARD:if(guard_count==GUARD_CYCLES-1)begin
     if(accepted)begin configured<=1;state<=RUN;end else state<=RECEIVE;
    end else guard_count<=guard_count+1'b1;
    RUN:begin end
    default:state<=RECEIVE;
   endcase
  end
 end
endmodule
