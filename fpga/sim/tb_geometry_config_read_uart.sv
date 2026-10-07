`timescale 1ns/1ps
// Purpose: exercise predecoded config READ through real 115200-baud RX/TX,
// asserting setup before acceptance and fresh snapshots on frame activation.
// Parser signals are observed for timing only; no force or byte injection.
module tb_geometry_config_read_uart;
 parameter integer CLK_HZ=1843200;
 localparam real BIT_NS=1.0e9/115200,CLK_NS=1.0e9/CLK_HZ;
 reg clk=0,rst_n=0,rx=1;always #(CLK_NS/2)clk=~clk;
 wire tx,context_valid,command_valid;wire [31:0] session_id;
 wire [7:0] command,code;wire [255:0] payload;wire [95:0] reply;
 reg frame_start=0,arm_activate=0;reg [63:0] source_id=64'h12345678abcdef01;
 wire [447:0] words;wire [31:0] version;wire [63:0] applied;
 wire [1:0] model,build_model;wire enhance,bank,build_start,build_bank,busy,failed,pending;
 wire lut_done,lut_failed;wire signed [31:0] k1,k2,k3,k4;
 mcu_protocol #(.CLK_HZ(CLK_HZ),.GEOMETRY_CONTROL(1)) uart(
  .clk(clk),.rst_n(rst_n),.uart_rx(rx),.uart_tx(tx),.link_epoch(64'd7),.link_epoch_valid(1'b1),
  .board_time_us(64'd0),.status_flags(32'd0),.board_diagnostics(96'd0),.video_diagnostics(96'd0),.chain_diagnostics(288'd0),
  .session_active(context_valid),.current_session_id(session_id),.geometry_command_valid(command_valid),
  .geometry_command(command),.geometry_payload(payload),.geometry_code(code),.geometry_reply(reply),
  .env_valid(),.env_session_id(),.env_event_seq(),.env_mcu_time_us(),.env_board_time_us(),
  .env_lux_milli(),.env_angle_mdeg(),.env_measurement_valid(),.rx_good_count(),.rx_error_count(),.tx_overflow_count());
 geometry_config_bank #(.PREDECODE_READ(1)) config_bank(
  .clk(clk),.rst_n(rst_n),.context_valid(context_valid),.epoch(64'd7),.session_id(session_id),
  .cmd_valid(command_valid),.cmd(command),.payload(payload),.code(code),.reply(reply),
  .frame_start(frame_start),.source_frame_id(source_id),.active_words(words),.active_model(model),
  .active_enhance(enhance),.active_bank(bank),.active_version(version),.applied_frame_id(applied),
  .build_busy(busy),.build_failed(failed),.pending(pending),.build_start(build_start),.build_bank(build_bank),
  .build_model(build_model),.k1(k1),.k2(k2),.k3(k3),.k4(k4),.build_done(lut_done),.lut_failed(lut_failed));
 geometry_lens_lut lut(.clk(clk),.rst_n(rst_n),.start(build_start),.build_bank(build_bank),
  .model(build_model),.k1(k1),.k2(k2),.k3(k3),.k4(k4),.busy(),.done(lut_done),.failed(lut_failed),
  .read_bank(bank),.read_index(11'd0),.scale0(),.scale1());
 integer checks=0,responses=0,expected=0,read_accepts=0,stable_edges=0,min_setup=32'h7fffffff;
 integer activation_edges=0,fresh_reads=0,n,b,v;reg [63:0] previous_address=0;
 reg [255:0] received[0:255],request_payload,last;
 reg [95:0] accepted_reply[0:255];reg [255:0] accepted_valid=0;
 reg previous_activation=0;
 task check(input bit ok,input string label_text);
  begin checks=checks+1;if(!ok)$fatal(1,"CONFIG_READ_UART_FAIL clk=%0d %s",CLK_HZ,label_text);end
 endtask
 function [15:0] crc_byte(input [15:0] prior,input [7:0] value);
  integer k;reg [15:0] c;begin c=prior;
   for(k=7;k>=0;k=k-1)begin if(c[15]^value[k])c=(c<<1)^16'h1021;else c=c<<1;end
   crc_byte=c;end
 endfunction
 function [31:0] parameter_word(input integer ver,idx);
  begin
   case(idx)
    0,4:parameter_word=32'd262144;
    2:parameter_word=ver*12345;
    10,11:parameter_word=32'd16777216;
    default:parameter_word=0;
   endcase
  end
 endfunction
 function [255:0] prefix;
  begin prefix=0;prefix[63:0]=7;prefix[95:64]=3;end
 endfunction
 task octet(input [7:0] value);integer k;begin
  rx=0;#(BIT_NS);for(k=0;k<8;k=k+1)begin rx=value[k];#(BIT_NS);end rx=1;#(BIT_NS);
 end endtask
 task send(input [7:0] op,input integer length,input bit corrupt);
  integer k;reg [15:0] crc;reg [7:0] value;begin
   octet(8'h55);octet(8'haa);crc=16'hffff;
   for(k=0;k<6+length;k=k+1)begin
    case(k)0:value=1;1:value=op;2:value=expected;3:value=0;4:value=length;5:value=0;
     default:value=request_payload[(k-6)*8+:8];endcase
    crc=crc_byte(crc,value);octet(value);
   end
   if(corrupt)crc=crc^1;octet(crc[7:0]);octet(crc[15:8]);
  end
 endtask
 // An independent serial decoder checks every byte frame, envelope and CRC.
 // READ data is also compared with the exact same-edge acceptance snapshot.
 initial begin:monitor
  reg [7:0] value,crc_low,op;reg [15:0] seq,crc;
  reg [255:0] p;integer k,offset;
  offset=0;p=0;crc=16'hffff;seq=0;
  forever begin
   @(negedge tx);#(BIT_NS/2);check(tx===0,"TX start");
   for(k=0;k<8;k=k+1)begin #(BIT_NS);value[k]=tx;end
   #(BIT_NS);check(tx===1,"TX stop");
   case(offset)
    0:check(value==8'h55,"sync55");1:check(value==8'haa,"syncaa");
    2:begin check(value==1,"envelope version");crc=16'hffff;end
    3:op=value;4:seq[7:0]=value;5:seq[15:8]=value;
    6:check(value==32,"reply length low");7:check(value==0,"reply length high");
   endcase
   if(offset>=2 && offset<40)crc=crc_byte(crc,value);
   if(offset>=8 && offset<40)p[(offset-8)*8+:8]=value;
   if(offset==40)crc_low=value;
   if(offset==41)begin
    check({value,crc_low}==crc,"reply CRC");check(seq==responses,"reply sequence");
    check(op==(p[7:0]<2?8'h80:8'h81),"ACK/NACK envelope");
    if(p[15:8]==8'h34 && p[7:0]==0)begin
     check(accepted_valid[seq],"READ was accepted");
     check(p[255:160]===accepted_reply[seq],"wire reply equals acceptance-edge snapshot");
    end
    received[responses]=p;responses=responses+1;offset=0;
   end else offset=offset+1;
  end
 end
 task expect_code(input [7:0] wanted);begin
  wait(responses>expected);last=received[expected];expected=expected+1;
  check(last[7:0]==wanted,$sformatf("code expected=%0d got=%0d",wanted,last[7:0]));
 end endtask
 // Observe the actual CRC1 byte delivery, then assert only the public frame
 // input. Activation and parser.done occur together; UART push is NEXT edge.
 // Registering data instead of selectors would return stale values here.
 always @(negedge clk)begin
  frame_start=0;
  if(rst_n && arm_activate && uart.byte_valid && uart.u_parser.state==10)begin
   frame_start=1;arm_activate=0;
  end
 end
 always @(posedge clk)if(rst_n)begin
  if(payload[159:96]!==previous_address)stable_edges=0;else stable_edges=stable_edges+1;
  previous_address=payload[159:96];
  if(command_valid && command==8'h34)begin
   check(stable_edges>=1,"READ selectors stable at least one preceding edge");
   if(stable_edges<min_setup)min_setup=stable_edges;
   accepted_reply[uart.request_seq]=reply;accepted_valid[uart.request_seq]=1;
   read_accepts=read_accepts+1;
   if(previous_activation)begin
    check(reply[95:64]==version,"fresh version immediately after activation");
    if(payload[127:96]==14)check(reply[63:32]==4,"fresh pending/status bits");
    else check(reply[63:32]==parameter_word(version,2),"fresh active word");
    fresh_reads=fresh_reads+1;
   end
   // Existing MCU contract: pending data captures on push, no additional edge.
   #0.001;check(uart.pending_geometry_data===accepted_reply[uart.request_seq],"unchanged snapshot capture edge");
  end
  previous_activation=frame_start && pending;
  if(previous_activation)activation_edges=activation_edges+1;
 end
 task read_word(input [31:0] idx,which_bank,expected_data,expected_version);
  begin
   request_payload=prefix();request_payload[127:96]=idx;request_payload[159:128]=which_bank;
   send(8'h34,20,0);expect_code(0);
   check(last[191:160]==idx && last[223:192]==expected_data && last[255:224]==expected_version,
         $sformatf("READ idx=%0d bank=%0d data=%h expected=%h version=%0d",idx,which_bank,last[223:192],expected_data,expected_version));
  end
 endtask
 initial begin
  repeat(6)@(negedge clk);rst_n=1;repeat(6)@(negedge clk);
  request_payload=prefix();send(2,12,0);expect_code(0);
  for(v=1;v<=2;v=v+1)begin
   request_payload=prefix();request_payload[127:96]=v;
   request_payload[135:128]=0;request_payload[143:136]=1;
   request_payload[159:144]=1920;request_payload[175:160]=1080;
   send(8'h30,24,0);expect_code(0);
   for(n=0;n<14;n=n+1)begin
    request_payload=prefix();request_payload[127:96]=v;request_payload[159:128]=n;
    request_payload[191:160]=parameter_word(v,n);send(8'h31,24,0);expect_code(0);
   end
   request_payload=prefix();request_payload[127:96]=v;send(8'h32,16,0);expect_code(0);
   wait(pending);check(version==v-1 && !failed,"COMMIT stages without applying");
   source_id=64'h12345678abcdef00+v;arm_activate=1;
   // First activation exercises live status; second exercises changed word data.
   if(v==1)read_word(14,1,4,v);else read_word(2,1,parameter_word(v,2),v);
   check(version==v && applied==source_id,"activation identity");
   for(b=0;b<2;b=b+1)for(n=0;n<18;n=n+1)begin
    if(n<14)read_word(n,b,parameter_word(v,n),v);
    else if(n==14)read_word(n,b,4,v);
    else if(n==15)read_word(n,b,32'h3fff,v);
    else if(n==16)read_word(n,b,source_id[31:0],v);
    else read_word(n,b,source_id[63:32],v);
   end
  end
  // Invalid high address/bank bits and transport errors cannot alias a word.
  request_payload=prefix();request_payload[127:96]=32'h80000000;send(8'h34,20,0);expect_code(11);
  request_payload[127:96]=0;request_payload[159:128]=32'h80000000;send(8'h34,20,0);expect_code(11);
  request_payload[159:128]=1;send(8'h34,20,1);expect_code(2);
  send(8'h34,19,0);expect_code(3);
  request_payload[95:64]=4;send(8'h34,20,0);expect_code(8);
  check(activation_edges==2 && fresh_reads==2,"both acceptance-adjacent activation cases covered");
  $display("CONFIG_READ_UART_PASS clk=%0d checks=%0d responses=%0d read_accepts=%0d min_setup_edges=%0d fresh_reads=%0d",
           CLK_HZ,checks,responses,read_accepts,min_setup,fresh_reads);$finish;
 end
 initial begin #1500000000;$fatal(1,"CONFIG_READ_UART_TIMEOUT");end
endmodule
