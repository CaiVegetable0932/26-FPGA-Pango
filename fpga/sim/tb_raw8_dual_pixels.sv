`timescale 1ns/1ps
// Purpose: a full DVP frame is stored by the actual capture RTL, then read by
// concurrent HDMI-gray and PRAW paths. Memory here is an ideal behavioral DDR
// store, NOT a native DDR/CDC model or a physical camera/30 fps measurement.
module tb_raw8_dual_pixels;
 reg camclk=0,netclk=0,pclk=0;
 always #6 camclk=~camclk;
 always #4 netclk=~netclk;
 always #6.734 pclk=~pclk;
 reg reset_n=0,vs=1,href=0,read_reset=0,nstart=0,hstart=0;
 reg [7:0] data=0;
 wire cvalid,cresult,cgood;wire [255:0] cword;wire [16:0] coffset;
 wire [63:0] capture_id;
 reg [255:0] memory[0:69119];
 raw8_capture #(.WARMUP_FRAMES(0)) capture(.clk(camclk),.reset_n(reset_n),
  .configured(1'b1),.arm(1'b1),.vsync(vs),.href(href),.data(data),
  .frame_start(),.frame_id(capture_id),.word_valid(cvalid),.word_ready(1'b1),
  .word_data(cword),.word_offset(coffset),.result_valid(cresult),.result_ready(1'b0),
  .result_good(cgood),.rejected_frames(),.overflow_frames());
 always @(posedge camclk)if(cvalid)memory[coffset]<=cword;
 reg [255:0] nw=0,hw=0;reg nv=0,hv=0;
 wire nr,hr,nready,ndone,nerror,nbusy,en,er;
 wire [7:0] txd;
 raw8_network_output network(.clk(netclk),.reset_n(read_reset),.enable(1'b1),.discard(1'b0),
  .frame_start(nstart),.frame_ready(nready),.stream_epoch(64'h1020304050607080),
  .frame_id(capture_id),.descriptor_id(32'd99),.param_version(32'd7),
  .word_data(nw),.word_valid(nv),.word_ready(nr),
  .src_mac(48'h020000000001),.dst_mac(48'h020000001001),
  .src_ip(32'hc0000201),.dst_ip(32'hc6336402),.src_port(16'd50001),.dst_port(16'd50000),
  .gmii_txd(txd),.gmii_tx_en(en),.gmii_tx_er(er),.frame_done(ndone),
  .frame_error(nerror),.mac_busy(nbusy),.error_code());
 wire [7:0] sample;wire pv,pr,plast,hidle;
 wire hs,vsout,de,boundary;wire [23:0] rgb;wire [31:0] underflows;
 raw8_unpack display(.clk(pclk),.reset_n(read_reset),.start(hstart),.idle(hidle),
  .word_data(hw),.word_valid(hv),.word_ready(hr),.pixel_data(sample),
  .pixel_valid(pv),.pixel_last(plast),.pixel_ready(pr),.done());
 raw8_hdmi_timing raster(.clk(pclk),.reset_n(read_reset),.enable(1'b1),
  .sample(sample),.sample_valid(pv),.sample_ready(pr),.hsync(hs),.vsync(vsout),
  .de(de),.frame_boundary(boundary),.rgb(rgb),.underflows(underflows));
 integer x,y,i,word_index,hword_index,pixels=0,stored=0;
 integer hexfile,lenfile,packets=0,wire_length=0,ncycle=0,first_cycle,last_cycle;
 integer idle_cycles=20,hraster=0,hs_count=0,vs_count=0;
 reg was_en=0,network_complete=0,display_complete=0,network_seen_done=0;
 always @(posedge netclk)begin
  ncycle=ncycle+1;
  if(read_reset && (nerror || er))$fatal(1,"RAW8_FAIL network error");
  if(ndone)network_seen_done=1;
  if(en)begin
   if(!was_en)begin
    if(idle_cycles<12)$fatal(1,"RAW8_FAIL IFG");wire_length=0;
   end
   $fwrite(hexfile,"%02x\n",txd);wire_length=wire_length+1;idle_cycles=0;
  end else begin
   idle_cycles=idle_cycles+1;
   if(was_en)begin $fwrite(lenfile,"%0d\n",wire_length);packets=packets+1;end
  end
  was_en=en;
 end
 // Purpose: independently check the fixed midpoint tone and causal Bayer-
 // cell averaging on every HDMI pixel, including the former mode boundary.
 function automatic [7:0] display_tone(input [7:0] value);
  integer bright,dark,delta;
  begin
   if(value<=24)bright=0;
   else if(value<=80)bright=(value-24)*2;
   else if(value<=144)bright=112+(value-80)+((value-80)>>2);
   else if(value==255)bright=255;
   else begin delta=value-144;bright=192+(delta>>1)+(delta>>4)+(delta>>6);end
   if(value<=8)dark=0;
   else if(value<=16)dark=(value-8)*4;
   else if(value<=32)dark=32+(value-16)*7;
   else if(value<=64)dark=144+(value-32)*2;
   else if(value<=128)dark=208+((value-64)>>1);
   else if(value<=240)dark=240+((value-128)>>4);
   else if(value==255)dark=255;
   else dark=247+((value-240)>>1);
   display_tone=(bright+dark+1)>>1;
  end
 endfunction
 function automatic [7:0] median3(input [7:0] a,b,c);
  if(a>b)median3=b>c?b:(a>c?c:a);
  else median3=a>c?a:(b>c?c:b);
 endfunction
 reg [7:0] expected_raw,expected_display,expected_toned;
 reg [7:0] expected_line [0:1919];
 reg [7:0] expected_current_left,expected_prior_left;
 reg [7:0] expected_left,expected_top,expected_top_left;
 integer expected_gray,display_x,display_y;
 always @(posedge pclk)if(read_reset && !display_complete)begin
  if(de)begin
   expected_raw=8'((pixels*17+22)&255);
   expected_display=pixels%1920>=4 ? median3(expected_raw,
    8'(((pixels-2)*17+22)&255),8'(((pixels-4)*17+22)&255)) : expected_raw;
   // Purpose: compare the rendered HDMI byte to an independent row-buffer
   // reference, including frame-top and left-edge replication.
   expected_toned=display_tone(expected_display);
   display_x=pixels%1920;display_y=pixels/1920;
   expected_left=display_x==0 ? expected_toned : expected_current_left;
   expected_top=display_y==0 ? expected_toned : expected_line[display_x];
   expected_top_left=display_y==0 ? expected_left :
                     display_x==0 ? expected_top : expected_prior_left;
   expected_gray=(expected_toned+expected_left+expected_top+expected_top_left+2)>>2;
   if(!pv || rgb!=={3{expected_gray[7:0]}})$fatal(1,"RAW8_FAIL HDMI pixel %0d got=%h want=%0d",pixels,rgb,expected_gray);
   expected_line[display_x]=expected_toned;
   expected_current_left=expected_toned;
   expected_prior_left=expected_top;
   pixels=pixels+1;
  end
  if(hs)hs_count=hs_count+1;
  if(vsout)vs_count=vs_count+1;
  hraster=hraster+1;
  if(hraster==2475000)begin
   if(pixels!=2073600 || hs_count!=49500 || vs_count!=11000 || underflows!=0)
    $fatal(1,"RAW8_FAIL HDMI geometry pixels=%0d hs=%0d vs=%0d",pixels,hs_count,vs_count);
   display_complete=1;
  end
 end
 initial begin
  hexfile=$fopen("raw8_gmii.hex","w");lenfile=$fopen("raw8_gmii_lengths.txt","w");
  repeat(5)@(negedge camclk);reset_n=1;
  for(y=0;y<1080;y=y+1)begin
   for(x=0;x<1920;x=x+1)begin
    @(negedge camclk);vs=0;href=1;data=((y*1920+x)*17+22)&255;
   end
   @(negedge camclk);href=0;repeat(128)@(negedge camclk);
  end
  vs=1;wait(cresult);if(!cgood)$fatal(1,"RAW8_FAIL capture rejected");
  // Start both output clocks after the same validated stored frame, not after
  // separate synthetic generators. Identity remains capture_id=0 in both paths.
  @(negedge pclk);read_reset=1;hstart=1;
  fork
   begin
    @(negedge pclk);hstart=0;
    for(hword_index=0;hword_index<64800;hword_index=hword_index+1)begin
     hw=memory[(hword_index/60)*64+hword_index%60];hv=1;
     @(posedge pclk);while(!hr)@(posedge pclk);
     @(negedge pclk);
    end
    hv=0;
   end
   begin
    @(negedge netclk);nstart=1;wait(nready);
    @(posedge netclk);first_cycle=ncycle;
    @(negedge netclk);nstart=0;
    for(word_index=0;word_index<64800;word_index=word_index+1)begin
     nw=memory[(word_index/60)*64+word_index%60];nv=1;
     @(posedge netclk);while(!nr)@(posedge netclk);
     @(negedge netclk);
    end
    nv=0;wait(network_seen_done);wait(!nbusy);repeat(20)@(negedge netclk);
    last_cycle=ncycle;
    if(packets!=1482 || last_cycle-first_cycle>=4166666)$fatal(1,"RAW8_FAIL network rate/count");
    network_complete=1;
   end
  join
  wait(display_complete && network_complete);
  $fclose(hexfile);$fclose(lenfile);
  $display("RAW8_DUAL_PIXELS_PASS pixels=%0d packets=%0d net_cycles=%0d capture_id=%0d",pixels,packets,last_cycle-first_cycle,capture_id);
  $finish;
 end
 initial begin #150000000;$fatal(1,"RAW8_TIMEOUT dual output");end
endmodule
