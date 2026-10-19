`timescale 1ns/1ps
// Independent transaction/data scoreboard; no behavioral replacement of DUT RAM.
module write_cdc_tb #(parameter real CLIENT_HALF=3.333,MEMORY_HALF=4.0,MEMORY_PHASE=0.7);
 reg client_clk=0,memory_clk=0,client_rst_n=0,memory_rst_n=0;
 always #(CLIENT_HALF)client_clk=~client_clk;
 initial begin #(MEMORY_PHASE);forever #(MEMORY_HALF)memory_clk=~memory_clk;end
 reg req_valid=0,cancel=0,w_valid=0,done_ready=0;
 reg [31:0] req_addr=0,req_tag=0,w_strb=0;reg [4:0] req_beats=0;reg [255:0] w_data=0;
 wire req_ready,w_ready,done,error,cancelled;wire [31:0] done_tag;
 wire memory_req_valid,memory_cancel,memory_w_valid,memory_done_ready;
 wire [31:0] memory_req_addr,memory_req_tag,memory_w_strb;wire [4:0] memory_req_beats;
 wire [255:0] memory_w_data;
 reg memory_req_ready=0,memory_w_ready=0,memory_done=0,memory_error=0,memory_cancelled=0;
 reg [31:0] memory_done_tag=0;
 dma_write_cdc dut(.*);
 integer mode=0,identifier=0,expected_beats=0,received=0,requests=0,beats=0,cases=0;
 integer cancelled_cases=0,error_cases=0,memory_cycle=0,last_beat_cycle=0,write_stalls=0;
 reg [31:0] expected_addr,expected_tag,rng=32'h17432abc;
 reg pending=0,force_request_stall=0,request_stalled=0,write_stalled=0,previous_completion=0;
 reg [68:0] held_request;reg [287:0] held_write;
 function [255:0] value(input integer id,index);
  begin for(integer lane=0;lane<8;lane++)
   value[lane*32+:32]=32'h9e3779b9^(id*32'h1020305)^(index*32'h31415927)^(lane*32'h70f17);
  end
 endfunction
 function [31:0] strobe(input integer id,index);
  strobe=32'hf0f0a5a5^(id*32'h1010101)^index;
 endfunction
 always @(negedge memory_clk)begin
  if(!memory_rst_n)begin memory_req_ready=0;memory_w_ready=0;memory_done=0;end
  else begin
   rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
   memory_req_ready=!force_request_stall && (mode==6 || rng[0] || rng[3]);
   memory_w_ready=(mode==6 || rng[1] || rng[2]);
   memory_done=pending && (memory_cancel || received==expected_beats ||
                     ((mode==3 || mode==5) && received>=3));
   memory_error=mode==3;memory_cancelled=memory_cancel;
   memory_done_tag=expected_tag^(mode==4 ? 32'd1:32'd0);
  end
 end
 always @(posedge memory_clk or negedge memory_rst_n)begin
  if(!memory_rst_n)begin
   pending=0;received=0;request_stalled=0;write_stalled=0;previous_completion=0;memory_cycle=0;
  end else begin
   memory_cycle++;
   if(request_stalled && (!memory_req_valid ||
      {memory_req_tag,memory_req_addr,memory_req_beats}!==held_request))
    $fatal(1,"WRITE_CDC request withdrew/changed during stall or cancel");
   if(write_stalled && !previous_completion && !memory_cancel &&
      (!memory_w_valid || {memory_w_data,memory_w_strb}!==held_write))
    $fatal(1,"WRITE_CDC data changed under backpressure");
   request_stalled=memory_req_valid && !memory_req_ready;
   held_request={memory_req_tag,memory_req_addr,memory_req_beats};
   write_stalled=memory_w_valid && !memory_w_ready;
   held_write={memory_w_data,memory_w_strb};
   previous_completion=memory_done && memory_done_ready;
   if(write_stalled)write_stalls++;
   if(memory_req_valid && memory_req_ready)begin
    if(pending || memory_req_addr!==expected_addr || memory_req_tag!==expected_tag || memory_req_beats!==expected_beats)
     $fatal(1,"WRITE_CDC immutable descriptor/one-transaction ownership");
    pending=1;received=0;requests++;
   end
   if(memory_w_valid && memory_w_ready)begin
    if(!pending || received>=expected_beats || memory_w_data!==value(identifier,received) ||
       memory_w_strb!==strobe(identifier,received))
     $fatal(1,"WRITE_CDC data/mask order id=%0d index=%0d",identifier,received);
    if(mode==6 && received>0 && memory_cycle!=last_beat_cycle+1)
     $fatal(1,"WRITE_CDC unnecessary inter-beat bubble");
    last_beat_cycle=memory_cycle;received++;beats++;
   end
   if(memory_done && memory_done_ready)begin
    if(!pending)$fatal(1,"WRITE_CDC completion without ownership");
    pending=0;
   end
  end
 end
 task cold_reset;
  begin
   @(negedge client_clk);client_rst_n=0;memory_rst_n=0;
   req_valid=0;w_valid=0;cancel=0;done_ready=0;force_request_stall=0;
   repeat(5)@(negedge client_clk);repeat(3)@(negedge memory_clk);
   @(negedge client_clk);client_rst_n=1;
   @(negedge memory_clk);memory_rst_n=1;
   repeat(5)@(negedge client_clk);
   if(!req_ready || done || memory_req_valid || memory_w_valid)
    $fatal(1,"WRITE_CDC phantom activity after common cold reset");
  end
 endtask
 task begin_request(input integer count,scenario);
  begin
   identifier++;mode=scenario;expected_beats=count;
   expected_addr=32'h100000+identifier*32'h1000;expected_tag=32'h81000000+identifier;
   @(negedge client_clk);while(!req_ready)@(negedge client_clk);
   req_addr=expected_addr;req_tag=expected_tag;req_beats=count;req_valid=1;cancel=scenario==8;
   @(posedge client_clk);@(negedge client_clk);req_valid=0;
   // Invalid payload after the accepted descriptor must never change it.
   req_addr=32'hbadbadba;req_tag=32'hdeadbeef;req_beats=31;
  end
 endtask
 task send_beat(input integer index);
  begin
   @(negedge client_clk);w_valid=1;w_data=value(identifier,index);w_strb=strobe(identifier,index);
   while(!w_ready)@(negedge client_clk);
   @(posedge client_clk);@(negedge client_clk);w_valid=0;w_data='x;w_strb='x;
  end
 endtask
 task finish_request(input logic expected_error,expected_cancel,input [31:0] expected_done_tag);
  begin
   wait(done);@(negedge client_clk);
   repeat(4)begin
    @(posedge client_clk);#1;
    if(!done || error!==expected_error || cancelled!==expected_cancel || done_tag!==expected_done_tag)
     $fatal(1,"WRITE_CDC stable drained status id=%0d mode=%0d got=%b/%b/%h expected=%b/%b/%h",
       identifier,mode,error,cancelled,done_tag,expected_error,expected_cancel,expected_done_tag);
   end
   if(expected_error)error_cases++;if(expected_cancel)cancelled_cases++;
   @(negedge client_clk);done_ready=1;@(posedge client_clk);
   @(negedge client_clk);done_ready=0;cancel=0;cases++;
  end
 endtask
 task transaction(input integer count,scenario);
  integer before_requests;
  begin
   before_requests=requests;force_request_stall=scenario==2;
   begin_request(count,scenario);
   if(scenario!=7 && scenario!=8)
    for(integer j=0;j<count;j++)send_beat(j);
   if(scenario==2)begin
    wait(memory_req_valid);@(negedge client_clk);cancel=1;
    repeat(6)begin @(posedge memory_clk);#1;if(!memory_req_valid)$fatal(1,"Request lost before admission");end
    force_request_stall=0;
   end
   if(scenario==9)begin wait(received>=3);@(negedge client_clk);cancel=1;end
   finish_request(scenario==3 || scenario==4 || scenario==5 || scenario==7,
                  scenario==2 || scenario==8 || scenario==9,expected_tag^(scenario==4?32'd1:32'd0));
   repeat(4)@(negedge memory_clk);
   if(requests-before_requests!==((scenario==7 || scenario==8)?0:1))
    $fatal(1,"WRITE_CDC unexpected native request count");
  end
 endtask
 initial begin
  cold_reset;
  for(integer iteration=0;iteration<3;iteration++)begin
   transaction(1,0);transaction(2,0);transaction(3,0);transaction(7,0);
   transaction(8,0);transaction(15,0);transaction(16,6);
  end
  begin : local_cancel
   integer before_requests;before_requests=requests;
   begin_request(8,0);send_beat(0);send_beat(1);@(negedge client_clk);cancel=1;
   finish_request(0,1,expected_tag);repeat(5)@(negedge memory_clk);
   if(requests!=before_requests)$fatal(1,"Partial local burst escaped to DDR");
  end
  transaction(8,2);transaction(16,3);transaction(16,4);transaction(16,5);
  transaction(0,7);transaction(17,7);transaction(4,8);transaction(16,9);
  begin_request(16,0);send_beat(0);send_beat(1);cold_reset;transaction(4,0);
  begin_request(16,0);for(integer j=0;j<16;j++)send_beat(j);
  wait(received>=3);cold_reset;transaction(16,6);
  if(cases<30 || cancelled_cases<4 || error_cases<5 || write_stalls<1)
   $fatal(1,"WRITE_CDC insufficient independent scenario coverage");
  $display("WRITE_CDC_PASS cases=%0d requests=%0d beats=%0d errors=%0d cancels=%0d stalls=%0d",
            cases,requests,beats,error_cases,cancelled_cases,write_stalls);$finish;
 end
 initial begin #2000000;$fatal(1,"WRITE_CDC timeout");end
endmodule
