`timescale 1ns/1ps
// Purpose: full GMII packet replay across unequal/stopped clocks, and atomic
// display offer/release mailboxes with a deliberately delayed memory ACK.
module tb_board_service_cdc;
 reg rxclk=0,mclk=0,pclk=0,rst=0,clock_enable=1;
 always #4.05 rxclk=~rxclk;always #4 if(clock_enable)mclk=~mclk;else mclk=0;always #6.7 pclk=~pclk;
 reg [7:0] rxdata=0;reg rxdv=0,rxer=0;
 wire [7:0] data;wire valid,error;wire [31:0] dropped;
 gmii_receive_cdc rx(.rx_clk(rxclk),.rx_rst_n(rst),.rx_data(rxdata),.rx_dv(rxdv),.rx_er(rxer),
  .memory_clk(mclk),.memory_rst_n(rst),.data(data),.valid(valid),.error(error),.dropped_frames(dropped));
 integer byte_no=0,frames=0;reg previous=0;integer expected_seed=1;
 always @(posedge mclk)if(rst)begin
  if(valid)begin
   if(error || data!==((byte_no*3+expected_seed)&255))$fatal(1,"Wire frame byte changed frame=%0d byte=%0d",frames,byte_no);
   byte_no=byte_no+1;
  end
  if(previous && !valid)begin
   if(byte_no!=1500)$fatal(1,"Intra-frame gap or bad length %0d",byte_no);
   byte_no=0;frames=frames+1;expected_seed=expected_seed+1;
  end
  previous=valid;
 end
 task packet(input integer seed,input corrupt);
  integer k;
  begin
   for(k=0;k<1500;k=k+1)begin @(negedge rxclk);rxdv=1;rxdata=(k*3+seed)&255;rxer=corrupt && k==800;end
   @(negedge rxclk);rxdv=0;rxer=0;repeat(12)@(negedge rxclk);
  end
 endtask
 reg mo=0,pr=0,po_ready=0,mrel_ready=0;reg [31:0] mb=0,mg=0;reg [1:0] ms=0,prs=0;reg [31:0] prg=0;
 wire mr,mor,po,pr_ready,mrel;wire [31:0] pb,pg,mrg;wire [1:0] ps,mrs;wire [63:0] pe,pi;
 display_frame_cdc dc(.memory_clk(mclk),.memory_rst_n(rst),.memory_request(mr),.memory_offer_valid(mo),.memory_offer_ready(mor),
  .memory_base(mb),.memory_generation(mg),.memory_slot(ms),.memory_epoch(64'h8000000000000001),.memory_id(64'd91),
  .memory_release_valid(mrel),.memory_release_ready(mrel_ready),.memory_release_slot(mrs),.memory_release_generation(mrg),
  .pixel_clk(pclk),.pixel_rst_n(rst),.pixel_offer_valid(po),.pixel_offer_ready(po_ready),.pixel_base(pb),.pixel_generation(pg),.pixel_slot(ps),
  .pixel_epoch(pe),.pixel_id(pi),.pixel_release_valid(pr),.pixel_release_ready(pr_ready),.pixel_release_slot(prs),.pixel_release_generation(prg));
 task offer_frame(input [1:0] slot,input [31:0] generation);
  begin wait(mor);@(negedge mclk);mo=1;mb=32'h01800000+(slot<<23);mg=generation;ms=slot;@(negedge mclk);mo=0;end
 endtask
 initial begin
  #100;rst=1;
  packet(1,0);packet(2,0);wait(frames==2);
  packet(99,1);repeat(100)@(negedge mclk);
  if(frames!=2 || dropped!=1)$fatal(1,"RX error frame was published");
  @(negedge mclk);clock_enable=0;
  packet(3,0);packet(4,0);packet(5,0);
  if(dropped!=2)$fatal(1,"Full-bank frame was not dropped");
  clock_enable=1;wait(frames==4);
  offer_frame(1,32'd17);wait(po);repeat(20)@(negedge pclk);
  if(ps!=1 || pg!=17 || pe!=64'h8000000000000001 || pi!=91 || mor)$fatal(1,"Offer hold failed");
  po_ready=1;@(negedge pclk);po_ready=0;wait(mor);
  offer_frame(2,32'd18);wait(po);
  @(negedge pclk);po_ready=1;pr=1;prs=1;prg=17;
  @(negedge pclk);po_ready=0;pr=0;wait(mrel);
  repeat(100)@(negedge mclk);
  if(mrs!=1 || mrg!=17 || pr_ready)$fatal(1,"Drained release context overwritten");
  mrel_ready=1;@(negedge mclk);mrel_ready=0;wait(pr_ready);
  $display("TB_BOARD_SERVICE_CDC_PASS packets=%0d dropped=%0d",frames,dropped);$finish;
 end
 initial begin #3000000;$fatal(1,"Service CDC timeout");end
endmodule
