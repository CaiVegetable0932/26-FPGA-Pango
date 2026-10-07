`timescale 1ns/1ps
// Purpose: test result-pool address isolation and commit/grant concurrency.
// Public lease metadata must identify the selected old frame, not the live
// publication counter after a simultaneous newer commit.
module tb_geometry_pool;
 reg clk=0,rst=0,cr=0,cc=0,hr=0,rel=0;always #4 clk=~clk;
 reg [63:0] fid=0;wire cg,hg,locked,error;wire [27:0] base;wire [1:0] cs,hs;
 wire [63:0] id;wire [31:0] published,hpub;
 raw8_frame_pool #(.BASE(28'h4000000)) pool(.clk(clk),.reset_n(rst),
  .capture_request(cr),.capture_grant(cg),.capture_slot(cs),.capture_base(base),
  .capture_commit(cc),.capture_good(1'b1),.capture_drained(cc),.captured_id(fid),.captured_epoch(64'd123),
  .hdmi_request(hr),.hdmi_release(rel),.hdmi_grant(hg),.hdmi_locked(locked),.hdmi_slot(hs),
  .hdmi_id(id),.hdmi_epoch(),.hdmi_publication(hpub),
  .net_request(1'b0),.net_release(1'b0),.net_grant(),.net_locked(),.net_slot(),.net_id(),.net_epoch(),
  .published(published),.dropped(),.protocol_error(error));
 task reserve;
  begin @(negedge clk);cr=1;@(negedge clk);cr=0;
   if(!cg || base<28'h4000000 || base>=28'h4c00000)$fatal(1,"GEOMETRY_POOL_FAIL base/grant");end
 endtask
 initial begin
  repeat(4)@(negedge clk);rst=1;reserve();fid=10;cc=1;@(negedge clk);cc=0;
  reserve();fid=11;cc=1;hr=1;@(negedge clk);cc=0;hr=0;
  if(error || !hg || id!=10 || hpub!=1 || published!=2)$fatal(1,"GEOMETRY_POOL_FAIL concurrent identity");
  rel=1;@(negedge clk);rel=0;hr=1;@(negedge clk);hr=0;
  if(error || !hg || id!=11 || hpub!=2)$fatal(1,"GEOMETRY_POOL_FAIL latest lease");
  $display("GEOMETRY_POOL_PASS publication=2 lease_identity=11");$finish;
 end
 initial begin #10000;$fatal(1,"GEOMETRY_POOL_TIMEOUT");end
endmodule
