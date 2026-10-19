`timescale 1ns/1ps
// Purpose: drive identical real UART traffic into original and local-capture
// candidate; compare every public output after each clock in four-state logic.
module pc_tb;
 reg clk=0,rst=0,rx=1;always #4 clk=~clk;
 reg [767:0] status=0,geometry_status=0,s1=0,result_status=0,snap_geometry=0;
 reg mode_ready=1,geometry_ready=1,snapshot_ready=1,mutate_busy=0;
 wire [1:0] tx,configured,mode_valid,geometry_valid,snapshot_arm;
 wire [63:0] epoch[0:1];wire [47:0] local_mac[0:1],peer_mac[0:1];
 wire [31:0] local_ip[0:1],peer_ip[0:1];wire [15:0] local_port[0:1],peer_port[0:1];
 wire [1:0] mode[0:1];wire [31:0] mode_version[0:1],geometry_version[0:1],geometry_id[0:1];
 wire [543:0] geometry_entity[0:1];wire [902:0] public0,public1;
 pc_video_boot #(.BAUD(12500000)) dut0(.clk(clk),.rst_n(rst),.uart_rx(rx),.uart_tx(tx[0]),.configured(configured[0]),
  .epoch(epoch[0]),.local_mac(local_mac[0]),.peer_mac(peer_mac[0]),.local_ip(local_ip[0]),.peer_ip(peer_ip[0]),.local_port(local_port[0]),.peer_port(peer_port[0]),
  .control_status(status),.mode_submit_valid(mode_valid[0]),.mode_submit_ready(mode_ready),.mode_submit(mode[0]),.mode_version(mode_version[0]),
  .geometry_status(geometry_status),.snapshot_s1_status(s1),.snapshot_result_status(result_status),.snapshot_geometry_status(snap_geometry),
  .geometry_submit_valid(geometry_valid[0]),.geometry_submit_ready(geometry_ready),.geometry_submit(geometry_entity[0]),.geometry_version(geometry_version[0]),.geometry_entity_id(geometry_id[0]),
  .snapshot_arm(snapshot_arm[0]),.snapshot_arm_ready(snapshot_ready));
 pc_video_boot_local_capture_candidate #(.BAUD(12500000)) dut1(.clk(clk),.rst_n(rst),.uart_rx(rx),.uart_tx(tx[1]),.configured(configured[1]),
  .epoch(epoch[1]),.local_mac(local_mac[1]),.peer_mac(peer_mac[1]),.local_ip(local_ip[1]),.peer_ip(peer_ip[1]),.local_port(local_port[1]),.peer_port(peer_port[1]),
  .control_status(status),.mode_submit_valid(mode_valid[1]),.mode_submit_ready(mode_ready),.mode_submit(mode[1]),.mode_version(mode_version[1]),
  .geometry_status(geometry_status),.snapshot_s1_status(s1),.snapshot_result_status(result_status),.snapshot_geometry_status(snap_geometry),
  .geometry_submit_valid(geometry_valid[1]),.geometry_submit_ready(geometry_ready),.geometry_submit(geometry_entity[1]),.geometry_version(geometry_version[1]),.geometry_entity_id(geometry_id[1]),
  .snapshot_arm(snapshot_arm[1]),.snapshot_arm_ready(snapshot_ready));
 assign public0={tx[0],configured[0],epoch[0],local_mac[0],peer_mac[0],local_ip[0],peer_ip[0],local_port[0],peer_port[0],mode_valid[0],mode[0],mode_version[0],geometry_valid[0],geometry_entity[0],geometry_version[0],geometry_id[0],snapshot_arm[0]};
 assign public1={tx[1],configured[1],epoch[1],local_mac[1],peer_mac[1],local_ip[1],peer_ip[1],local_port[1],peer_port[1],mode_valid[1],mode[1],mode_version[1],geometry_valid[1],geometry_entity[1],geometry_version[1],geometry_id[1],snapshot_arm[1]};
 wire byte_valid;wire [7:0] byte_data;
 uart_8n1 #(.BAUD(12500000)) decode(.clk(clk),.rst_n(rst),.rx(tx[0]),.tx(),.rx_valid(byte_valid),.rx_data(byte_data),.framing_error(),.tx_valid(1'b0),.tx_ready(),.tx_data(8'd0));
 integer cycles=0,rx_bytes=0,total_replies=0,captures=0,busy_cycles=0,resets=0;
 integer modes=0,geometries=0,snapshots=0,seq_no=0;
 reg [7:0] response[0:8191];reg [1535:0] frozen=0;reg [7:0] frozen_op=0;
 // No masks, forced values, or two-state comparison: invalid public payloads
 // are also checked, and any unknown/Z on either public interface is fatal.
 always @(posedge clk)begin
  if(!rst)rx_bytes=0;
  else begin
   if(byte_valid)begin response[rx_bytes]=byte_data;rx_bytes=rx_bytes+1;end
   if(mode_valid[0] && mode_ready)begin
    if(mode[0]!=1 || mode_version[0]!=2)$fatal(1,"Wrong mode submission");modes=modes+1;
   end
   if(geometry_valid[0] && geometry_ready)begin
    if(geometry_version[0]!=2 || geometry_id[0]!=7 || geometry_entity[0][320+:32]!=65536000)$fatal(1,"Wrong geometry submission");geometries=geometries+1;
   end
   if(snapshot_arm[0] && snapshot_ready)snapshots=snapshots+1;
   if(dut0.state==2 && dut0.received[7:0]==0 && (dut0.operation==8'h90 || dut0.operation==8'h95 || dut0.operation==8'h96 || dut0.operation==8'h97))begin
    frozen=dut0.operation==8'h96 ? {result_status,s1}:{768'd0,(dut0.operation==8'h95 ? geometry_status:(dut0.operation==8'h97 ? snap_geometry:status))};
    frozen_op=dut0.operation;captures=captures+1;
   end
   if(dut0.tx_active && !dut0.uart_ready)busy_cycles=busy_cycles+1;
  end
  #1;cycles=cycles+1;
  if((^public0)===1'bx || (^public1)===1'bx)$fatal(1,"Public X/Z cycle=%0d rst=%0b states=%0d/%0d",cycles,rst,dut0.state,dut1.state);
  if(dut0.status_snapshot!==dut1.status_snapshot)$fatal(1,"Snapshot capture edge/data differs");
  if(public0!==public1)$fatal(1,"Public difference cycle=%0d states=%0d/%0d",cycles,dut0.state,dut1.state);
 end
 // Backend values deliberately change while UART holds reply bytes. The
 // expected readback is captured independently on the actual CHECK edge.
 always @(negedge clk)if(rst && mutate_busy && (dut0.state==6 || dut0.state==4))begin
  status=~status;geometry_status=~geometry_status;s1=~s1;result_status=~result_status;snap_geometry=~snap_geometry;
  status[320+:32]=1;geometry_status[576+:32]=1;
 end
 function [15:0] crc_byte(input [15:0] c,input [7:0] b);
  reg [15:0] v;integer k;begin v=c^{b,8'd0};for(k=0;k<8;k=k+1)v=(v<<1)^(v[15]?16'h1021:0);crc_byte=v;end
 endfunction
 function [31:0] crc32_byte(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer k;begin v=c^b;for(k=0;k<8;k=k+1)v=(v>>1)^(v[0]?32'hedb88320:0);crc32_byte=v;end
 endfunction
 task send_byte(input [7:0] b);
  integer k;begin @(negedge clk);rx=0;repeat(10)@(negedge clk);for(k=0;k<8;k=k+1)begin rx=b[k];repeat(10)@(negedge clk);end rx=1;repeat(12)@(negedge clk);end
 endtask
 // Request seq_no and CRC are real wire fields; parser/internal data are
 // never forced. Natural UART tx_ready creates roughly 100-cycle stalls.
 task send_packet(input [7:0] cmd,input integer length,input [639:0] payload);
  reg [15:0] crc;reg [7:0] b;integer i;begin
   seq_no=seq_no+1;send_byte(8'h55);send_byte(8'haa);crc=16'hffff;
   for(i=0;i<length+6;i=i+1)begin
    case(i)0:b=1;1:b=cmd;2:b=seq_no;3:b=seq_no>>8;4:b=length;5:b=length>>8;default:b=payload[(i-6)*8+:8];endcase
    crc=crc_byte(crc,b);send_byte(b);
   end
   send_byte(crc[7:0]);send_byte(crc[15:8]);
  end
 endtask
 task transact(input [7:0] cmd,input integer length,input [639:0] payload,input [7:0] expect_code,input integer page_check);
  integer base,i;reg [15:0] crc;begin
   base=rx_bytes;send_packet(cmd,length,payload);wait(rx_bytes==base+42);wait(dut0.state==5 || dut0.state==0);repeat(4)@(negedge clk);
   if(response[base+8]!==expect_code || response[base+3]!== (expect_code==0 ? 8'h80:8'h81) || response[base+9]!==cmd)$fatal(1,"Reply differs cmd=%h code=%0d expected=%0d",cmd,response[base+8],expect_code);
   crc=16'hffff;for(i=2;i<40;i=i+1)crc=crc_byte(crc,response[base+i]);
   if({response[base+41],response[base+40]}!==crc)$fatal(1,"Reply CRC");
   if(page_check>=0)begin
    if(frozen_op!==cmd || response[base+10]!==page_check || response[base+11]!==24)$fatal(1,"Page metadata");
    for(i=0;i<24;i=i+1)if(response[base+12+i]!==frozen[page_check*192+i*8+:8])$fatal(1,"Frozen status differs cmd=%h page=%0d byte=%0d",cmd,page_check,i);
   end
   total_replies=total_replies+1;
  end
 endtask
 reg [639:0] boot,payload,geometry_payload;reg [31:0] entity_crc;integer i,op,page;
 // Reset drives only the real reset/RX inputs. Both implementations must
 // clear all snapshot pages; fresh boot reestablishes nonzero-page ownership.
 task reset_board;
  begin @(negedge clk);rst=0;rx=1;resets=resets+1;repeat(8)@(negedge clk);rst=1;repeat(20)@(negedge clk);end
 endtask
 task boot_board;
  begin transact(8'h71,32,boot,0,-1);if(!configured[0])$fatal(1,"Boot not configured");end
 endtask
 task cold_reject;
  begin transact(8'h90,1,640'd1,11,-1);transact(8'h95,1,640'd1,11,-1);transact(8'h96,1,640'd7,11,-1);transact(8'h97,1,640'd3,11,-1);end
 endtask
 initial begin
  for(i=0;i<96;i=i+1)begin status[i*8+:8]=i*3+7;geometry_status[i*8+:8]=i*7+3;s1[i*8+:8]=i*3+1;result_status[i*8+:8]=i*5+7;snap_geometry[i*8+:8]=i*11+9;end
  status[320+:32]=1;geometry_status[576+:32]=1;
  boot=0;boot[0+:64]=99;boot[64+:48]=48'h010000000002;boot[112+:48]=48'h020000000002;boot[160+:32]=32'h0350a8c0;boot[192+:32]=32'h0250a8c0;boot[224+:16]=50001;boot[240+:16]=50000;
  repeat(10)@(negedge clk);
  if(dut1.status_snapshot!==1536'd0)$fatal(1,"Candidate payload reset differs");
  rst=1;resets=resets+1;repeat(20)@(negedge clk);boot_board();cold_reject();
  mutate_busy=1;
  for(op=0;op<4;op=op+1)begin
   case(op)0:payload=8'h90;1:payload=8'h95;2:payload=8'h96;3:payload=8'h97;endcase
   // Capture each operation and exhaust all legal pages while inputs change.
   for(page=0;page<(op==2?8:4);page=page+1)transact(payload[7:0],1,page,0,page);
   transact(payload[7:0],1,op==2?640'd8:640'd4,11,-1);
   case(op)0:transact(8'h95,1,640'd1,11,-1);1:transact(8'h96,1,640'd1,11,-1);2:transact(8'h97,1,640'd1,11,-1);3:transact(8'h90,1,640'd1,11,-1);endcase
  end
  mutate_busy=0;
  payload=0;payload[7:0]=1;payload[47:16]=2;transact(8'h92,6,payload,0,-1);
  mode_ready=0;payload[47:16]=3;transact(8'h92,6,payload,4,-1);
  mode_ready=1;payload[7:0]=3;transact(8'h92,6,payload,11,-1);
  geometry_payload=0;geometry_payload[31:0]=2;geometry_payload[63:32]=7;geometry_payload[64+:32]=67109;geometry_payload[192+:32]=67109;
  geometry_payload[384+:32]=65536000;geometry_payload[416+:32]=65536000;geometry_payload[576+:32]=32'h04000000;
  entity_crc=32'hffffffff;for(i=0;i<76;i=i+1)entity_crc=crc32_byte(entity_crc,geometry_payload[i*8+:8]);geometry_payload[639:608]=~entity_crc;
  transact(8'h94,80,geometry_payload,0,-1);
  geometry_payload[608]=!geometry_payload[608];transact(8'h94,80,geometry_payload,11,-1);geometry_payload[608]=!geometry_payload[608];
  payload=geometry_payload;payload[384+:32]=0;entity_crc=32'hffffffff;for(i=0;i<76;i=i+1)entity_crc=crc32_byte(entity_crc,payload[i*8+:8]);payload[639:608]=~entity_crc;
  transact(8'h94,80,payload,11,-1);
  transact(8'h93,1,640'd0,0,-1);snapshot_ready=0;transact(8'h93,1,640'd0,4,-1);snapshot_ready=1;
  if(modes!=1 || geometries!=1 || snapshots!=1)$fatal(1,"Submission counts");
  // Abort in SEND/TRANSMIT after status capture, then prove reset invalidates
  // all page ownership even though candidate payload retains earlier data.
  send_packet(8'h96,1,640'd0);wait(dut0.state==6 && !dut0.uart_ready);repeat(200)@(negedge clk);reset_board();boot_board();cold_reject();
  // Abort during synchronous 80-byte COLLECT before CHECK/guard/submit.
  send_packet(8'h94,80,geometry_payload);wait(dut0.state==1);repeat(10)@(negedge clk);if(dut0.state!=1)$fatal(1,"Collection reset coverage missed");reset_board();boot_board();cold_reject();
  transact(8'h97,1,640'd0,0,0);transact(8'h97,1,640'd3,0,3);
  if((^dut1.status_snapshot)===1'bx)$fatal(1,"Full capture left unknown data");
  $display("PC_CAPTURE_DIFF_PASS cycles=%0d public_bits=903 replies=%0d captures=%0d busy_cycles=%0d resets=%0d mode=%0d geometry=%0d snapshot=%0d",cycles,total_replies,captures,busy_cycles,resets,modes,geometries,snapshots);$finish;
 end
 initial begin #20000000;$fatal(1,"PC payload diff timeout states=%0d/%0d bytes=%0d seq=%0d",dut0.state,dut1.state,rx_bytes,seq_no);end
endmodule
