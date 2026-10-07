`timescale 1ns/1ps
// Purpose: compare the default combinational API against a frozen pre-change
// implementation, and the opt-in selectors after their documented setup edge.
// Configuration transitions use public ports, including LUT completion/errors.
module tb_geometry_config_predecode;
 reg clk=0,rst_n=0,context_valid=1,cmd_valid=0,frame_start=0,build_done=0,lut_failed=0;
 always #5 clk=~clk;
 reg [63:0] epoch=7,source_frame_id=64'h123456789abcdef0;
 reg [31:0] session_id=3;
 reg [7:0] cmd=0;
 reg [255:0] payload=0;
 wire [7:0] code[0:2];wire [95:0] reply[0:2];wire [782:0] state[0:2];
 integer checks=0,reads=0,i,j,round_no;reg [31:0] rng=32'hb78153ac;
 // The reference module is renamed only in the isolated build directory.
 `define CONFIG_PORTS .clk(clk),.rst_n(rst_n),.context_valid(context_valid),.epoch(epoch), \
  .session_id(session_id),.cmd_valid(cmd_valid),.cmd(cmd),.payload(payload), \
  .code(code[unit_no]),.reply(reply[unit_no]),.frame_start(frame_start),.source_frame_id(source_frame_id), \
  .active_words(words),.active_model(model),.active_enhance(enhance),.active_bank(bank), \
  .active_version(version),.applied_frame_id(applied),.build_busy(busy),.build_failed(failed), \
  .pending(pending),.build_start(build_start),.build_bank(build_bank),.build_model(build_model), \
  .k1(k1),.k2(k2),.k3(k3),.k4(k4),.build_done(build_done),.lut_failed(lut_failed)
 genvar unit_no;
 generate for(unit_no=0;unit_no<3;unit_no=unit_no+1)begin:g_unit
  wire [447:0] words;wire [1:0] model,build_model;
  wire enhance,bank,busy,failed,pending,build_start,build_bank;
  wire [31:0] version,k1,k2,k3,k4;wire [63:0] applied;
  assign state[unit_no]={words,model,enhance,bank,version,applied,
                        busy,failed,pending,build_start,build_bank,build_model,k1,k2,k3,k4};
  if(unit_no==0)begin:r
   geometry_config_bank_reference dut(`CONFIG_PORTS);
  end else if(unit_no==1)begin:d
   geometry_config_bank dut(`CONFIG_PORTS);
  end else begin:p
   geometry_config_bank #(.PREDECODE_READ(1)) dut(`CONFIG_PORTS);
  end
 end endgenerate
 `undef CONFIG_PORTS
 task check(input bit ok,input string label_text);
  begin checks=checks+1;if(!ok)$fatal(1,"CONFIG_PREDECODE_FAIL %s cmd=%h payload=%h",label_text,cmd,payload);end
 endtask
 task legacy_now;
  begin check({code[0],reply[0]}==={code[1],reply[1]},"default immediate reply");end
 endtask
 task settled;
  begin
   check(state[0]===state[1] && state[0]===state[2],"all public state identical");
   legacy_now();check({code[0],reply[0]}==={code[2],reply[2]},"predecoded live reply");
  end
 endtask
 task tick;
  begin @(posedge clk);#1;settled();end
 endtask
 task issue(input [7:0] op,input [31:0] ver,idx,value);
  begin
   @(negedge clk);cmd=op;payload=0;payload[127:96]=ver;
   payload[159:128]=idx;payload[191:160]=value;cmd_valid=1;
   #1;legacy_now();tick();@(negedge clk);cmd_valid=0;
  end
 endtask
 // Every READ changes its address before any rising edge: this catches an
 // accidental one-clock latency in the default API, including high invalid bits.
 task read_all;
  begin
   for(j=0;j<4;j=j+1)for(i=0;i<22;i=i+1)begin
    @(negedge clk);cmd=8'h34;payload[127:96]=(i==21)?32'h80000000:i;
    payload[159:128]=(j==3)?32'h80000000:j;#1;legacy_now();tick();reads=reads+1;
   end
  end
 endtask
 initial begin
  repeat(3)@(negedge clk);rst_n=1;tick();read_all();
  for(round_no=1;round_no<=4;round_no=round_no+1)begin
   issue(8'h30,round_no,(1920<<16)|((round_no&1)<<8)|(round_no%3),32'd1080);
   for(i=0;i<14;i=i+1)issue(8'h31,round_no,i,(i==10 || i==11)?32'd65536:round_no*100+i);
   // Duplicate/conflicting WORDs and invalid indices retain their old codes.
   issue(8'h31,round_no,0,round_no*100);
   issue(8'h31,round_no,0,round_no*100+1);
   issue(8'h31,round_no,14,32'hffffffff);
   issue(8'h32,round_no,0,0);read_all();
   @(negedge clk);build_done=1;lut_failed=(round_no==3);tick();
   @(negedge clk);build_done=0;read_all();
   // Hold selectors across activation: data must change immediately after the
   // activation edge, not one cycle later as a registered-value fix would do.
   @(negedge clk);cmd=8'h34;payload[127:96]=0;payload[159:128]=1;tick();
   @(negedge clk);frame_start=1;source_frame_id=source_frame_id+1;tick();
   @(negedge clk);frame_start=0;read_all();
  end
  // Deterministic mixed control traffic covers context loss and simultaneous
  // build/frame events without assuming private storage or admission signals.
  for(i=0;i<2000;i=i+1)begin
   @(negedge clk);rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
   cmd=8'h30+(rng%7);payload[127:96]=rng%24;payload[159:128]=(rng>>8)%18;
   payload[191:160]=rng;cmd_valid=rng[17];frame_start=rng[18];
   build_done=rng[19];lut_failed=rng[20];context_valid=|rng[22:21];
   if(rng[27:24]==0)session_id=session_id+1;
   #1;legacy_now();tick();
  end
  $display("CONFIG_PREDECODE_PASS checks=%0d immediate_reads=%0d random_cycles=2000",checks,reads);$finish;
 end
 initial begin #1000000;$fatal(1,"CONFIG_PREDECODE_TIMEOUT");end
endmodule
