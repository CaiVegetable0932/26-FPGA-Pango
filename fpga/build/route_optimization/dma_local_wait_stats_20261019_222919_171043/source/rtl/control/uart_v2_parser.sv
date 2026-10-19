`timescale 1ns/1ps
// 2048B bounded ring, independent of outgoing transactions. Bad length/version/
// CRC/absolute 30ms deadline discards ONE candidate byte and rescans remaining
// buffered bytes, including nested magic. Payload magic never restarts a valid
// candidate. UART cannot backpressure: overflow flushes the ring and is explicit.
// Packet payload is borrowed until packet_ready, through a synchronous read port.
module uart_v2_parser #(parameter TIMEOUT_US=30000,WIRE_VERSION=2)(
 input clk,input rst_n,input [63:0] now_us,input byte_valid,input [7:0] byte_data,
 input byte_error,
 output packet_valid,input packet_ready,output reg [7:0] cmd,
 output reg [15:0] seq,length,output reg [63:0] receive_us,
 input read_valid,input [9:0] read_index,output reg read_response,output reg [7:0] read_data,
 output reg [31:0] bad_crc,bad_header,timeouts,overflows,
 output reg [11:0] peak_bytes
);
 localparam FETCH=0,EVAL=1,HOLD=2,COMMIT=3;
 reg [1:0] state;
 reg [11:0] head,tail,scan;
 reg [10:0] offset;
 reg [7:0] bytes_mem [0:2047];
 reg [31:0] times_mem [0:2047];
 reg [7:0] q;reg [31:0] qt,first_us;
 // Precompute the modulo32 deadline at the same edge as first_us. When the
 // interval wraps, its complement lies between deadline and first_us;
 // otherwise expiration is outside [first_us,deadline). This preserves even
 // backward timestamps and the exact >= boundary of unsigned age arithmetic.
 // Unusual negative/wider parameter overrides retain the original expression.
 localparam USE_DEADLINE=(TIMEOUT_US>=0 && TIMEOUT_US<=64'h00000000ffffffff);
 localparam [31:0] TIMEOUT_LOW32=TIMEOUT_US;
 reg [31:0] deadline_us;reg deadline_wrap;
 wire [32:0] first_deadline_sum={1'b0,qt}+{1'b0,TIMEOUT_LOW32};
 wire arrival_expired=USE_DEADLINE ?
  (deadline_wrap ? (qt>=deadline_us && qt<first_us) : (qt>=deadline_us || qt<first_us)) :
  ((qt-first_us)>=TIMEOUT_US);
 wire waiting_expired=USE_DEADLINE ?
  (deadline_wrap ? (now_us[31:0]>=deadline_us && now_us[31:0]<first_us) :
                   (now_us[31:0]>=deadline_us || now_us[31:0]<first_us)) :
  ((now_us[31:0]-first_us)>=TIMEOUT_US);
 reg [15:0] crc,wire_crc;
 wire [11:0] occupancy=tail-head;
 reg expired_wait;
 wire expired=offset!=0 && expired_wait && state==FETCH && scan==tail;
 assign packet_valid=state==HOLD;
 function automatic [15:0] crc_byte(input [15:0] c,input [7:0] b);
  reg [15:0] v;integer i;
  begin v=c^{b,8'd0};for(i=0;i<8;i=i+1) v=(v<<1)^(v[15]?16'h1021:0);crc_byte=v;end
 endfunction
 // Independent read port holds payload storage until consumer ACK. Consumers
 // must request only indices < length and honor read_response on the next edge.
 always @(posedge clk) begin
  read_response<=read_valid && packet_valid && read_index<length;
  if(read_valid && packet_valid && read_index<length)
   read_data<=bytes_mem[(head+12'd8+read_index)&12'h7ff];
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=FETCH;head<=0;tail<=0;scan<=0;offset<=0;q<=0;qt<=0;first_us<=0;deadline_us<=0;deadline_wrap<=0;
   crc<=16'hffff;wire_crc<=0;cmd<=0;seq<=0;length<=0;receive_us<=0;
   bad_crc<=0;bad_header<=0;timeouts<=0;overflows<=0;peak_bytes<=0;expired_wait<=0;
  end else begin
   // Deadline observation is registered; buffered bytes are judged by their
   // actual arrival times in EVAL. Processing latency never renews the deadline
   // or falsely rejects a complete packet received before it.
   expired_wait<=offset!=0 && waiting_expired;
   if(occupancy>peak_bytes) peak_bytes<=occupancy;
   if(byte_valid) begin
    bytes_mem[tail[10:0]]<=byte_data;times_mem[tail[10:0]]<=now_us[31:0];tail<=tail+1'b1;
   end
   if(byte_error || (byte_valid && occupancy==2048)) begin
    // Discontinuity invalidates candidate and queued bytes; do not deliver a
    // CRC-valid fragment assembled across an unobserved lost serial byte.
    overflows<=overflows+1;head<=tail+byte_valid;scan<=tail+byte_valid;offset<=0;state<=FETCH;
   end else if(packet_valid) begin
    if(packet_ready) begin head<=head+length+10;scan<=head+length+10;offset<=0;state<=FETCH;end
   end else if(state==COMMIT) begin
    // One service stage isolates CRC/deadline acceptance from a wide timestamp
    // register enable. Low32 arrival is exact; only a possible high32 borrow
    // must be reconstructed, avoiding two chained 64-bit subtractions.
    state<=HOLD;
    receive_us<={now_us[63:32]-{31'd0,(now_us[31:0]<qt)},qt};
   end else if(expired) begin
    timeouts<=timeouts+1;head<=head+1'b1;scan<=head+1'b1;offset<=0;state<=FETCH;
   end else if(state==FETCH) begin
    if(scan!=tail) begin q<=bytes_mem[scan[10:0]];qt<=times_mem[scan[10:0]];state<=EVAL;end
   end else begin
    state<=FETCH;scan<=scan+1'b1;offset<=offset+1'b1;
    if(offset==0) begin
     first_us<=qt;deadline_us<=first_deadline_sum[31:0];deadline_wrap<=first_deadline_sum[32];crc<=16'hffff;
     if(q!=8'h55) begin head<=head+1'b1;offset<=0;end
    end else if(arrival_expired) begin
     timeouts<=timeouts+1;head<=head+1'b1;scan<=head+1'b1;offset<=0;
    end else if(offset==1 && q!=8'haa || offset==2 && q!=WIRE_VERSION) begin
     bad_header<=bad_header+1;head<=head+1'b1;scan<=head+1'b1;offset<=0;
    end else begin
     if(offset>=2 && (offset<8 || offset<length+8)) crc<=crc_byte(crc,q);
     case(offset)
      3: cmd<=q;
      4: seq[7:0]<=q;
      5: seq[15:8]<=q;
      6: length[7:0]<=q;
      7: begin
       length[15:8]<=q;
       if({q,length[7:0]}>1024) begin
        bad_header<=bad_header+1;head<=head+1'b1;scan<=head+1'b1;offset<=0;
       end
      end
      default: begin end
     endcase
     if(offset==length+8 && offset>=8) wire_crc[7:0]<=q;
     if(offset==length+9 && offset>=9) begin
      if({q,wire_crc[7:0]}==crc) begin
       state<=COMMIT;
      end
      else begin bad_crc<=bad_crc+1;head<=head+1'b1;scan<=head+1'b1;offset<=0;end
     end
    end
   end
  end
 end
endmodule
