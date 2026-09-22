`timescale 1ns/1ps
// Purpose: native FIFO packet bridge scoreboard at independent faster/slower
// clocks. Check every byte, no mid-frame gaps, IFG, error fail-stop and reset.
module tb_raw8_gmii_cdc #(parameter real RD_HALF=4.1);
 reg wc=0,rc=0,wn=0,rn=0,grs=0;reg [7:0] din=0;reg ien=0,ierr=0;
 wire [7:0] dout;wire oen,oerr,wfault,rfault;
 integer expected_packet=0,position=0,idle_cycles=100,checks=0,packets=0;
 integer i,j;reg observe=1;
 always #4 wc=~wc;always #(RD_HALF)rc=~rc;
 GTP_GRS GRS_INST(.GRS_N(grs));
 raw8_gmii_cdc dut(.wr_clk(wc),.wr_reset_n(wn),.in_data(din),.in_en(ien),.in_error(ierr),
  .rd_clk(rc),.rd_reset_n(rn),.out_data(dout),.out_en(oen),.out_error(oerr),.wr_fault(wfault),.rd_fault(rfault));
 function integer length_of(input integer fid);
  case(fid%8)0:length_of=1;1:length_of=31;2:length_of=32;3:length_of=33;
   4:length_of=64;5:length_of=1526;6:length_of=60;7:length_of=1460;endcase
 endfunction
 function [7:0] pattern(input integer fid,input integer offset);
  pattern=(fid*19+offset*7+91)&255;
 endfunction
 task check(input bit value,input string why);
  begin checks=checks+1;if(!value)$fatal(1,"RAW8_GMII_CDC_FAIL %s packet=%0d byte=%0d",why,expected_packet,position);end
 endtask
 // Independent receiver derives expected content only from stimulus identity.
 always @(posedge rc)begin
  #0.1;
  if(rn && observe)begin
   check(!rfault && !oerr,"no output fault");
   if(oen)begin
    if(position==0)check(idle_cycles>=12,"minimum interpacket gap");
    check(dout===pattern(expected_packet,position),"payload preserved across clocks");
    idle_cycles=0;position=position+1;
    if(position==length_of(expected_packet))begin position=0;expected_packet=expected_packet+1;packets=packets+1;end
   end else begin check(position==0,"no mid-packet gap");idle_cycles=idle_cycles+1;end
  end
 end
 task send(input integer fid);
  begin
   for(j=0;j<length_of(fid);j=j+1)begin @(negedge wc);ien=1;din=pattern(fid,j);end
   @(negedge wc);ien=0;
   repeat(12)@(negedge wc);
  end
 endtask
 task release_reset;
  begin fork begin repeat(6)@(negedge wc);wn=1;end
             begin repeat(6)@(negedge rc);rn=1;end join end
 endtask
 initial begin
  #17;grs=1;release_reset();
  for(i=0;i<80;i=i+1)send(i);
  wait(packets==80);repeat(30)@(negedge rc);
  check(!wfault && !rfault,"all native FIFO transactions accepted");
  // A MAC error must never publish the incomplete packet for transmission.
  @(negedge wc);ien=1;din=8'h55;ierr=1;
  @(negedge wc);ien=0;ierr=0;repeat(40)@(negedge rc);
  check(wfault && packets==80,"input error stops unpublished frame");
  // Both FIFO sides assert together; independently synchronized releases
  // must discard partial pre-reset records and accept a fresh packet identity.
  observe=0;wn=0;rn=0;#19;expected_packet=0;position=0;idle_cycles=100;packets=0;
  release_reset();observe=1;send(0);wait(packets==1);
  repeat(40)@(negedge rc);check(!wfault && !rfault,"reset recovery");
  $display("RAW8_GMII_CDC_PASS checks=%0d packets=81 rd_half=%0f",checks,RD_HALF);$finish;
 end
 initial begin #3000000;$fatal(1,"RAW8_GMII_CDC_TIMEOUT");end
endmodule
