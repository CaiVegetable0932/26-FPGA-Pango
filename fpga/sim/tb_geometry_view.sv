`timescale 1ns/1ps
// Purpose: frame-intent admission, async held-bus transfer, slot/version pairing,
// generation stability and two-clock final-overlay raster alignment.
module tb_geometry_view;
 reg clk=0,pclk=0,rst_n=0;always #4 clk=~clk;always #7 pclk=~pclk;
 reg context_valid=1,cmd_valid=0,prepare=0;reg [63:0] epoch=7;reg [31:0] session_id=3;
 reg [7:0] cmd=8'h35;reg [255:0] payload=0;wire [7:0] code;wire [95:0] reply;
 wire [31:0] frame_revision,frame_packed,applied_revision,applied_packed,applied_version,generation;
 geometry_view_control controls(clk,rst_n,context_valid,epoch,session_id,cmd_valid,cmd,payload,prepare,
  applied_revision,applied_packed,code,reply,frame_revision,frame_packed);
 reg commit=0,lease=0;reg [1:0] slot=0,lease_slot=0;
 reg [1279:0] coordinates=0;reg [19:0] mask=1;reg [31:0] revision=1,packed_control=2563,version=11,status=1;
 wire lease_ready;reg request=1,ack=0,in_vs=0,in_de=0;reg [31:0] index=0;wire [31:0] value;wire read_valid;
 wire [1279:0] pixel_coordinates;wire [19:0] pixel_visible;wire [31:0] pixel_packed;
 geometry_view_snapshot snap(clk,rst_n,pclk,rst_n,commit,slot,coordinates,mask,revision,packed_control,version,status,
  lease,lease_slot,lease_ready,request,ack,in_vs,in_de,index,value,read_valid,
  applied_revision,applied_packed,applied_version,generation,pixel_coordinates,pixel_visible,pixel_packed);
 // Purpose: run the production address-predecode alongside the unchanged
 // combinational API. Compare live readback after one address setup edge and
 // every public CDC/display output, including a snapshot change during READ.
 wire fast_ready,fast_valid;
 wire [31:0] fast_value,fast_revision,fast_packed,fast_version,fast_generation,fast_pixel_packed;
 wire [1279:0] fast_coordinates;wire [19:0] fast_visible;
 geometry_view_snapshot #(.PREDECODE_READ(1)) snap_fast(
  clk,rst_n,pclk,rst_n,commit,slot,coordinates,mask,revision,packed_control,version,status,
  lease,lease_slot,fast_ready,request,ack,in_vs,in_de,index,fast_value,fast_valid,
  fast_revision,fast_packed,fast_version,fast_generation,fast_coordinates,fast_visible,fast_pixel_packed);
 reg [31:0] sampled_index=0,last_checked_generation=0;
 reg sampled_valid=0;
 integer predecode_checks=0,fresh_reads=0,address_trial;
 always @(posedge clk)begin sampled_index<=index;sampled_valid<=rst_n;end
 always @(negedge clk)if(rst_n && sampled_valid)begin
  check({fast_ready,fast_revision,fast_packed,fast_version,fast_generation,
         fast_coordinates,fast_visible,fast_pixel_packed}===
        {lease_ready,applied_revision,applied_packed,applied_version,generation,
         pixel_coordinates,pixel_visible,pixel_packed},"predecode leaves CDC/display state unchanged");
  if(index===sampled_index)begin
   check({fast_valid,fast_value}==={read_valid,value},"settled address has exact live metadata");
   predecode_checks=predecode_checks+1;
   if(index==5)begin
    check(fast_value===generation,"READ observes current generation, not delayed data");
    if(generation!=last_checked_generation)fresh_reads=fresh_reads+1;
   end
  end
  last_checked_generation=generation;
 end
 reg overlay_enable=0,oh=0,ov=0,od=0;reg [23:0] source_rgb=24'h123456;
 wire [23:0] rgb;wire hs,vs,de;reg [1279:0] overlay_coords=0;
 geometry_marker_overlay #(.WIDTH(32),.HEIGHT(24)) overlay(pclk,rst_n,overlay_coords,20'b1,overlay_enable,6'd10,source_rgb,oh,ov,od,rgb,hs,vs,de);
 reg [2:0] golden_strobes=0;reg [23:0] golden_rgb=0;reg previous_enabled=0;
 integer golden_x=-1,golden_y=-1;integer aligned_points=0;
 integer colored=0,black=0,x,y,read_word,compare_bit;reg [31:0] before_generation;
 task check(input bit ok,input string label_text);begin if(!ok)$fatal(1,"VIEW_FAIL %s",label_text);end endtask
 // Reference FIFO independently checks delay of every strobe and pass-through
 // RGB. Overlay writes cannot feed back to the immutable incoming sample.
 always @(posedge pclk)begin
  if(rst_n)begin
   #1;check({hs,vs,de}==golden_strobes,"all raster strobes align with RGB");
   if(!previous_enabled)check(rgb==golden_rgb,"disabled overlay preserves every RGB byte");
   if(de && rgb==24'hff3864)colored=colored+1;
   if(de && rgb==0)black=black+1;
   if(previous_enabled && de && golden_y==10 && golden_x==10)begin check(rgb==24'hff3864,"marker center alignment");aligned_points=aligned_points+1;end
   if(previous_enabled && de && golden_y==10 && golden_x==5)begin check(rgb==0,"black outline alignment");aligned_points=aligned_points+1;end
   if(previous_enabled && de && golden_y==2 && golden_x==19)begin check(rgb==24'hff3864,"number one glyph alignment");aligned_points=aligned_points+1;end
   golden_strobes={oh,ov,od};golden_rgb=source_rgb;previous_enabled=overlay_enable;
   golden_x=x;golden_y=y;
  end else begin golden_strobes=0;golden_rgb=0;previous_enabled=0;end
 end
 task control(input [31:0] rev,flags,size,input [7:0] expected);begin
  @(negedge clk);payload=0;payload[127:96]=rev;payload[159:128]=flags;payload[191:160]=size;
  #1;check(code==expected,"view admission code");cmd_valid=1;@(negedge clk);cmd_valid=0;
 end endtask
 task publish;begin @(negedge clk);commit=1;@(negedge clk);commit=0;end endtask
 task acquire;begin
  @(negedge clk);lease=1;@(negedge clk);lease=0;wait(!lease_ready);wait(lease_ready);
 end endtask
 task display_frame;begin
  @(negedge pclk);ack=1;repeat(5)@(negedge pclk);request=0;
  repeat(5)@(negedge pclk);ack=0;repeat(5)@(negedge pclk);
  in_vs=1;repeat(2)@(negedge pclk);in_vs=0;repeat(2)@(negedge pclk);in_de=1;
  repeat(5)@(negedge pclk);in_de=0;repeat(6)@(negedge clk);
 end endtask
 task raster;begin
  @(negedge pclk);ov=1;od=0;repeat(3)@(negedge pclk);ov=0;
  for(y=0;y<24;y=y+1)begin
   for(x=0;x<32;x=x+1)begin od=1;source_rgb=24'h123456;@(negedge pclk);end
   od=0;oh=1;repeat(2)@(negedge pclk);oh=0;
  end
  repeat(4)@(negedge pclk);
 end endtask
 initial begin
  repeat(4)@(negedge clk);rst_n=1;
  check(frame_revision==0 && frame_packed==2560,"corrected markers-off default");
  control(1,3,10,0);check(frame_revision==0,"intent cannot change running frame");
  @(negedge clk);prepare=1;@(negedge clk);prepare=0;
  check(frame_revision==1 && frame_packed==2563,"frame prepare samples intent");
  control(1,3,10,1);control(1,2,10,10);control(0,0,10,11);
  control(2,4,10,11);control(2,2,3,11);control(2,2,33,11);control(2,2,32,0);control(1,3,10,9);
  check(frame_revision==1 && frame_packed==2563,"pending revision does not change frame");
  coordinates[63:0]={32'd8192,32'd4096};publish();acquire();
  check(generation==0 && applied_revision==0,"lease is not displayed confirmation");
  display_frame();check(generation==1 && applied_revision==1 && applied_version==11 && applied_packed==2563,"first displayed snapshot");
  index=16;#1;check(value==0,"canonical source marker one");index=17;#1;check(value==4096,"displayed dx");
  index=19;#1;check(value==24'hff3864,"displayed canonical color");index=20;#1;check(value==1,"visibility flag");
  index=115;#1;check(read_valid,"last legal marker word");index=116;#1;check(!read_valid,"reject out of range read");
  slot=1;revision=2;version=12;packed_control=8194;coordinates[63:0]={32'd16384,32'd12288};publish();
  check(pixel_coordinates[31:0]==4096 && generation==1,"other slot cannot change current overlay");
  request=1;repeat(4)@(negedge pclk);lease_slot=1;acquire();
  check(pixel_coordinates[31:0]==4096 && generation==1,"new lease waits raster boundary");
  display_frame();check(generation==2 && applied_revision==2 && applied_version==12 && pixel_coordinates[31:0]==12288,"atomic second frame");
  request=1;repeat(4)@(negedge pclk);acquire();display_frame();
  check(generation==2,"identical displayed metadata stays readable across repeated video frames");
  before_generation=generation;
  // Read every metadata-table word while several identical frames activate.
  // This models a UART sweep spanning video boundaries without slowing clocks.
  for(read_word=16;read_word<116;read_word=read_word+1)begin
   index=read_word;@(negedge clk);check(read_valid && generation==before_generation,"coherent full metadata sweep");
   if(read_word%20==0)begin request=1;repeat(4)@(negedge pclk);acquire();display_frame();end
  end
  check(generation==before_generation,"before/after generation check survives repeated frames");
  // Hold a header READ across real display acknowledgements: predecode may
  // retain the address but must never cache the generation or reply data.
  index=5;repeat(2)@(negedge clk);
  // Exercise every coordinate comparison chunk, including a lowest-bit-only
  // update that leaves revision/version/flags unchanged. A frame round trip
  // must cover all three comparison stages; repeat frames must settle to zero.
  for(compare_bit=0;compare_bit<1280;compare_bit=compare_bit+32)begin
   coordinates[compare_bit]=!coordinates[compare_bit];publish();
   request=1;repeat(4)@(negedge pclk);acquire();display_frame();
   before_generation=before_generation+1;
   check(generation==before_generation && pixel_coordinates==coordinates,"chunk-only coordinate change reaches displayed snapshot");
   request=1;repeat(4)@(negedge pclk);acquire();display_frame();
   check(generation==before_generation,"comparison pipeline settles after publication");
  end
  // Last partial chunk is status[31:12], above all coordinate words.
  status=32'h80000001;publish();request=1;repeat(4)@(negedge pclk);acquire();display_frame();
  check(generation==before_generation+1,"last partial comparison chunk");
  // Sweep all bounded words and high-bit aliases. A seven-bit selector alone
  // must never admit an invalid 32-bit address or leak stale marker data.
  for(address_trial=0;address_trial<128;address_trial=address_trial+1)begin
   @(negedge clk);index=address_trial;repeat(2)@(negedge clk);
   check(fast_valid==((address_trial<=6)||(address_trial>=16 && address_trial<116)),"full legal index domain");
   index=32'h80000000|address_trial;repeat(2)@(negedge clk);
   check(!fast_valid && fast_value==0,"high-bit address alias rejected");
  end
  epoch=8;repeat(3)@(negedge clk);prepare=1;@(negedge clk);prepare=0;
  check(frame_revision==0 && frame_packed==2560,"epoch invalidates pending intent");
  overlay_coords[63:0]={32'd40960,32'd40960};raster();
  overlay_enable=1;raster();check(colored>30 && black>10 && aligned_points==3,"colored numbered marker and black outline rendered");
  check(source_rgb==24'h123456,"source bytes remain untouched");
  check(predecode_checks>300 && fresh_reads>=40,"predecode comparisons and fresh-update coverage");
  $display("GEOMETRY_VIEW_PASS colored=%0d black=%0d predecode_checks=%0d fresh_reads=%0d",colored,black,predecode_checks,fresh_reads);$finish;
 end
 initial begin #1000000;$fatal(1,"VIEW_TIMEOUT");end
endmodule
