`timescale 1ns/1ps
// Synthetic camera policy/service checks prove bounds and stopped transitions,
// never optical frame timing. The service mock checks every actual register.
module tb_camera_brightness_control;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg submit=0;reg [383:0] body=0;reg [31:0] version=2;wire [7:0] code;wire [2303:0] status;
 reg quiet=0,boundary=0,stats=0;wire pause_capture,apply,apply_ready,done;wire [19:0] exp;wire [9:0] gain;
 wire [31:0] cv;wire [2:0] error;reg [47:0] sum=0;
 wire command;wire [15:0] address;wire [7:0] value,mask;wire [31:0] cookie;
 reg response=0;reg [2:0] response_error=0;reg [7:0] response_value=0;reg [31:0] response_cookie=0;
 reg inject_error=0;integer writes=0;reg [31:0] seen=0;
 camera_brightness_control #(.DRAIN_TIMEOUT(2000)) policy(.clk(clk),.rst_n(rst_n),.submit_valid(submit),.body(body),.version(version),.entity_id(32'd4),
  .submit_code(code),.status(status),.source_quiesced(quiet),.pause_capture(pause_capture),.apply_valid(apply),.apply_ready(apply_ready),
  .exposure(exp),.gain(gain),.apply_done(done),.apply_error(error),.capture_boundary(boundary),.capture_epoch(64'd2),.capture_frame(64'd99),
  .statistics_valid(stats),.luminance_sum(sum),.samples(32'd100),.capture_camera_version(cv));
 ov5640_exposure_update #(.TIMEOUT(1000)) update_sensor(.clk(clk),.rst_n(rst_n),.apply(apply),.quiesced(quiet),.exposure(exp),.gain(gain),
  .apply_ready(apply_ready),.done(done),.error(error),.busy(),.cmd_valid(command),.cmd_ready(1'b1),.cmd_write(),
  .cmd_addr(address),.cmd_value(value),.cmd_mask(mask),.cmd_cookie(cookie),.rsp_valid(response),.rsp_status(response_error),.rsp_value(response_value),.rsp_cookie(response_cookie));
 always @(posedge clk)begin
  response<=command;
  if(command)begin
   if(!quiet || !pause_capture)$fatal(1,"SCCB command while capture live");
   if(address==16'h380e || address==16'h380f || address==16'h3212)$fatal(1,"forbidden VTS/online group write");
   if(writes%12==0 && (address!=16'h3008 || value!=8'h40))$fatal(1,"standby must precede exposure");
   if(writes%12==11 && (address!=16'h3008 || value!=0))$fatal(1,"stream-on must follow verified group");
   writes<=writes+1;response_cookie<=cookie;response_value<=value;response_error<=inject_error?1:0;
  end
 end
 task send(input [7:0] expected);
  begin @(negedge clk);#1;if(code!==expected)$fatal(1,"camera submit code %d expected %d",code,expected);
   submit=1;@(negedge clk);submit=0;end
 endtask
 task admit;
  begin wait(!pause_capture);@(negedge clk);boundary=1;@(negedge clk);boundary=0;end
 endtask
 integer n;
 initial begin
  #22;rst_n=1;
  body[7:0]=1;body[23:16]=96;body[31:24]=144;body[32+:32]=1000;body[64+:16]=16;
  body[80+:16]=16;body[96+:16]=32;body[112+:16]=1;body[128+:32]=16;body[160+:32]=17856;
  body[192+:32]=256;body[224+:16]=1;body[240+:16]=2;
  send(0);repeat(8)@(negedge clk);if(writes!=0 || !pause_capture)$fatal(1,"did not wait for drain");
  quiet=1;admit();if(writes!=12 || cv!=2 || status[32+:32]!=2 || !status[114])$fatal(1,"fixed group status wrong");
  // Two settling frames and one held frame must precede the first AE change.
  for(n=0;n<3;n=n+1)begin @(negedge clk);stats=1;@(negedge clk);stats=0;end
  if(pause_capture)$fatal(1,"AE ignored settling/hold");
  @(negedge clk);stats=1;@(negedge clk);stats=0;wait(pause_capture);if(exp!=1256 || gain!=16)$fatal(1,"AE step wrong");admit();
  if(cv!=3 || writes!=24)$fatal(1,"AE did not retain independent new camera version");
  // Neither out-of-range mode nor excessive exposure may reach SCCB.
  version=4;body[7:0]=3;send(11);body[7:0]=0;body[32+:32]=17857;send(11);body[32+:32]=1000;
  inject_error=1;send(0);wait(status[120+:8]!=0);if(!pause_capture || status[32+:32]!=3)$fatal(1,"failed group overwrote last-good state");
  $display("CAMERA_BRIGHTNESS_PASS bounded AE, drain, SCCB mask/readback, failure and no VTS write");$finish;
 end
 initial begin #100000;$fatal(1,"CAMERA_BRIGHTNESS_TIMEOUT");end
endmodule
