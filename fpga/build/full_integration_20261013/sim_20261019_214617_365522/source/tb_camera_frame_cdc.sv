`timescale 1ns/1ps
// Purpose: asynchronous sensor/memory clocks, complete EOF, independent RAW
// overrun and delayed context release. A later unadmitted frame must not alter
// the held first frame's identity or terminal mailbox.
module tb_camera_frame_cdc;
 reg pclk=0,memory_clk=0,rst=0;
 always #6 pclk=~pclk;always #4 memory_clk=~memory_clk;
 reg [7:0] data=0;reg href=0,vsync=1;
 wire cv,ce,il,rl,ia,ra,iv,rv,drained;wire [7:0] ib,rb;
 wire [63:0] epoch,id,first,last;wire [31:0] errors,source,dropped_raw,dropped_isp;
 reg complete=0,raw_ready=1,isp_ready=1;
 integer raw_count=0,isp_count=0,contexts=0,case_no=0;
 camera_frame_cdc #(.WIDTH(35),.HEIGHT(9),.WARMUP(0),.QUEUE_BITS(5)) dut(
  .pclk(pclk),.pclk_rst_n(rst),.dvp_data(data),.href(href),.vsync(vsync),.camera_ready(1'b1),.boot_epoch(64'h123456789abcdef0),
  .memory_clk(memory_clk),.memory_rst_n(rst),.capture_valid(cv),.capture_ready(1'b1),.capture_complete(complete),
  .epoch(epoch),.frame_id(id),.capture_first(first),.capture_last(last),.capture_end(ce),.isp_legal(il),.raw_legal(rl),
  .capture_errors(errors),.isp_abort(ia),.raw_abort(ra),.isp_valid(iv),.isp_ready(isp_ready),.isp_data(ib),
  .raw_valid(rv),.raw_ready(raw_ready),.raw_data(rb),.queues_drained(drained),
  .source_frames(source),.dropped_raw(dropped_raw),.dropped_isp(dropped_isp));
 always @(posedge memory_clk)if(rst)begin
  if(cv)contexts=contexts+1;
  if(iv && isp_ready)begin if(ib!==8'd73)$fatal(1,"ISP byte changed");isp_count=isp_count+1;end
  if(rv && raw_ready)begin if(rb!==8'd73)$fatal(1,"RAW byte changed");raw_count=raw_count+1;end
 end
 task sensor_frame(input integer width);
  integer x,y;
  begin
   @(negedge pclk);vsync=0;
   repeat(12)@(negedge pclk);
   for(y=0;y<9;y=y+1)begin
    href=1;for(x=0;x<width;x=x+1)begin data=73;@(negedge pclk);end
    href=0;repeat(12)@(negedge pclk);
   end
   vsync=1;repeat(15)@(negedge pclk);
  end
 endtask
 task release_context;
  begin wait(drained);@(negedge memory_clk);complete=1;@(negedge memory_clk);complete=0;repeat(20)@(negedge pclk);end
 endtask
 reg [63:0] saved_last;
 initial begin
  #100;rst=1;repeat(30)@(negedge pclk);
  sensor_frame(35);wait(ce);repeat(10)@(negedge memory_clk);
  if(!il || !rl || errors || raw_count!=315 || isp_count!=315 || id!=1 || epoch!=64'h123456789abcdef0)
   $fatal(1,"Normal context/bytes failed raw=%0d isp=%0d legal=%b%b",raw_count,isp_count,rl,il);
  saved_last=last;sensor_frame(35);
  if(contexts!=1 || id!=1 || last!=saved_last || !il || !rl)$fatal(1,"Unadmitted frame overwrote context");
  release_context;
  raw_count=0;isp_count=0;raw_ready=0;sensor_frame(35);wait(ce);repeat(10)@(negedge memory_clk);
  if(rl || !il || !ra || ia || isp_count!=315 || dropped_raw!=1 || dropped_isp!=0 || id!=3)
   $fatal(1,"Independent overflow failed legal=%b%b abort=%b%b isp=%0d",rl,il,ra,ia,isp_count);
  raw_ready=1;release_context;
  raw_count=0;isp_count=0;sensor_frame(34);wait(ce);repeat(10)@(negedge memory_clk);
  if(il || rl || errors==0)$fatal(1,"Short line published");
  release_context;
  $display("TB_CAMERA_FRAME_CDC_PASS contexts=%0d source=%0d",contexts,source);$finish;
 end
 initial begin #2000000;$fatal(1,"CDC timeout");end
endmodule
