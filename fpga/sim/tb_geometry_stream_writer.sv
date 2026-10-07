`timescale 1ns/1ps
// Purpose: verify pipelined gray/mask writes, queue backpressure, row padding,
// independent AW/W stalls and final read fence, including corrupt-fence refusal.
module tb_geometry_stream_writer;
 parameter BAD_FENCE=0;
 reg clk=0,rst=0,start=0;always #4 clk=~clk;
 wire ready,done,good,fault,awv,req;wire [27:0] aw,ra;wire [3:0] al;wire [255:0] wd;wire [31:0] st;
 reg pv=0,pm=0;reg [7:0] p=0;
 reg awready=0,wready=0,wlast=0,rr=0,rv=0,rd=0;reg [255:0] data=0;
 geometry_result_stream_writer #(.WIDTH(64),.HEIGHT(8),.STRIDE(128)) dut(
 .clk(clk),.rst_n(rst),.start(start),.base(28'h4000000),
 .pixel_valid(pv),.pixel_mask(pm),.pixel(p),.pixel_ready(ready),
 .done(done),.good(good),.fault(fault),.awaddr(aw),.awlen(al),.awvalid(awv),
 .awready(awready),.wready(wready),.wlast(wlast),.wid(4'd0),.wdata(wd),.wstrb(st),
 .fence_req(req),.fence_addr(ra),.fence_ready(rr),.fence_valid(rv),.fence_done(rd),.fence_data(data));
 integer sent=0,writes=0,cycles=0,delayw=0,delayr=0,frame=0,idx,j,offset;
 reg writing=0,reading=0;reg [27:0] address;reg [255:0] expected,last_mask;reg held_aw=0;reg [283:0] held;
 function [7:0] pixel_value(input integer n,input integer f);begin pixel_value=(n*29+f*47) & 255;end endfunction
 always @(posedge clk)if(rst)begin
  cycles=cycles+1;
  if(pv && ready)sent=sent+1;
  if(held_aw && (!awv || {aw,wd}!==held))$fatal(1,"STREAM_WRITER_FAIL stalled AW");
  held_aw=awv && !awready;held={aw,wd};
  if(awv && awready)begin
   if(writing || al!=0)$fatal(1,"STREAM_WRITER_FAIL overlap");
   writing=1;address=aw<<2;delayw=cycles%31+2;
  end
  if(wready)begin
   if(!writing || !wlast || st!=32'hffffffff)$fatal(1,"STREAM_WRITER_FAIL native write");
   offset=address-28'h4000000;expected=0;
   if(offset<1024)begin
    if(offset%128>=64)$fatal(1,"STREAM_WRITER_FAIL padding");
    idx=(offset/128)*64+offset%128;
    for(j=0;j<32;j=j+1)expected[j*8+:8]=pixel_value(idx+j,frame);
   end else if(offset==28'h280000 || offset==28'h280020)begin
    idx=((offset-28'h280000)/32)*256;
    for(j=0;j<256;j=j+1)expected[j]=(idx+j)%13!=0;
    last_mask=expected;
   end else $fatal(1,"STREAM_WRITER_FAIL address");
   if(wd!==expected)$fatal(1,"STREAM_WRITER_FAIL payload off=%h got=%h exp=%h",offset,wd,expected);
   writing=0;writes=writes+1;
  end
  if(req && rr)begin
   if(sent!=512 || writes!=18 || writing || reading || ra!=28'h4280020)
    $fatal(1,"STREAM_WRITER_FAIL premature fence sent=%0d writes=%0d",sent,writes);
   reading=1;delayr=7;
  end
 end
 always @(negedge clk)begin
  awready=rst && !writing && cycles%7!=0;rr=rst && !reading;
  wready=0;wlast=0;rv=0;rd=0;
  if(writing)begin if(delayw>0)delayw=delayw-1;else begin wready=1;wlast=1;end end
  if(reading)begin
   if(delayr>0)delayr=delayr-1;
   else begin rv=1;rd=1;reading=0;data=last_mask ^ BAD_FENCE;end
  end
 end
 initial begin
  repeat(4)@(negedge clk);rst=1;
  for(frame=0;frame<3;frame=frame+1)begin
   @(negedge clk);sent=0;writes=0;start=1;@(negedge clk);start=0;
   while(sent<512)begin
    @(negedge clk);pv=1;p=pixel_value(sent,frame);pm=sent%13!=0;
   end
   @(negedge clk);pv=0;
   wait(done);@(negedge clk);
   if(good!==!BAD_FENCE || fault!==BAD_FENCE[0])$fatal(1,"STREAM_WRITER_FAIL fence status");
   if(BAD_FENCE)begin $display("STREAM_WRITER_BAD_FENCE_PASS");$finish;end
  end
  $display("STREAM_WRITER_PASS frames=3 cycles=%0d",cycles);$finish;
 end
 initial begin #1000000;$fatal(1,"STREAM_WRITER_TIMEOUT");end
endmodule

