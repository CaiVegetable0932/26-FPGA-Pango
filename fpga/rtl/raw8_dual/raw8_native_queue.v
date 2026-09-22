// Purpose: ready/valid adapter for unmodified PDS-native async DRM FIFO IPs.
// Both domains must be reset together after outstanding DDR transactions drain;
// per-frame unilateral FIFO resets would corrupt pointers and are forbidden.
// Non-showahead RAM output is captured one read-clock after rd_en. One pending
// read plus one held word makes consumer backpressure safe without data loss.
module raw8_native_queue #(parameter WIDTH=256)(
 input wire wr_clk,wr_reset_n,input wire [WIDTH-1:0] in_data,
 input wire in_valid,output wire in_ready,output wire [9:0] wr_used,
 input wire rd_clk,rd_reset_n,output reg [WIDTH-1:0] out_data,
 output reg out_valid,input wire out_ready
);
 wire full,empty;wire [WIDTH-1:0] fifo_data;
 reg pending;
 wire pop=rd_reset_n && !empty && !pending && (!out_valid || out_ready);
 assign in_ready=wr_reset_n && !full;
 generate if(WIDTH==256)begin:g_words
  raw8_word_cdc u_fifo(.wr_clk(wr_clk),.wr_rst(!wr_reset_n),
   .wr_data(in_data),.wr_en(in_valid && in_ready),.wr_full(full),.wr_water_level(wr_used),
   .rd_clk(rd_clk),.rd_rst(!rd_reset_n),.rd_en(pop),.rd_data(fifo_data),
   .rd_empty(empty),.rd_water_level(),.almost_full(),.almost_empty());
 end else if(WIDTH==288)begin:g_records
  raw8_capture_cdc u_fifo(.wr_clk(wr_clk),.wr_rst(!wr_reset_n),
   .wr_data(in_data),.wr_en(in_valid && in_ready),.wr_full(full),.wr_water_level(wr_used),
   .rd_clk(rd_clk),.rd_rst(!rd_reset_n),.rd_en(pop),.rd_data(fifo_data),
   .rd_empty(empty),.rd_water_level(),.almost_full(),.almost_empty());
 end else begin:g_invalid_width
  // Purpose: unsupported instantiations fail elaboration instead of silently
  // truncating capture metadata or constructing an unvalidated inferred FIFO.
  RAW8_QUEUE_WIDTH_MUST_BE_256_OR_288 invalid_configuration();
 end endgenerate
 always @(posedge rd_clk or negedge rd_reset_n)
  if(!rd_reset_n)begin pending<=0;out_valid<=0;out_data<=0;end
  else begin
   pending<=pop;
   if(out_valid && out_ready)out_valid<=0;
   if(pending)begin out_data<=fifo_data;out_valid<=1;end
  end
endmodule
