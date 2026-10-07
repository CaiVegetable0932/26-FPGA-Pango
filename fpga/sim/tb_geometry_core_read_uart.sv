`timescale 1ns/1ps
// Purpose: real serial RX/parser/reply FIFO/TX -> production core read routing.
// Only underlying static status/snapshot storage is forced. No parser payload,
// selector, read value, reply or handshake is overridden. Camera/pixel domains
// stay reset: this is control-path evidence, NOT image/CDC/hardware validation.
module tb_geometry_core_read_uart;
 parameter integer CLK_HZ=125000000,BAUD=7812500,SMOKE=0;
 localparam real BIT_NS=1.0e9/BAUD,CLK_NS=1.0e9/CLK_HZ;
 reg clk=0,rst_n=0,rx=1;always #(CLK_NS/2)clk=~clk;
 // Native FIFO simulation models require this same global reset instance as
 // the existing board bench; this is simulation scaffolding, not board RTL.
 GTP_GRS GRS_INST(.GRS_N(rst_n));
 wire tx,context_valid,command_valid;wire [31:0] session_id;
 wire [7:0] command,code;wire [255:0] payload;wire [95:0] reply;
 wire [27:0] awaddr,araddr;wire awvalid,arvalid;
 mcu_protocol #(.CLK_HZ(CLK_HZ),.BAUD(BAUD),.GEOMETRY_CONTROL(1),.DISPLAY_CONTROL(1)) uart(
  .clk(clk),.rst_n(rst_n),.uart_rx(rx),.uart_tx(tx),.link_epoch(64'd7),.link_epoch_valid(1'b1),
  .board_time_us(64'd0),.status_flags(32'd0),.board_diagnostics(96'd0),.video_diagnostics(96'd0),.chain_diagnostics(288'd0),
  .session_active(context_valid),.current_session_id(session_id),.geometry_command_valid(command_valid),
  .geometry_command(command),.geometry_payload(payload),.geometry_code(code),.geometry_reply(reply),
  .env_valid(),.env_session_id(),.env_event_seq(),.env_mcu_time_us(),.env_board_time_us(),
  .env_lux_milli(),.env_angle_mdeg(),.env_measurement_valid(),.rx_good_count(),.rx_error_count(),.tx_overflow_count());
 raw8_geometry_core #(.WARMUP_FRAMES(0),.PREDECODE_VIEW_READ(1)) core(
  .mem_clk(clk),.mem_reset_n(rst_n),.cam_clk(1'b0),.cam_reset_n(1'b0),.pixel_clk(1'b0),.pixel_reset_n(1'b0),
  .configured(1'b0),.vsync(1'b0),.href(1'b0),.camera_data(8'd0),
  .commissioned(1'b1),.network_enable(1'b0),.epoch(64'd7),
  .src_mac(48'd0),.dst_mac(48'd0),.src_ip(32'd0),.dst_ip(32'd0),.src_port(16'd0),.dst_port(16'd0),
  .awaddr(awaddr),.araddr(araddr),.awlen(),.arlen(),.arid(),.awvalid(awvalid),.arvalid(arvalid),
  .awready(1'b0),.arready(1'b0),.wready(1'b0),.wlast(1'b0),.wid(4'd0),.rid(4'd0),
  .rvalid(1'b0),.rlast(1'b0),.rdata(256'd0),.wdata(),.wstrb(),.rgb(),.hs(),.vs(),.de(),
  .gmii_data(),.gmii_en(),.gmii_error(),.fault(),.published(),.underflows(),.fault_detail(),.writer_snapshot(),.chain_diagnostics(),
  .geo_cmd_valid(command_valid),.geo_cmd(command),.geo_payload(payload),.geo_code(code),.geo_reply(reply),
  .mcu_context_valid(context_valid),.mcu_session_id(session_id),.env_valid(1'b0),.env_measurement_valid(2'b0),
  .env_angle_mdeg(32'sd0),.env_event_seq(32'd0),.env_board_time_us(64'd0));

 integer fixture_generation=1,checks=0,responses=0,expected=0,cycle=0;
 integer last_payload_cycle=0,last_crc_cycle=0,min_setup=32'h7fffffff;
 integer read_accepts=0,fresh_reads=0,bank2_accepts=0,core_accepts=0,view_accepts=0;
 integer i,j;reg [255:0] request_payload,last,received[0:511];
 reg [95:0] wanted_reply[0:511],accepted_reply[0:511];
 reg [7:0] wanted_code[0:511],wanted_command[0:511];reg [511:0] accepted=0;
 reg [1427:0] fixture_snapshot;integer marker;
 wire [31:0] fixture_version=32'hc0000000+fixture_generation;
 wire [31:0] fixture_display_version=32'hd0000000+fixture_generation;
 wire [31:0] fixture_revision=32'ha0000000+fixture_generation;
 wire [31:0] fixture_packed=32'h00001002+(fixture_generation<<8);
 wire [63:0] fixture_id={32'h11220000+fixture_generation,32'h55660000+fixture_generation};
 wire [31:0] fixture_publication=32'h22000000+fixture_generation;
 wire [31:0] fixture_angle=-32'd12345-fixture_generation;
 wire [31:0] fixture_seq=32'h28000000+fixture_generation;
 wire [31:0] fixture_session=fixture_generation[0]?32'd3:32'd4;
 wire [63:0] fixture_time={32'h31000000+fixture_generation,32'h30000000+fixture_generation};
 wire [31:0] fixture_display_generation=32'h50000000+fixture_generation;
 // Purpose: twenty unique signed-looking coordinate pairs prevent wrong
 // marker, half-word, field or table-index aliases from passing by coincidence.
 always @* begin
  fixture_snapshot=0;
  for(marker=0;marker<20;marker=marker+1)begin
   fixture_snapshot[marker*64+:32]=32'h10000000+fixture_generation*256+marker*2;
   fixture_snapshot[marker*64+32+:32]=32'he0000000+fixture_generation*256+marker*2+1;
  end
  fixture_snapshot[1299:1280]=20'ha5a5a^fixture_generation;
  fixture_snapshot[1331:1300]=fixture_revision;fixture_snapshot[1363:1332]=fixture_packed;
  fixture_snapshot[1395:1364]=fixture_display_version;fixture_snapshot[1427:1396]=32'h60000000+fixture_generation;
 end
 task check(input bit ok,input string label_text);
  begin checks=checks+1;if(!ok)$fatal(1,"CORE_READ_UART_FAIL baud=%0d seq=%0d %s",BAUD,expected,label_text);end
 endtask
 function [15:0] crc_byte(input [15:0] prior,input [7:0] value);
  integer k;reg [15:0] c;begin c=prior;
   for(k=7;k>=0;k=k-1)if(c[15]^value[k])c=(c<<1)^16'h1021;else c=c<<1;
   crc_byte=c;end
 endfunction
 // Independent catalog oracle: constants are the current 1920x1080 marker
 // definitions, not another instance of the DUT's address/catalog decoder.
 function [55:0] catalog(input integer m);
  reg [15:0] x,y;reg [23:0] c;begin
   x=0;y=0;c=0;
   case(m)
    0:begin x=0;y=0;c=24'hff3864;end 1:begin x=1919;y=0;c=24'h00e5ff;end
    2:begin x=1919;y=1079;c=24'hffe600;end 3:begin x=0;y=1079;c=24'h58ff42;end
    4:begin x=960;y=0;c=24'hff52ef;end 5:begin x=1919;y=540;c=24'hff8b18;end
    6:begin x=960;y=1079;c=24'h7d9cff;end 7:begin x=0;y=540;c=24'h00ffb3;end
    8:begin x=960;y=540;c=24'hffffff;end 9:begin x=480;y=270;c=24'hff4040;end
    10:begin x=1439;y=809;c=24'h22dfff;end 11:begin x=1439;y=270;c=24'heeff00;end
    12:begin x=480;y=809;c=24'hff65ed;end 13:begin x=480;y=540;c=24'hffb000;end
    14:begin x=1439;y=540;c=24'h00ff74;end 15:begin x=960;y=270;c=24'hbf80ff;end
    16:begin x=960;y=809;c=24'hff734d;end 17:begin x=640;y=360;c=24'h00ffff;end
    18:begin x=1279;y=719;c=24'hdfff00;end 19:begin x=1279;y=360;c=24'hff70c8;end
   endcase
   catalog={y,x,c};
  end
 endfunction
 function [31:0] marker_word(input [31:0] idx,input integer g);
  integer m,f;reg [55:0] cat;reg [19:0] vis;
  begin
   marker_word=0;vis=20'ha5a5a^g;
   case(idx)
    0:marker_word=32'h4d4b5231;1:marker_word=32'ha0000000+g;
    2:marker_word=32'h1002+(g<<8);3:marker_word=32'hd0000000+g;
    4:marker_word={12'b0,vis};5:marker_word=32'h50000000+g;6:marker_word=32'h60000000+g;
    default:if(idx>=16 && idx<116)begin
     m=(idx-16)/5;f=(idx-16)%5;cat=catalog(m);
     case(f)
      0:marker_word=cat[55:24];1:marker_word=32'h10000000+g*256+m*2;
      2:marker_word=32'he0000000+g*256+m*2+1;
      3:marker_word={8'b0,cat[23:0]};4:marker_word={31'b0,vis[m]};
     endcase
    end
   endcase
  end
 endfunction
 function [31:0] core_word(input [31:0] idx,input integer g);
  begin case(idx)
   21:core_word=0;22:core_word=32'h22000000+g;23:core_word=32'hc0000000+g;
   24:core_word=32'h55660000+g;25:core_word=32'h11220000+g;26:core_word=g%2;
   27:core_word=-32'd12345-g;28:core_word=32'h28000000+g;29:core_word=g%2?3:4;
   30:core_word=32'h30000000+g;31:core_word=32'h31000000+g;32:core_word=7;33:core_word=0;
   default:core_word=0;
  endcase end
 endfunction
 task octet(input [7:0] value);integer k;begin
  rx=0;#(BIT_NS);for(k=0;k<8;k=k+1)begin rx=value[k];#(BIT_NS);end rx=1;#(BIT_NS);
 end endtask
 task send(input [7:0] op,input integer length);
  integer k;reg [15:0] crc;reg [7:0] value;begin
   wanted_command[expected]=op;octet(8'h55);octet(8'haa);crc=16'hffff;
   for(k=0;k<6+length;k=k+1)begin
    case(k)0:value=1;1:value=op;2:value=expected;3:value=expected>>8;4:value=length;5:value=0;
     default:value=request_payload[(k-6)*8+:8];endcase
    crc=crc_byte(crc,value);octet(value);
   end
   octet(crc[7:0]);octet(crc[15:8]);
  end
 endtask
 task await_reply;begin
  wait(responses>expected);last=received[expected];expected=expected+1;
 end endtask
 task read_word(input [31:0] idx,bank,input [7:0] expected_code);
  integer g;begin
   g=fixture_generation+1;request_payload=0;request_payload[63:0]=7;request_payload[95:64]=3;
   request_payload[127:96]=idx;request_payload[159:128]=bank;wanted_code[expected]=expected_code;
   if(bank==2)wanted_reply[expected]={32'hd0000000+g,marker_word(idx,g),idx};
   else if(bank==1 && idx>=21 && idx<=33)wanted_reply[expected]={32'hc0000000+g,core_word(idx,g),idx};
   else wanted_reply[expected]=0; // Invalid config fallback has reset version/id.
   send(8'h34,20);await_reply;
  end
 endtask
 task view_command(input [31:0] revision,flags,size,input [7:0] expected_code);
  integer g;begin
   g=fixture_generation+1;request_payload=0;request_payload[63:0]=7;request_payload[95:64]=3;
   request_payload[127:96]=revision;request_payload[159:128]=flags;request_payload[191:160]=size;
   wanted_code[expected]=expected_code;wanted_reply[expected]={32'h1002+(g<<8),32'ha0000000+g,revision};
   send(8'h35,24);await_reply;
  end
 endtask
 // Purpose: observe serial parsing only. Change the fixture by NBA exactly
 // when CRC1 is accepted: registered selectors already settled, but live data
 // changes just ONE edge before protocol.push. A data-predecode would be stale.
 always @(posedge clk)if(rst_n)begin
  cycle=cycle+1;
  if(uart.byte_valid && uart.u_parser.state==8 && uart.u_parser.received==uart.request_length-1)
   last_payload_cycle=cycle;
  if(uart.byte_valid && uart.u_parser.state==10 && (command==8'h34 || command==8'h35))begin
   fixture_generation<=fixture_generation+1;last_crc_cycle=cycle;
  end
  if(command_valid)begin
   check(command==8'h34 || command==8'h35,"only expected geometry opcodes");
   check(cycle-last_payload_cycle>=2,"payload committed before CRC/acceptance");
   if(cycle-last_payload_cycle<min_setup)min_setup=cycle-last_payload_cycle;
   check(cycle==last_crc_cycle+1,"unchanged one-edge parser-done to acceptance");
   check(code===wanted_code[uart.request_seq],"live core response code");
   check(reply===wanted_reply[uart.request_seq],$sformatf("fresh route reply index=%h got=%h expected=%h",payload[127:96],reply,wanted_reply[uart.request_seq]));
   accepted_reply[uart.request_seq]=reply;accepted[uart.request_seq]=1;fresh_reads=fresh_reads+1;
   if(command==8'h35)view_accepts=view_accepts+1;
   else begin
    read_accepts=read_accepts+1;
    if(payload[159:128]==2)bank2_accepts=bank2_accepts+1;
    if(payload[159:128]==1 && payload[127:96]>=21 && payload[127:96]<=33)core_accepts=core_accepts+1;
   end
   #0.001;check(uart.pending_geometry_data===accepted_reply[uart.request_seq],"protocol captures current reply on acceptance edge");
  end
 end
 // Independent pin-level TX decoder verifies framing, CRC, sequence, command,
 // epoch/session prefix and all 96 extension bits including NACK bank2 echoes.
 initial begin:monitor
  reg [7:0] value,crc_low,op;reg [15:0] seq,crc;reg [255:0] p;integer k,offset;
  offset=0;p=0;crc=16'hffff;seq=0;
  forever begin
   @(negedge tx);#(BIT_NS/2);check(tx===0,"TX start");
   for(k=0;k<8;k=k+1)begin #(BIT_NS);value[k]=tx;end
   #(BIT_NS);check(tx===1,"TX stop");
   case(offset)
    0:check(value==8'h55,"sync55");1:check(value==8'haa,"syncaa");
    2:begin check(value==1,"envelope version");crc=16'hffff;end
    3:op=value;4:seq[7:0]=value;5:seq[15:8]=value;
    6:check(value==32,"response length low");7:check(value==0,"response length high");
   endcase
   if(offset>=2 && offset<40)crc=crc_byte(crc,value);
   if(offset>=8 && offset<40)p[(offset-8)*8+:8]=value;
   if(offset==40)crc_low=value;
   if(offset==41)begin
    check({value,crc_low}==crc,"response CRC");check(seq==responses,"response sequence");
    check(p[7:0]==wanted_code[seq] && p[15:8]==wanted_command[seq],"response code/opcode");
    check(op==(wanted_code[seq]<2?8'h80:8'h81),"ACK/NACK envelope");
    check(p[95:32]==7 && p[127:96]==3,"epoch/session prefix");
    if(wanted_command[seq]==8'h34 || wanted_command[seq]==8'h35)begin
     check(accepted[seq],"reply belongs to admitted geometry request");
     check(p[255:160]===wanted_reply[seq] && p[255:160]===accepted_reply[seq],"wire current data/version/full index");
    end
    received[responses]=p;responses=responses+1;offset=0;
   end else offset=offset+1;
  end
 end
 initial begin
  repeat(6)@(negedge clk);rst_n=1;repeat(6)@(negedge clk);
  // Force only static producer state. Keep the actual PREDECODE_VIEW_READ=1
  // core, snapshot address decoder, config fallback and 0x35 reply mux live.
  force core.process_state=3'd0;force core.geo_start=1'b0;
  force core.result_commit=1'b0;force core.result_hdmi_grant=1'b0;
  force core.result_pool_fault=1'b0;force core.write_arb_fault=1'b0;force core.geo_fault=1'b0;
  force core.arb_fault=1'b0;force core.write_fault=1'b0;force core.net_fault=1'b0;
  force core.overflow_fault=1'b0;force core.pool_fault=1'b0;
  force core.result_published=fixture_publication;force core.completed_version=fixture_version;
  force core.completed_id=fixture_id;force core.completed_epoch=64'd7;
  force core.completed_angle_valid=1'b1;force core.completed_angle=fixture_angle;
  force core.completed_angle_seq=fixture_seq;force core.completed_angle_session=fixture_session;
  force core.completed_angle_time=fixture_time;
  force core.u_view_snapshot.snapshot=fixture_snapshot;
  force core.u_view_snapshot.applied_revision=fixture_revision;
  force core.u_view_snapshot.applied_packed=fixture_packed;
  force core.u_view_snapshot.applied_version=fixture_display_version;
  force core.u_view_snapshot.generation=fixture_display_generation;
  request_payload=0;request_payload[63:0]=7;request_payload[95:64]=3;wanted_code[expected]=0;
  send(8'h02,12);await_reply;check(context_valid && session_id==3,"real OPEN session");
  if(!SMOKE)begin
   for(i=0;i<=6;i=i+1)read_word(i,2,0);
   for(i=16;i<116;i=i+1)read_word(i,2,0);
   for(i=21;i<=33;i=i+1)read_word(i,1,0);
   // Force both truth values of the live posture/session validity predicate.
   read_word(26,1,0);read_word(26,1,0);
   read_word(7,2,11);read_word(15,2,11);read_word(116,2,11);read_word(32'hffffffff,2,11);
   read_word(32'h80000000,2,11);read_word(32'h80000011,2,11);read_word(32'h00000091,2,11);
   read_word(32'h00000055,1,11);read_word(32'h80000015,1,11);read_word(32'h80000021,1,11);
   read_word(34,1,11);read_word(21,32'h80000001,11);read_word(17,32'h80000002,11);
   view_command(1,3,10,0);read_word(17,2,0);
   view_command(2,2,12,0);view_command(2,2,12,1);view_command(2,3,12,10);
  end else begin
   // Production 115200 baud smoke keeps real 125MHz UART timing and checks
   // all three routing families plus high-bit rejection without full video.
   read_word(0,2,0);read_word(17,2,0);read_word(113,2,0);
   read_word(24,1,0);read_word(33,1,0);read_word(32'h80000011,2,11);
   read_word(32'h80000015,1,11);view_command(1,3,10,0);
  end
  check(bank2_accepts>0 && core_accepts>0 && view_accepts>0 && fresh_reads==expected-1,"all route/freshness coverage");
  check(uart.tx_overflow_count==0,"no dropped replies");
  $display("CORE_READ_UART_PASS clk=%0d baud=%0d smoke=%0d checks=%0d responses=%0d reads=%0d bank2=%0d core=%0d view=%0d fresh=%0d min_payload_setup_edges=%0d control_only=1",CLK_HZ,BAUD,SMOKE,checks,responses,read_accepts,bank2_accepts,core_accepts,view_accepts,fresh_reads,min_setup);
  $finish;
 end
 initial begin #1500000000;$fatal(1,"CORE_READ_UART_TIMEOUT responses=%0d",responses);end
endmodule
