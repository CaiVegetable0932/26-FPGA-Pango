`timescale 1ns/1ps
// Purpose: independent Clause-22 PHY model with worst-case 300 ns read delay.
// Validate real 10/200 ms reset waits, preamble/op/address/TA, RMW preservation,
// gigabit admission, link loss and fail-closed ID/ACK/readback fault paths.
// SETTLE_TEST_MS=30 deliberately replays the old bug: an independent PHY
// stays unavailable for 150 ms and must reject that premature scan.
module tb_rtl8211f_init #(parameter USE_PHY_DELAY=1, SETTLE_TEST_MS=200, PHY_READ_DELAY_NS=300);
 reg clk=0;always #4 clk=~clk;
 reg reset_n=0;
 wire mdc,mo,oe,phy_reset_n,configured,link_ready,fault;
 wire [3:0] fault_code;wire [15:0] status;wire [31:0] id;
 tri1 mdio;reg phy_drive=0,phy_bit=1;
 assign mdio=oe?mo:1'bz;assign mdio=phy_drive?phy_bit:1'bz;
 wire [4:0] selected_addr;wire [5:0] diagnostic_step;wire [15:0] last_read;wire last_ack_error;
 rtl8211f_init #(.POLL_MS(1),.SETTLE_MS(SETTLE_TEST_MS),.PHY_TX_DELAY(USE_PHY_DELAY),.SCAN_ADDRESSES(1)) dut(.clk(clk),.reset_n(reset_n),.mdio_i(mdio),
  .mdio_o(mo),.mdio_oe(oe),.mdc(mdc),.phy_reset_n(phy_reset_n),
  .configured(configured),.link_ready(link_ready),.fault(fault),.fault_code(fault_code),
  .phy_status(status),.phy_id(id),.selected_addr(selected_addr),
  .diagnostic_step(diagnostic_step),.last_read(last_read),.last_ack_error(last_ack_error));
 integer bitno=0,transactions=0,reads=0,writes=0,checks=0;
 reg [63:0] shift=0;reg [15:0] page=0,txcr=16'hb5a5,anar=16'h0de1;
 reg [15:0] gbcr=16'h0100,bmcr=16'h1140,eee=16'h0006,mmd=0,mmdaddr=0;
 reg [15:0] physr=16'h002c,response=0;
 reg [4:0] ra=0,pa=0;reg [1:0] op=0;
 reg no_ack=0,bad_id=0,ignore_delay_write=0;
 reg [4:0] device_addr=1;
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
 // Clause22 Z0: after rising edge46 (Z), launch TA0 for edge47; after
 // edge47 launch D15 for edge48, through D0 after edge62 for edge63.
 // The MAC samples the PREVIOUSLY launched bit on each rising edge. Late-high
 // sampling instead captures the NEXT bit and appends idle1 to the read word.
 always @(posedge mdc) begin
  check(phy_reset_n,"MDIO during hardware reset");
  if(SETTLE_TEST_MS>=200)
   check($realtime-release_time>=200000000,"MDIO before production 200 ms settle");
  check($realtime-last_fall>=500,"MDC low duration");last_rise=$realtime;
  if(bitno<46 || op==1) begin
   check(oe,"host released a driven command bit");
   check(!phy_drive,"bus contention");
  end else check(!oe,"host drove read turnaround/data");
  shift={shift[62:0],mdio};
  if(bitno<32)check(mdio===1'b1,"preamble is not 32 ones");
  if(bitno==45) begin
   check(shift[13:12]==1,"start bits");op=shift[11:10];pa=shift[9:5];ra=shift[4:0];
   // Only read-only probes may address absent devices. A broadcast or write
   // to an unverified address is a regression failure, not a simulated success.
   check(pa>=1 && pa<=7,"broadcast/out-of-range address");check(op==1||op==2,"opcode");
   if(op==1)check(pa==device_addr,"write to unverified PHY address");
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
  // Independently model register inaccessibility during the documented boot
  // window. This is deliberately NOT derived from the DUT settle parameter.
  if(op==2 && bitno>=46 && !no_ack && pa==device_addr &&
     $realtime-release_time>=150000000) begin
   if(bitno==63) begin
    phy_drive<=#PHY_READ_DELAY_NS 1'b0;phy_bit<=#PHY_READ_DELAY_NS 1'b1;
   end else begin
    phy_drive<=#PHY_READ_DELAY_NS 1'b1;
    phy_bit<=#PHY_READ_DELAY_NS ((bitno==46)?1'b0:response[62-bitno]);
   end
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
  if(SETTLE_TEST_MS<150) begin
   wait(fault);
   check(fault_code==1 && !configured && !link_ready && writes==0 &&
         selected_addr==7 && last_ack_error && last_read==16'hffff,
         "premature scan must reproduce boot-window no-ACK without writes");
   $display("PHY_INIT_PASS early_access_rejected checks=%0d transactions=%0d",checks,transactions);
   $finish;
  end
  // Fail promptly with raw evidence if a sampling regression shifts the ID.
  wait(configured || fault);#1000;
  $display("PHY_FIRST_ID raw=%04h fault=%0d code=%0d read_delay_ns=%0d",last_read,fault,fault_code,PHY_READ_DELAY_NS);
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
  // Strap address7 must be discovered without any writes to absent addresses.
  device_addr=7;reboot();wait(configured);
  check(selected_addr==7 && id==32'h001cc916 && !fault,"address7 discovery");
  // With every address absent, exhaust the bounded scan and retain evidence.
  no_ack=1;reboot();wait(fault);
  check(fault_code==1 && selected_addr==7 && diagnostic_step==0 &&
        last_read==16'hffff && last_ack_error,"scan exhaustion diagnostics");
  $display("PHY_INIT_PASS checks=%0d transactions=%0d reads=%0d writes=%0d",checks,transactions,reads,writes);
  $finish;
 end
 // Six full hardware boots now include the real 200 ms settling interval.
 initial begin #1600000000;$fatal(1,"PHY_INIT_TIMEOUT");end
endmodule
