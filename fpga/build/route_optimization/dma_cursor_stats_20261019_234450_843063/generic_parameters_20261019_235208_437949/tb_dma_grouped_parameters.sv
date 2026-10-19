`timescale 1ns/1ps
// Purpose: independent byte-memory checks for generic DMA client counts.
// The dual-implementation wrapper additionally compares every interface cycle;
// this controller model follows only native addresses/handshakes and checks
// data against accepted client traffic, never internal owner/group signals.
module tb_dma_grouped_parameters #(parameter N=1,VERIFY=1);
 localparam DEPTH=16384,BEATS=3;
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,controller_ready=1,allow_snapshot=1;
 reg [N-1:0] req_valid=0,req_write=0,urgent=0,cancel=0,w_valid=0,r_ready='1,done_ready=0;
 wire [N-1:0] req_ready,w_ready,r_valid,r_last,done,cancelled,error,write_verified;
 reg [N*32-1:0] req_addr=0,req_tag=0;
 reg [N*5-1:0] req_beats=0;
 reg [N*256-1:0] w_data=0;
 reg [N*32-1:0] w_strb=0;
 wire [N*256-1:0] r_data;
 wire [N*32-1:0] done_tag,max_wait_cycles,bus_bytes,useful_write_bytes;
 wire [27:0] awaddr,araddr;
 wire [3:0] awlen,arlen,awid,arid;
 wire awvalid,arvalid;
 wire [255:0] native_wdata;
 wire [31:0] native_wstrb;
 reg [255:0] native_rdata=0;
 reg awready=0,arready=0,native_wready=0,native_wlast=0,native_rvalid=0,native_rlast=0;
 wire [3:0] native_wid=0,native_rid=0;
 wire fault;
 ddr_native_dma #(.CLIENTS(N),.MAX_BEATS(4),.VERIFY_WRITES(VERIFY)) dut(.*);
 reg [7:0] actual[0:DEPTH-1],expected[0:DEPTH-1];
 integer accepted_address[0:N-1],accepted_length[0:N-1],sent[0:N-1],received[0:N-1];
 integer write_base=0,write_left=0,write_index=0,read_base=0,read_left=0,read_index=0;
 integer cycle=0,c,b,i,beat,checks=0,native_requests=0;
 // Controller inputs change on the falling edge, keeping them stable across
 // both implementations' rising-edge handshakes without testbench races.
 always @(negedge clk)begin
  cycle=cycle+1;
  awready=rst_n && write_left==0 && cycle%5!=0;
  arready=rst_n && read_left==0 && cycle%7!=0;
  native_wready=rst_n && write_left!=0 && cycle%3!=0;
  native_wlast=write_left==1;
  native_rvalid=rst_n && read_left!=0 && cycle%4!=0;
  native_rlast=read_left==1;
  for(integer lane=0;lane<32;lane=lane+1)
   native_rdata[lane*8+:8]=actual[read_base+read_index*32+lane];
 end
 // Only accepted client bytes populate the expected memory. Native writes
 // populate a distinct memory, allowing address/selection/mask errors to fail.
 always @(posedge clk)begin
  if(!rst_n)begin write_left=0;read_left=0;write_index=0;read_index=0;end
  else begin
   for(c=0;c<N;c=c+1)begin
    if(req_valid[c] && req_ready[c])begin
     accepted_address[c]=req_addr[c*32+:32];accepted_length[c]=req_beats[c*5+:5];sent[c]=0;received[c]=0;
    end
    if(w_valid[c] && w_ready[c])begin
     for(b=0;b<32;b=b+1)if(w_strb[c*32+b])
      expected[accepted_address[c]+sent[c]*32+b]=w_data[c*256+b*8+:8];
     sent[c]=sent[c]+1;
    end
    if(r_valid[c] && r_ready[c])begin
     for(b=0;b<32;b=b+1)begin
      if(r_data[c*256+b*8+:8]!==expected[accepted_address[c]+received[c]*32+b])
       $fatal(1,"Generic client read differs N=%0d c=%0d beat=%0d",N,c,received[c]);
      checks=checks+1;
     end
     if(r_last[c]!=(received[c]==accepted_length[c]-1))$fatal(1,"Generic LAST differs");
     received[c]=received[c]+1;
    end
   end
   if(awvalid && awready)begin
    if(awid!=0 || awlen!=BEATS-1 || awaddr*4+BEATS*32>DEPTH)$fatal(1,"Native AW shape");
    write_base=awaddr*4;write_left=awlen+1;write_index=0;native_requests=native_requests+1;
   end
   if(native_wready)begin
    for(b=0;b<32;b=b+1)if(native_wstrb[b])
     actual[write_base+write_index*32+b]=native_wdata[b*8+:8];
    write_left=write_left-1;write_index=write_index+1;
   end
   if(arvalid && arready)begin
    if(arid!=0 || arlen!=BEATS-1 || araddr*4+BEATS*32>DEPTH)$fatal(1,"Native AR shape");
    read_base=araddr*4;read_left=arlen+1;read_index=0;native_requests=native_requests+1;
   end
   if(native_rvalid)begin read_left=read_left-1;read_index=read_index+1;end
  end
 end
 task tick;begin @(posedge clk);#1;end endtask
 task enqueue(input integer client,input bit writing,input integer address,input integer length);
  begin
   @(negedge clk);req_valid[client]=1;req_write[client]=writing;
   req_addr[client*32+:32]=address;req_beats[client*5+:5]=length;req_tag[client*32+:32]=client+32'h1200;
   while(!req_ready[client])tick;
   tick;@(negedge clk);req_valid[client]=0;
  end
 endtask
 task acknowledge;
  begin @(negedge clk);done_ready='1;repeat(3)tick;@(negedge clk);done_ready=0;end
 endtask
 initial begin
  for(i=0;i<DEPTH;i=i+1)begin actual[i]=8'h5a;expected[i]=8'h5a;end
  repeat(5)tick;@(negedge clk);rst_n=1;repeat(3)tick;
  // Queue all clients before filling any write reservation. Distinct byte
  // patterns make accidental selection of a neighbor or final odd bank visible.
  for(i=0;i<N;i=i+1)enqueue(i,1,i*512,BEATS);
  for(beat=0;beat<BEATS;beat=beat+1)for(i=0;i<N;i=i+1)begin
   @(negedge clk);w_valid[i]=1;
   for(integer lane=0;lane<32;lane=lane+1)begin
    w_data[i*256+lane*8+:8]=i*29+beat*7+lane;
    w_strb[i*32+lane]=(lane%5!=(i+beat)%5);
   end
   while(!w_ready[i])tick;
   tick;@(negedge clk);w_valid[i]=0;
  end
  wait(&done);#1;
  if(error!=0 || cancelled!=0 || fault || (VERIFY && write_verified!={N{1'b1}}))$fatal(1,"Write fence failed");
  for(i=0;i<DEPTH;i=i+1)if(actual[i]!==expected[i])$fatal(1,"Native memory mismatch at %0d",i);
  acknowledge;
  for(i=0;i<N;i=i+1)enqueue(i,0,i*512,BEATS);
  wait(&done);#1;if(error!=0 || cancelled!=0 || fault)$fatal(1,"Read completion failed");
  if(checks!=N*BEATS*32)$fatal(1,"Missing read data");
  acknowledge;
  // Denied snapshot and malformed alignment may not issue a native address.
  begin integer prior;prior=native_requests;
   allow_snapshot=0;enqueue(N-1,0,(N-1)*512,BEATS);wait(done[N-1]);#1;
   if(!error[N-1] || native_requests!=prior)$fatal(1,"Snapshot rejection escaped to native bus");
   acknowledge;allow_snapshot=1;
   enqueue(0,0,1,BEATS);wait(done[0]);#1;
   if(!error[0] || native_requests!=prior)$fatal(1,"Unaligned request escaped to native bus");
   acknowledge;
  end
  $display("DMA_GENERIC_PARAMETERS_PASS clients=%0d verify=%0d bytes=%0d",N,VERIFY,checks);$finish;
 end
 initial begin #1000000;$fatal(1,"Generic DMA timeout N=%0d",N);end
endmodule
