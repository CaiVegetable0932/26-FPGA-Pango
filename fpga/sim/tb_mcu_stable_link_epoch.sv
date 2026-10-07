`timescale 1ns/1ps
// Purpose: UART-pin stable-epoch equivalence under the ACTUAL immutable boot gateway.
// Reset is the board's mem_reset_n && commissioned. No force/byte injection is used.
module tb_mcu_stable_link_epoch;
 parameter integer CLK_HZ=1843200,BAUD=115200,FULL=1;
 localparam real CLK_NS=1.0e9/CLK_HZ,BIT_NS=1.0e9/BAUD;
 reg clk=0,reset_n=0,rx=1;always #(CLK_NS/2)clk=~clk;
 wire configured;wire [63:0] epoch;wire [47:0] smac,dmac;wire [31:0] sip,dip;wire [15:0] sport,dport;
 wire mcu_reset_n=reset_n && configured;wire tx;
 reg [63:0] board_time=64'h100000000;
 always @(posedge clk)board_time<=board_time+1;

 wire c_tx,g_tx,c_session,g_session,c_env,g_env,c_geom,g_geom;
 wire [31:0] c_sid,g_sid,c_esid,g_esid,c_event,g_event,c_mt,g_mt,c_lux,g_lux,c_angle,g_angle;
 wire [63:0] c_bt,g_bt;wire [1:0] c_mv,g_mv;
 wire [31:0] c_good,g_good,c_error,g_error,c_drop,g_drop;
 wire [7:0] c_cmd,g_cmd;wire [255:0] c_payload,g_payload;

 comms_boot_config #(.CLK_HZ(CLK_HZ),.BAUD(BAUD),.BOOT_COMMAND(8'h71),.BOOT_MARKER(32'h38574152)) boot(
 .clk(clk),.reset_n(reset_n),.uart_rx(rx),.mcu_tx(c_tx),.uart_tx(tx),.configured(configured),.epoch(epoch),
 .src_mac(smac),.dst_mac(dmac),.src_ip(sip),.dst_ip(dip),.src_port(sport),.dst_port(dport));
mcu_protocol #(.CLK_HZ(CLK_HZ),.BAUD(BAUD),.RX_TIMEOUT_MS(FULL?2:20),
 .BOARD_DIAGNOSTICS(1),.VIDEO_DIAGNOSTICS(1),.CHAIN_DIAGNOSTICS(1),.GEOMETRY_CONTROL(1),.DISPLAY_CONTROL(1),.STABLE_LINK_EPOCH(1)) c(
 .clk(clk),.rst_n(mcu_reset_n),.uart_rx(rx),.uart_tx(c_tx),.link_epoch(epoch),.link_epoch_valid(configured),
 .board_time_us(board_time),.status_flags(32'hcafe1234),.board_diagnostics(96'h010203040506070809aabbcc),
 .video_diagnostics(96'h112233445566778899aabbcc),.chain_diagnostics(288'h123456789abcdef00112233445566778899aabbccddeeff0123456789abcdef01234567890),
 .session_active(c_session),.current_session_id(c_sid),.geometry_command_valid(c_geom),
 .geometry_command(c_cmd),.geometry_payload(c_payload),.geometry_code(8'd0),.geometry_reply({32'h76543210,board_time}),
 .env_valid(c_env),.env_session_id(c_esid),.env_event_seq(c_event),.env_mcu_time_us(c_mt),.env_board_time_us(c_bt),
 .env_lux_milli(c_lux),.env_angle_mdeg(c_angle),.env_measurement_valid(c_mv),
 .rx_good_count(c_good),.rx_error_count(c_error),.tx_overflow_count(c_drop));
mcu_protocol_golden #(.CLK_HZ(CLK_HZ),.BAUD(BAUD),.RX_TIMEOUT_MS(FULL?2:20),
 .BOARD_DIAGNOSTICS(1),.VIDEO_DIAGNOSTICS(1),.CHAIN_DIAGNOSTICS(1),.GEOMETRY_CONTROL(1),.DISPLAY_CONTROL(1)) g(
 .clk(clk),.rst_n(mcu_reset_n),.uart_rx(rx),.uart_tx(g_tx),.link_epoch(epoch),.link_epoch_valid(configured),
 .board_time_us(board_time),.status_flags(32'hcafe1234),.board_diagnostics(96'h010203040506070809aabbcc),
 .video_diagnostics(96'h112233445566778899aabbcc),.chain_diagnostics(288'h123456789abcdef00112233445566778899aabbccddeeff0123456789abcdef01234567890),
 .session_active(g_session),.current_session_id(g_sid),.geometry_command_valid(g_geom),
 .geometry_command(g_cmd),.geometry_payload(g_payload),.geometry_code(8'd0),.geometry_reply({32'h76543210,board_time}),
 .env_valid(g_env),.env_session_id(g_esid),.env_event_seq(g_event),.env_mcu_time_us(g_mt),.env_board_time_us(g_bt),
 .env_lux_milli(g_lux),.env_angle_mdeg(g_angle),.env_measurement_valid(g_mv),
 .rx_good_count(g_good),.rx_error_count(g_error),.tx_overflow_count(g_drop));

 integer cycles=0,checks=0,releases=0,pushes=0,pops=0,environments=0,geometry=0;
 integer reset_pending=0,reset_uart=0,reset_guard=0,single_bits=0,max_queue=0,reset_generation=0,guard_noise=0,invalid_boot=0;
 reg prior_running=0,prior_configured=0;reg [63:0] prior_epoch=0;
 always @(negedge reset_n)reset_generation=reset_generation+1;
 task check(input bit ok,input string label_text);
 begin checks=checks+1;if(!ok)$fatal(1,"MCU_STABLE_EPOCH_FAIL %s cycle=%0d",label_text,cycles);end endtask
 // Observe BEFORE first release edge: mismatch must flush all admissions once.
 always @(posedge clk)begin
  if(mcu_reset_n && !prior_running)begin
   check(configured && epoch!=0 && prior_epoch===epoch,"valid epoch settled before release");
   check(c.epoch_change===1'b1 && g.epoch_change===1'b1,"first release valid mismatch flush");
   check(!c.push && !c.pop && !g.push && !g.pop && !c_session && !g_session,"first release inhibits admission");
   releases=releases+1;
  end
  prior_running=mcu_reset_n;
  #1;cycles=cycles+1;
  if(reset_n && prior_configured)check(configured && epoch===prior_epoch,"immutable RUN epoch until reset");
  prior_configured=configured;prior_epoch=epoch;
  check({c_tx,c_session,c_sid,c_env,c_esid,c_event,c_mt,c_bt,c_lux,c_angle,c_mv,c_geom,c_cmd,c_payload,c_good,c_error,c_drop}==={g_tx,g_session,g_sid,g_env,g_esid,g_event,g_mt,g_bt,g_lux,g_angle,g_mv,g_geom,g_cmd,g_payload,g_good,g_error,g_drop},"visible cycle equality");
  if(mcu_reset_n)check({c.epoch_change,c.push,c.pop,c.queue_count,c.pending_reply,c.pending_payload,c.pending_seq,c.pending_command,c.pending_geometry,c.pending_geometry_data,c.u_reply_queue.front,c.observed_epoch,c.observed_epoch_valid,c.epoch_nonzero}==={g.epoch_change,g.push,g.pop,g.queue_count,g.pending_reply,g.pending_payload,g.pending_seq,g.pending_command,g.pending_geometry,g.pending_geometry_data,g.u_reply_queue.front,g.observed_epoch,g.observed_epoch_valid,g.epoch_nonzero},"internal cycle equality");
  else begin
   check(!c.rst_n && !g.rst_n,"both MCU held reset while configuring");
   check(c.queue_count==0 && g.queue_count==0 && !c.pending_reply && !g.pending_reply && !c_session && !g_session,"reset clears queue/session");
  end
  if(c.queue_count>max_queue)max_queue=c.queue_count;
  if(mcu_reset_n && c.push)pushes=pushes+1;
  if(mcu_reset_n && c.pop)pops=pops+1;
  if(c_env)environments=environments+1;
  if(c_geom)geometry=geometry+1;
 end
 function automatic [15:0] crc(input [15:0] prior,input [7:0] value);
 reg [15:0] v;integer b;begin v=prior;for(b=7;b>=0;b=b-1)begin
 if(v[15]^value[b])v=(v<<1)^16'h1021;else v=v<<1;end crc=v;end endfunction
 task octet(input [7:0] value);
 integer b;begin rx=0;#(BIT_NS);for(b=0;b<8;b=b+1)begin rx=value[b];#(BIT_NS);end rx=1;#(BIT_NS);end endtask
 task request(input [7:0] cmd,input [15:0] seq,input integer len,input [255:0] p,input bit bad_crc);
 integer i;reg [7:0] b;reg [15:0] v;
 begin octet(8'h55);octet(8'haa);v=16'hffff;
 for(i=0;i<6+len;i=i+1)begin
 case(i)0:b=1;1:b=cmd;2:b=seq[7:0];3:b=seq[15:8];4:b=len;5:b=0;default:b=p[(i-6)*8+:8];endcase
 v=crc(v,b);octet(b);end
 octet(v[7:0]^(bad_crc?8'd1:8'd0));octet(v[15:8]);end endtask
 // Independent physical TX decoder. Reset aborts partial frames explicitly.
 integer responses=0;reg [255:0] last_reply;reg [15:0] last_seq;
 initial begin:monitor
 integer b,index,gen,index_gen,i;reg [7:0] value,packet[0:41];reg [15:0] v;reg [255:0] p;
 index=0;index_gen=-1;
 forever begin
  @(negedge tx);
  begin:read_byte
   gen=reset_generation;if(index_gen!=gen)begin index=0;index_gen=gen;end
   #(BIT_NS/2);if(!reset_n || gen!=reset_generation)disable read_byte;
   check(tx===0,"UART start bit");
   for(b=0;b<8;b=b+1)begin #(BIT_NS);if(!reset_n || gen!=reset_generation)disable read_byte;value[b]=tx;end
   #(BIT_NS);if(!reset_n || gen!=reset_generation)disable read_byte;check(tx===1,"UART stop bit");
   packet[index]=value;
   if(index==41)begin
    check(packet[0]==8'h55 && packet[1]==8'haa && packet[2]==1 && packet[6]==32 && packet[7]==0,"reply envelope");
    v=16'hffff;for(i=2;i<40;i=i+1)v=crc(v,packet[i]);check({packet[41],packet[40]}==v,"reply CRC");
    for(i=0;i<32;i=i+1)p[i*8+:8]=packet[i+8];
    last_reply=p;last_seq={packet[5],packet[4]};responses=responses+1;index=0;
   end else index=index+1;
  end
 end end
 integer next_seq=1;
 task transact(input [7:0] cmd,input integer len,input [255:0] p,input [7:0] code,input bit bad);
 integer target;begin target=responses+1;request(cmd,next_seq,len,p,bad);wait(responses==target);
 check(last_seq==next_seq && last_reply[7:0]==code && last_reply[15:8]==cmd,"reply code/sequence/command");
 // Boot owns UART for its complete 24-bit guard after an ACK/NACK.
 // Ordinary post-commission requests only need the final stop-bit margin.
 next_seq=next_seq+1;
 if(!configured)wait(boot.state==0);else #(BIT_NS*12);
 end endtask
 function automatic [255:0] config_payload(input [63:0] e);
 begin config_payload={16'd50000,16'd50001,32'h6401a8c0,32'h3201a8c0,48'h020000000002,48'h010000000002,e};end endfunction
 function automatic [255:0] session_payload(input [63:0] e,input [31:0] sid);
 begin session_payload=0;session_payload[63:0]=e;session_payload[95:64]=sid;end endfunction
 task commission(input [63:0] e,input bit early);
 integer target;begin
 target=responses+1;request(8'h71,next_seq,32,config_payload(e),0);next_seq=next_seq+1;
 wait(boot.state==3);
 if(early)begin
  request(8'h01,16'hff01,0,0,0);guard_noise=guard_noise+1;
  // A released receiver can see a partial early byte: respect its REAL
  // framing-error quarantine/idle timeout rather than bypassing parser state.
  rx=1;#(FULL?3000000:21000000);
 end
 wait(configured);wait(responses>=target);repeat(16)@(negedge clk);
 check(epoch===e && c_good==0 && !c_session && c.queue_count==0,"commissioning/early command did not admit");
 end endtask
 reg [255:0] p,q;reg [63:0] e;integer i,j,epochs;integer before_env;
 initial begin
 repeat(8)@(negedge clk);reset_n=1;
 // Incoming CAPS before commissioning stays in boot domain; zero epoch rejected.
 transact(8'h01,0,0,6,0);invalid_boot=invalid_boot+1;
 transact(8'h71,32,config_payload(0),11,0);invalid_boot=invalid_boot+1;wait(boot.state==0);
 if(FULL)begin
  transact(8'h70,32,config_payload(1),6,0);invalid_boot=invalid_boot+1;wait(boot.state==0);
  transact(8'h71,31,config_payload(1),3,0);invalid_boot=invalid_boot+1;wait(boot.state==0);
  transact(8'h71,32,config_payload(1),2,1);invalid_boot=invalid_boot+1;wait(boot.state==0);
  p=config_payload(1);p[64]=1;transact(8'h71,32,p,11,0);invalid_boot=invalid_boot+1;wait(boot.state==0);
  p=config_payload(1);p[239:224]=0;transact(8'h71,32,p,11,0);invalid_boot=invalid_boot+1;wait(boot.state==0);
 end
 // Abort an accepted boot at the end of its real guard before MCU release.
 if(FULL)begin
  request(8'h71,next_seq,32,config_payload(64'h123456789abcdef1),0);next_seq=next_seq+1;
  wait(boot.state==3 && boot.guard_count>=(CLK_HZ/BAUD)*23);
  check(!configured && !mcu_reset_n,"GUARD abort before release");
  reset_n=0;reset_guard=reset_guard+1;rx=1;repeat(16)@(negedge clk);reset_n=1;
 end
 epochs=FULL?4:2;
 for(i=0;i<epochs;i=i+1)begin
  case(i)0:e=64'h8000000000000001;1:e=64'hffffffffffffffff;2:e=64'h0001000000000001;default:e=64'h7fffffffffffffff;endcase
  commission(e,i==0);
  transact(8'h01,0,0,0,0);p=session_payload(e,17+i);transact(8'h02,12,p,0,0);
  check(c_session && c_sid==17+i,"OPEN admitted");transact(8'h03,12,p,0,0);
  q=p;q[127:96]=1;q[159:128]=32'h80000001;q[191:160]=12345;q[223:192]=-123456;q[225:224]=3;
  before_env=environments;transact(8'h10,32,q,0,0);check(environments==before_env+1 && c_mv==3 && c_event==1,"environment accepted once");
  transact(8'h33,12,p,0,0);
  if(FULL && i==0)begin
   transact(8'h02,12,p,1,0);transact(8'h10,32,q,1,0);
   q[191:160]=12346;transact(8'h10,32,q,10,0);
   q=p;q[63:0]=e^64'h4000000000000000;transact(8'h03,12,q,7,0);
   for(j=4;j<=9;j=j+1)transact(j,12,p,0,0);
   transact(8'h30,24,p,0,0);transact(8'h31,24,p,0,0);transact(8'h32,16,p,0,0);
   transact(8'h34,20,p,0,0);transact(8'h35,24,p,0,0);
   // Ten-byte requests arrive faster than 42-byte replies: exercise real queue pressure.
   for(j=0;j<22;j=j+1)begin request(8'h01,next_seq,0,0,0);next_seq=next_seq+1;end
   wait(c.queue_count==0 && !c.pending_reply && !c.u_tx.active);#(BIT_NS*15);
   check(c_drop>0 && max_queue>=7,"queue overload reached");
  end
  if(i<epochs-1)begin
   if(FULL && i==1)begin
    // Interrupt a real serialized reply, including abort of the host decoder.
    request(8'h01,next_seq,0,0,0);wait(c.u_tx.active && c_tx==0);
    #(BIT_NS/3);check(g.u_tx.active,"both UARTs active at reset");
    reset_uart=reset_uart+1;reset_n=0;
   end else begin
    // Reset while a genuine UART request has reserved its pending reply.
    fork
     request(8'h01,next_seq,0,0,0);
     begin wait(c.pending_reply);#1;check(g.pending_reply,"matching pending at reset");reset_pending=reset_pending+1;reset_n=0;end
    join
   end
   rx=1;repeat(16)@(negedge clk);reset_n=1;next_seq=next_seq+1;
  end
 end
 // Actual accepted boot producer for every bit, including bit63. The reset
 // and first-release assertions above run on each recommissioned identity.
 if(FULL)for(j=0;j<64;j=j+1)begin
  reset_n=0;rx=1;repeat(16)@(negedge clk);reset_n=1;
  commission(64'd1<<j,0);transact(8'h01,0,0,0,0);single_bits=single_bits+1;
 end
 check(releases==epochs+single_bits && reset_pending+reset_uart==epochs-1 && guard_noise==1 && environments>=epochs && geometry>=epochs,"required bounded coverage");
 if(FULL)check(single_bits==64 && reset_guard==1 && reset_uart==1,"full boot/reset coverage");
 $display("MCU_STABLE_EPOCH_PASS clk=%0d full=%0d cycles=%0d checks=%0d releases=%0d invalid_boot=%0d guard_noise=%0d reset_pending=%0d reset_uart=%0d reset_guard=%0d single_bits=%0d replies=%0d pushes=%0d pops=%0d env=%0d geometry=%0d max_queue=%0d",
 CLK_HZ,FULL,cycles,checks,releases,invalid_boot,guard_noise,reset_pending,reset_uart,reset_guard,single_bits,responses,pushes,pops,environments,geometry,max_queue);$finish;
 end
 // Real-valued delay avoids ModelSim's unsized signed-32-bit timeout overflow.
 initial begin #(3.0e9);$fatal(1,"MCU_STABLE_EPOCH_TIMEOUT boot=%0d configured=%b replies=%0d seq=%0d i=%0d queue=%0d pending=%b",boot.state,configured,responses,next_seq,i,c.queue_count,c.pending_reply);end
endmodule

