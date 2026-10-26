`timescale 1ns/1ps
// Purpose: section 07 RAW reader -> real section 04 adapter -> native DDR model.
// Nonaligned short rows cross the native column boundary; compare only compact
// effective bytes, preserving row stride and cancellation/drain ownership.
module tb_raw_ddr_adapter;
 localparam N=6,W=37,H=3,S=64,BASE=4093;
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,start=0,stop=0,sink_ready=1;
 wire start_ready,raw_done,failed,request_valid,request_ready,read_valid,read_ready;
 wire [31:0] request_addr;wire [4:0] request_beats;
 wire [255:0] read_data;wire dma_done,dma_ack,dma_error,dma_cancel,byte_valid;
 wire [7:0] byte_data;
 raw_dma_reader #(.WIDTH(W),.HEIGHT(H),.STRIDE(S)) reader(
  .clk(clk),.rst_n(rst_n),.start(start),.start_ready(start_ready),.base_addr(BASE),
  .slot_begin(32'd0),.slot_end(32'd8192),.cancel(stop),.done(raw_done),.failed(failed),
  .req_valid(request_valid),.req_ready(request_ready),.req_addr(request_addr),.req_beats(request_beats),
  .r_valid(read_valid),.r_ready(read_ready),.r_data(read_data),
  .dma_done(dma_done),.dma_done_ready(dma_ack),.dma_error(dma_error),.dma_cancel(dma_cancel),
  .byte_valid(byte_valid),.byte_ready(sink_ready),.byte_data(byte_data));
 wire [N-1:0] req_ready,r_valid,r_last,done,error;
 wire [N*256-1:0] r_data;
 wire [27:0] araddr,awaddr;wire [3:0] arlen,awlen,arid,awid;
 wire arvalid,awvalid,fault;
 reg arready=0,rvalid=0,rlast=0;reg [255:0] rdata=0;
 ddr_native_dma dma(.clk(clk),.rst_n(rst_n),.controller_ready(1'b1),
  .req_valid({request_valid,5'b0}),.req_ready(req_ready),.req_write(6'b0),
  .req_addr({request_addr,160'b0}),.req_beats({request_beats,25'b0}),.req_tag(192'b0),
  .urgent(6'b0),.cancel({dma_cancel,5'b0}),.w_valid(6'b0),.w_data(1536'b0),.w_strb(192'b0),
  .r_valid(r_valid),.r_ready({read_ready,5'b0}),.r_data(r_data),.r_last(r_last),
  .done(done),.done_ready({dma_ack,5'b0}),.error(error),
  .awaddr(awaddr),.awlen(awlen),.awid(awid),.awvalid(awvalid),.awready(1'b0),
  .native_wready(1'b0),.native_wid(4'b0),.native_wlast(1'b0),
  .araddr(araddr),.arlen(arlen),.arid(arid),.arvalid(arvalid),.arready(arready),
  .native_rdata(rdata),.native_rvalid(rvalid),.native_rid(4'b0),.native_rlast(rlast),.fault(fault));
 assign request_ready=req_ready[5],read_valid=r_valid[5],read_data=r_data[5*256+:256];
 assign dma_done=done[5],dma_error=error[5];
 integer seed=33,seed_arg,expected_addr=0,expected_beats=0,base=0,left=0,index=0,seen=0,requests=0;
 reg aborting=0;
 function automatic [7:0] pattern(input integer a);pattern=(a*29+7)&255;endfunction
 always @(negedge clk) begin
  arready=rst_n&&left==0&&($random(seed)&3)!=0;
  rvalid=rst_n&&left!=0&&($random(seed)&3)!=0;rlast=left==1;
  sink_ready=($random(seed)&3)!=0;
  for(integer b=0;b<32;b=b+1)rdata[b*8+:8]=pattern(base+index*32+b);
 end
 always @(posedge clk) if(rst_n) begin
  if(request_valid&&request_ready)begin expected_addr=request_addr;expected_beats=request_beats;requests=requests+1;end
  if(arvalid&&arready)begin
   if(araddr*4!=expected_addr || arlen+1!=expected_beats || (araddr*4)%4096+(arlen+1)*32>4096)$fatal(1,"RAW native address/span");
   base=araddr*4;left=arlen+1;index=0;
  end
  if(rvalid)begin left=left-1;index=index+1;end
  if(byte_valid&&sink_ready)begin
   if(aborting || byte_data!==pattern(BASE+(seen/W)*S+(seen%W)))$fatal(1,"RAW stride removal/order");
   seen=seen+1;
  end
 end
 initial begin
  if($value$plusargs("seed=%d",seed_arg))seed=seed_arg;
  repeat(4)@(negedge clk);rst_n=1;start=1;@(negedge clk);start=0;
  wait(raw_done);@(negedge clk);if(failed || fault || seen!=W*H)$fatal(1,"RAW adapter result");
  wait(start_ready);@(negedge clk);start=1;@(negedge clk);start=0;
  wait(arvalid&&arready);@(negedge clk);aborting=1;stop=1;
  wait(raw_done);@(negedge clk);
  if(!failed || left!=0 || fault || !start_ready)$fatal(1,"RAW cancel did not drain");
  stop=0;$display("RAW_DDR_ADAPTER_PASS bytes=%0d requests=%0d",seen,requests);$finish;
 end
 // General unaligned mode owns the reservoir counters in its generate scope.
 initial begin #1000000;$fatal(1,"RAW_DDR_ADAPTER_TIMEOUT reader=%0d adapter=%0d seen=%0d requests=%0d left=%0d pending=%b done=%b unpack_left=%0d count=%0d",reader.state,dma.state,seen,requests,left,dma.pending,done,reader.unpack.unaligned_rows.left,reader.unpack.unaligned_rows.count);end
endmodule





































































































