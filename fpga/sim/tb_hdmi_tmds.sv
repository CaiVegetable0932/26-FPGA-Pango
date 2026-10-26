`timescale 1ns/1ps
// Purpose: three-channel independent TMDS reference with running disparity,
// exact blanking tokens and encoder metadata latency. Native serializers are
// instantiated; exhaustive bit-order validation also runs tb_tmds_serializer.
module tb_hdmi_tmds;
 reg serial_clk=0;always #1.346801 serial_clk=~serial_clk;
 reg grs_n=0,start_n=0,pixel_rst_n=0;
`ifdef HDMI_ENCODER_ONLY
 // The portable case checks encoder symbols/metadata only. It deliberately
 // excludes encrypted native serializer models and makes no bit-order claim.
 reg pixel_clk=0;always #6.734 pixel_clk=~pixel_clk;
`else
 wire pixel_clk;
`endif
 wire [2:0] dp,dn;wire cp,cn,tag;
 reg [23:0] rgb=0;reg hs=0,vs=0,de=0,valid=0;
 reg [63:0] id=0,epoch=9;reg [31:0] gen=0;
 wire [63:0] out_epoch,out_id;wire [31:0] out_gen;
`ifndef HDMI_ENCODER_ONLY
 GTP_GRS global_reset(.GRS_N(grs_n));
 GTP_IOCLKDIV_E2 #(.DIV_FACTOR("5")) divider(.CLKIN(serial_clk),.RST_N(start_n),.CE(1'b1),.CLKDIVOUT(pixel_clk));
`endif
 hdmi_rgb888_tx tx(.pixel_clk(pixel_clk),.serial_clk(serial_clk),.pixel_rst_n(pixel_rst_n),.serializer_reset(!start_n),
 .rgb(rgb),.hs(hs),.vs(vs),.de(de),.tag_valid(valid),.epoch(epoch),.source_frame_id(id),.generation(gen),
 .data_p(dp),.data_n(dn),.clock_p(cp),.clock_n(cn),.symbol_tag_valid(tag),
 .symbol_epoch(out_epoch),.symbol_source_frame_id(out_id),.symbol_generation(out_gen));
 integer disparity[0:2],checks=0,words=0,k,lane,step;
 reg [9:0] history[0:2][0:2];reg [2:0] valid_history=0;
 reg [63:0] ids[0:2],epochs[0:2];reg [31:0] gens[0:2];
 // Purpose: reference uses signed integer arithmetic rather than the DUT's
 // five-bit counter. It compares the exact emitted 10-bit word, not decode only.
 task automatic reference_word(input [7:0] value,input bit active,input [1:0] control,inout integer balance,output [9:0] word);
  reg [8:0] qm;integer ones,n,delta;bit use_xnor,invert;
  begin
   if(!active)begin
    balance=0;
    case(control)0:word=10'b1101010100;1:word=10'b0010101011;2:word=10'b0101010100;3:word=10'b1010101011;endcase
   end else begin
    ones=0;for(n=0;n<8;n++)ones+=value[n];use_xnor=ones>4 || (ones==4 && !value[0]);
    qm[0]=value[0];for(n=1;n<8;n++)qm[n]=qm[n-1]^value[n]^use_xnor;qm[8]=!use_xnor;
    ones=0;for(n=0;n<8;n++)ones+=qm[n];delta=2*ones-8;
    if(balance==0 || delta==0)begin
     word={~qm[8],qm[8],qm[7:0]^{8{!qm[8]}}};balance+=qm[8]?delta:-delta;
    end else begin
     invert=(balance>0 && delta>0)||(balance<0 && delta<0);
     word={invert,qm[8],qm[7:0]^{8{invert}}};
     balance+=invert?(2*qm[8]-delta):(delta-2*!qm[8]);
    end
   end
  end
 endtask
 task check(input bit ok,input string message_text);
  begin checks++;if(!ok)begin $display("HDMI_TMDS_FAIL %s step=%0d lane=%0d",message_text,step,lane);$fatal(1);end end
 endtask
 always @(posedge pixel_clk)begin
  if(!pixel_rst_n)begin
   valid_history=0;
   for(lane=0;lane<3;lane++)begin disparity[lane]=0;for(k=0;k<3;k++)begin history[lane][k]=0;ids[k]=0;epochs[k]=0;gens[k]=0;end end
  end else begin
   for(lane=0;lane<3;lane++)begin
    history[lane][2]=history[lane][1];history[lane][1]=history[lane][0];
    reference_word(rgb[lane*8+:8],de,lane==0?{vs,hs}:2'b00,disparity[lane],history[lane][0]);
   end
   valid_history={valid_history[1:0],valid && de};
   for(k=2;k>0;k--)begin ids[k]=ids[k-1];epochs[k]=epochs[k-1];gens[k]=gens[k-1];end
   ids[0]=id;epochs[0]=epoch;gens[0]=gen;
   #2;
   if(words>=3)begin
    for(lane=0;lane<3;lane++)check(tx.symbols[lane]===history[lane][2],"exact TMDS word / disparity / control");
    check(tag===valid_history[2] && out_id==ids[2] && out_gen==gens[2] && out_epoch==epochs[2],"three-stage source tag alignment");
   end
   words++;
  end
 end
 initial begin
  #100;grs_n=1;start_n=1;repeat(12)@(negedge pixel_clk);pixel_rst_n=1;
  // Each byte value appears on every lane; alternate long active runs with all
  // four blanking controls, then reset mid-stream and verify deterministic restart.
  for(step=0;step<4096;step++)begin
   @(negedge pixel_clk);rgb={8'(step*13),8'(step*7+1),8'(step)};
   de=step%261<256;hs=step[0];vs=step[1];valid=step[2];id=step;gen=step/256;
  end
  @(negedge pixel_clk);pixel_rst_n=0;de=0;valid=0;words=0;
  repeat(8)@(negedge pixel_clk);pixel_rst_n=1;
  repeat(12)@(negedge pixel_clk);
  $display("HDMI_TMDS_PASS checks=%0d",checks);$finish;
 end
 initial begin #1000000;$fatal(1,"HDMI_TMDS_TIMEOUT");end
endmodule
