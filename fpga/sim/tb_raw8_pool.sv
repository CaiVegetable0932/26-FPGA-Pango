`timescale 1ns/1ps
// Purpose: concurrent HDMI/network ownership, no-free-slot drops and a missing
// write-drain fence. Metadata assertions cover publication/acquisition ordering.
module tb_raw8_pool;
 reg clk=0,rst=0,c_req=0,c_commit=0,c_good=1,c_drained=1;
 reg h_req=0,h_release=0,n_req=0,n_release=0;
 reg [63:0] id=0;
 wire cg,hg,ng,hl,nl,error;
 wire [1:0] cs,hs,ns;wire [27:0] base;
 wire [63:0] hi,ni,he,ne;wire [31:0] published,dropped;
 always #5 clk=~clk;
 raw8_frame_pool dut(clk,rst,c_req,cg,cs,base,c_commit,c_good,c_drained,id,64'd99,
  h_req,h_release,hg,hl,hs,hi,he,n_req,n_release,ng,nl,ns,ni,ne,published,dropped,error);
 task tick;begin @(negedge clk);end endtask
 task publish(input integer fid);
  begin c_req=1;tick();c_req=0;if(!cg)$fatal(1,"RAW8_FAIL no capture lease");
   if((hl && cs==hs)||(nl && cs==ns))$fatal(1,"RAW8_FAIL reader overwritten");
   if(base!=28'h3000000+(cs<<22))$fatal(1,"RAW8_FAIL memory map");
   id=fid;c_commit=1;tick();c_commit=0;tick();end
 endtask
 initial begin
  tick();rst=1;tick();publish(1);
  h_req=1;n_req=1;tick();h_req=0;n_req=0;
  if(!hl||!nl||hi!=1||ni!=1||he!=99||ne!=99)$fatal(1,"RAW8_FAIL initial identity");
  publish(2);n_release=1;tick();n_release=0;n_req=1;tick();n_req=0;
  if(ni!=2 || hi!=1)$fatal(1,"RAW8_FAIL independent readers");
  publish(3);c_req=1;tick();c_req=0;
  if(cg || dropped!=1)$fatal(1,"RAW8_FAIL no free slot");
  h_release=1;tick();h_release=0;h_req=1;tick();h_req=0;
  if(hi!=3 || ni!=2)$fatal(1,"RAW8_FAIL latest identity");
  c_req=1;tick();c_req=0;c_drained=0;c_commit=1;tick();c_commit=0;
  if(!error || published!=3)$fatal(1,"RAW8_FAIL missing fence accepted");
  c_drained=1;c_good=0;c_commit=1;tick();c_commit=0;
  if(published!=3)$fatal(1,"RAW8_FAIL bad frame published");
  $display("RAW8_POOL_PASS published=%0d no_free=%0d",published,dropped);$finish;
 end
 initial begin #100000;$fatal(1,"RAW8_TIMEOUT pool");end
endmodule
