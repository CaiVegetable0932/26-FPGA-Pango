`timescale 1ns/1ps
// Purpose: native no-B/no-RREADY fault boundaries independently of full frames.
// Check partial-frame drain, wrong WLAST, burst credit, address units and RID.
module tb_raw8_native_contracts;
 reg clk=0,rst=0;always #4 clk=~clk;
 reg [287:0] record=0;reg rv=0,awr=0,wr=0,wl=0;
 wire rr,commit,good,wfault,awv;wire [27:0] awa;wire [255:0] wd;wire [2:0] wcode;
 wire [95:0] snapshot;
 raw8_write_engine w(.clk(clk),.rst_n(rst),.slot_base(28'h3000000),.epoch(64'd7),
  .record_data(record),.record_valid(rv),.record_ready(rr),.commit(commit),.good(good),
  .captured_id(),.captured_epoch(),.awaddr(awa),.awlen(),.awvalid(awv),.awready(awr),
  .wready(wr),.wlast(wl),.wid(4'b0),.wdata(wd),.wstrb(),.fence_req(),.fence_addr(),
  .fence_ready(1'b0),.fence_valid(1'b0),.fence_done(1'b0),.rdata(256'b0),.fault(wfault),.fault_code(wcode),.fault_snapshot(snapshot));
 reg hr=0,nr=0,hs=0,ns=0,fr=0,arready=0,rvalid=0,rlast=0;reg [3:0] rid=0;
 wire hready,nready,fready,hvalid,nvalid,fvalid,hdone,ndone,fdone,arvalid,afault;
 wire [27:0] addr;wire [3:0] len,id;
 raw8_read_arbiter a(.clk(clk),.rst_n(rst),.h_req(hr),.h_addr(28'h3000200),.h_len(5'd16),
  .h_space(hs),.h_ready(hready),.h_valid(hvalid),.h_done(hdone),
  .n_req(nr),.n_addr(28'h3400000),.n_len(5'd12),.n_space(ns),.n_ready(nready),.n_valid(nvalid),.n_done(ndone),
  .f_req(fr),.f_addr(28'h3000400),.f_ready(fready),.f_valid(fvalid),.f_done(fdone),
  .araddr(addr),.arlen(len),.arid(id),.arvalid(arvalid),.arready(arready),
  .rvalid(rvalid),.rlast(rlast),.rid(rid),.fault(afault));
 task tick;begin @(negedge clk);end endtask
 task send(input [287:0] value);begin
  tick();record=value;rv=1;while(!rr)tick();tick();rv=0;
 end endtask
 integer k;
 initial begin
  repeat(4)tick();rst=1;
  send({2'd1,222'b0,64'd11});send({32'b0,256'h1234});
  if(!awv || awa!=28'hc00000 || wd!=256'h1234)$fatal(1,"RAW8_FAIL native write address/data");
  // END may wait but cannot commit before the only outstanding W beat.
  record={2'd2,221'b0,1'b0,64'd11};rv=1;
  repeat(8)begin tick();if(rr||commit)$fatal(1,"RAW8_FAIL released undrained write");end
  awr=1;tick();awr=0;wr=1;wl=1;tick();wr=0;wl=0;tick();rv=0;
  if(!commit || good || wfault)$fatal(1,"RAW8_FAIL bad geometry drain/release");
  send({2'd1,222'b0,64'd12});send({32'b0,256'h5678});
  awr=1;tick();awr=0;wr=1;wl=0;tick();wr=0;
  // Purpose: telemetry must name the actual failure without relaxing it.
  if(!wfault || rr || wcode!=5)$fatal(1,"RAW8_FAIL missing WLAST not fail-closed/reported");
  // Without whole-burst credit, no request may be accepted.
  hr=1;nr=1;repeat(4)begin tick();if(hready||nready||arvalid)$fatal(1,"RAW8_FAIL credit gate");end
  hs=1;tick();hr=0;
  if(!arvalid || addr!=28'hc00080 || len!=15 || id!=0)$fatal(1,"RAW8_FAIL AR mapping");
  ns=1;fr=1;repeat(4)begin tick();if(nready||fready)$fatal(1,"RAW8_FAIL preempted pending AR");end
  arready=1;tick();arready=0;
  for(k=0;k<16;k=k+1)begin
   rvalid=1;rid=0;rlast=k==15;#1;
   if(!hvalid || nvalid || fvalid)$fatal(1,"RAW8_FAIL burst owner");tick();
  end
  rvalid=0;rlast=0;
  if(!hdone || !fready || afault)$fatal(1,"RAW8_FAIL fence priority/done");
  tick();fr=0;
  if(id!=2 || len!=0 || addr!=28'hc00100)$fatal(1,"RAW8_FAIL fence mapping");
  arready=1;tick();arready=0;rvalid=1;rlast=1;rid=1;tick();rvalid=0;
  if(!afault)$fatal(1,"RAW8_FAIL wrong RID accepted");
  repeat(4)begin tick();if(hready||nready||fready||arvalid)$fatal(1,"RAW8_FAIL reused faulty reader");end
  // Purpose: separately identify missing START and wrong offset, freezing the
  // pre-increment count/offset even when the producer changes the input later.
  rst=0;tick();rst=1;send({15'b0,17'd9,256'h1234});
  if(!wfault || wcode!=2 || snapshot!=96'h010500000000000000000009)
   $fatal(1,"RAW8_FAIL missing START snapshot %h",snapshot);
  record=0;repeat(3)tick();
  if(snapshot[23:0]!=9)$fatal(1,"RAW8_FAIL snapshot not sticky");
  rst=0;tick();rst=1;send({2'd1,222'b0,64'd13});send({15'b0,17'd1,256'h1234});
  if(!wfault || wcode!=2 || snapshot!=96'h010700000000000000000001)
   $fatal(1,"RAW8_FAIL offset snapshot %h",snapshot);
  $display("RAW8_NATIVE_CONTRACTS_PASS");$finish;
 end
 initial begin #100000;$fatal(1,"RAW8_TIMEOUT native contracts");end
endmodule
