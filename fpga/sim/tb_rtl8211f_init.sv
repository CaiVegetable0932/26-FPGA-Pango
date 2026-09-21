`timescale 1ns/1ps
// Purpose: independent Clause-22 PHY model with worst-case 300 ns read delay.
// Validate real 10/30 ms reset waits, preamble/op/address/TA, RMW preservation,
// gigabit admission, link loss and fail-closed ID/ACK/readback fault paths.
module tb_rtl8211f_init #(parameter USE_PHY_DELAY=1);
 reg clk=0;always #4 clk=~clk;
 reg reset_n=0;
 wire mdc,mo,oe,phy_reset_n,configured,link_ready,fault;
 wire [3:0] fault_code;wire [15:0] status;wire [31:0] id;
 tri1 mdio;reg phy_drive=0,phy_bit=1;
 assign mdio=oe?mo:1'bz;assign mdio=phy_drive?phy_bit:1'bz;
 rtl8211f_init #(.POLL_MS(1),.PHY_TX_DELAY(USE_PHY_DELAY)) dut(.clk(clk),.reset_n(reset_n),.mdio_i(mdio),
  .mdio_o(mo),.mdio_oe(oe),.mdc(mdc),.phy_reset_n(phy_reset_n),
  .configured(configured),.link_ready(link_ready),.fault(fault),.fault_code(fault_code),
  .phy_status(status),.phy_id(id));
 integer bitno=0,transactions=0,reads=0,writes=0,checks=0;
 reg [63:0] shift=0;reg [15:0] page=0,txcr=16'hb5a5,anar=16'h0de1;
 reg [15:0] gbcr=16'h0100,bmcr=16'h1140,eee=16'h0006,mmd=0,mmdaddr=0;
 reg [15:0] physr=16'h002c,response=0;
 reg [4:0] ra=0,pa=0;reg [1:0] op=0;
 reg no_ack=0,bad_id=0,ignore_delay_write=0;
 realtime reset_start=0,release_time=0,last_rise=0,last_fall=0;
 task check(input bit ok,input string why);
  begin checks=checks+1;if(!ok)$fatal(1,"PHY_FAIL %s",why);end
 endtask
 always @(negedge phy_reset_n) begin
  reset_start=$realtime;bitno=0;phy_drive=0;page=0;txcr=USE_PHY_DELAY?16'hb4a5:16'hb5a5;
  anar=16'h0de1;gbcr=16'h0100;bmcr=16'h1140;eee=6;mmd=0;mmdaddr=0;
 end
 always @(posedge phy_reset_n) begin
  check($realtime-reset_start>=10000000,"hardware reset shorter than 10 ms");
  release_time=$realtime;last_fall=$realtime;
 end
 // PHY reads change AFTER the rising edge. An incorrectly early MAC sample
 // passes zero-delay models but fails this one. Writes sample on rising edges.
 always @(posedge mdc) begin
  check(phy_reset_n && $realtime-release_time>=30000000,"MDIO before 30 ms settle");
  check($realtime-last_fall>=500,"MDC low duration");last_rise=$realtime;
  if(bitno<46 || op==1) begin
   check(oe,"host released a driven command bit");
   check(!phy_drive,"bus contention");
  end else check(!oe,"host drove read turnaround/data");
  shift={shift[62:0],mdio};
  if(bitno<32)check(mdio===1'b1,"preamble is not 32 ones");
  if(bitno==45) begin
   check(shift[13:12]==1,"start bits");op=shift[11:10];pa=shift[9:5];ra=shift[4:0];
   check(pa==1,"wrong PHY address");check(op==1||op==2,"opcode");
   response=16'hffff;
   if(ra==31)response=page;
   else if(page==0 && op==2) case(ra)
    2:response=bad_id?16'h1234:16'h001c;
    3:response=16'hc916;
    4:response=anar;
    9:response=gbcr;
    0:response=bmcr;
    14:begin check(mmd==16'h4007 && mmdaddr==16'h003c,"MMD read address");response=eee;end
    default:check(0,"unexpected base-page read");
   endcase
   else if(page==16'h0d08 && ra==17)response=txcr;
   else if(page==16'h0a43 && ra==26)response=physr;
   // Read-value lookup is irrelevant to writes into MMD/page-selection fields.
  end
  if(op==2 && bitno>=47 && !no_ack) begin
   phy_drive<=#300 1'b1;
   phy_bit<=#300 ((bitno==47)?1'b0:response[63-bitno]);
  end
  if(bitno==63) begin
   transactions=transactions+1;
   if(op==1) begin
    writes=writes+1;check(shift[17:16]==2'b10,"write turnaround");
    if(ra==31)page=shift[15:0];
    else if(page==16'h0d08 && ra==17) begin
     if(!ignore_delay_write)txcr=shift[15:0];
    end else if(page==0)case(ra)
     4:anar=shift[15:0];9:gbcr=shift[15:0];0:bmcr=shift[15:0];
     13:mmd=shift[15:0];
     14:if(mmd==7)mmdaddr=shift[15:0];else if(mmd==16'h4007)eee=shift[15:0];
     default:check(0,"unexpected write");
    endcase
   end else reads=reads+1;
   bitno=0;
  end else bitno=bitno+1;
 end
 always @(negedge mdc) begin
  if(reset_n)check($realtime-last_rise>=500,"MDC high duration");
  last_fall=$realtime;
  if(bitno==0) begin phy_drive<=0;phy_bit<=1;end
 end
 task reboot;
  begin @(negedge clk);reset_n=0;repeat(5)@(negedge clk);reset_n=1;end
 endtask
 initial begin
  repeat(5)@(negedge clk);reset_n=1;
  wait(configured);#1000;
  check(!fault && link_ready && id==32'h001cc916,"normal initialization");
  check(txcr==(USE_PHY_DELAY?16'hb5a5:16'hb4a5) && anar==16'h0001 && gbcr==16'h0200 && eee==0,
        "RMW/no EEE/no pause/gigabit-only configuration");
  check(page==0,"page not restored");
  physr=16'h001c;wait(!link_ready);check(!fault,"100 Mbps must block without fault");
  physr=16'h0024;#1300000;check(!link_ready,"half duplex admission");
  physr=0;#1300000;check(!link_ready,"link down admission");
  physr=16'h002c;wait(link_ready);
  no_ack=1;wait(fault);check(fault_code==1&&!link_ready,"missing ACK not fail closed");
  no_ack=0;bad_id=1;reboot();wait(fault);check(fault_code==2,"wrong ID accepted");
  bad_id=0;ignore_delay_write=1;reboot();wait(fault);check(fault_code==3,"TXID write failure accepted");
  ignore_delay_write=0;reboot();wait(configured);check(link_ready&&!fault,"reset did not recover");
  $display("PHY_INIT_PASS checks=%0d transactions=%0d reads=%0d writes=%0d",checks,transactions,reads,writes);
  $finish;
 end
 initial begin #250000000;$fatal(1,"PHY_INIT_TIMEOUT");end
endmodule
