`timescale 1ns/1ps
// Purpose: isolated synthesis/route fixture, NOT a board application or DDR
// implementation. Real display/TMDS logic is retained with a local traffic
// source. Resource/timing reports include this source and exclude real DMA/CDC.
// Origin of startup topology: current mini_camera_diag/Top.v and the installed
// PG2L100H high-speed output example. No official source is changed.
module hdmi_display_pnr_probe(input clk_27m,reset_n,
 output hdmi_clk_p,hdmi_clk_n,output [2:0] hdmi_data_p,hdmi_data_n,
 output status_led);
 wire serial_raw,serial_clk,pixel_clk,pll_lock;
 video_pll u_video_pll(.clkin1(clk_27m),.clkout1(serial_raw),.lock(pll_lock));
 GTP_IOCLKBUF u_hdmi_serial_clock(.CLKIN(serial_raw),.DI(1'b1),.CLKOUT(serial_clk));
 reg [7:0] startup_count;
 reg video_div_reset_n /* synthesis syn_preserve = 1 */;
 GTP_IOCLKDIV_E2 #(.DIV_FACTOR("5")) u_hdmi_pixel_clock(
 .CE(1'b1),.CLKIN(serial_raw),.RST_N(video_div_reset_n),.CLKDIVOUT(pixel_clk));
 // Dedicated asynchronous initialization pulse only drives divider/OSERDES.
 always @(posedge clk_27m or negedge reset_n)
  if(!reset_n)startup_count<=0;
  else if(!pll_lock)startup_count<=0;
  else if(startup_count!=255)startup_count<=startup_count+1'b1;
 always @(posedge clk_27m or negedge reset_n)
  if(!reset_n)video_div_reset_n<=1;
  else if(!pll_lock)video_div_reset_n<=1;
  else video_div_reset_n<=!(startup_count>=8'h4f && startup_count<=8'h8f);
 reg [2:0] pixel_reset_stages /* synthesis syn_preserve = 1 */;
 always @(posedge pixel_clk)
  if(!(reset_n && pll_lock && startup_count==255))pixel_reset_stages<=0;
  else pixel_reset_stages<={pixel_reset_stages[1:0],1'b1};
 wire prn=pixel_reset_stages[2];
 wire req_valid,req_ready,r_ready,done_ready,cancel,urgent,fault;
 wire [31:0] addr,req_tag;wire [4:0] beats;
 reg pending,completion,aborted;
 reg [4:0] beat_count,burst_beats;
 reg [31:0] response_tag,offer_gen;
 reg [63:0] offer_id;
 reg [1:0] offer_slot;
 reg [255:0] traffic;
 wire offer_ready,release_valid,boundary,hs,vs,de,tag_valid;
 wire [23:0] rgb;wire [11:0] x,y;wire [1:0] release_slot,ready_lines;
 wire [31:0] release_gen,new_frames,repeats,failed,scanned,empty,uf,ufpixels,gap,low,gen;
 wire [63:0] epoch,id,encoded_epoch,encoded_id;wire [31:0] encoded_gen;
 wire encoded_valid;
 wire rv=pending && !completion && !aborted && beat_count<burst_beats;
 wire rl=beat_count==burst_beats-1'b1;
 assign req_ready=!pending;
 // Purpose: changing 256-bit payload, complete/cancel fences and frame handles
 // keep real datapath and counters observable. It does not model native DDR.
 always @(posedge pixel_clk or negedge prn)
  if(!prn)begin pending<=0;completion<=0;aborted<=0;beat_count<=0;burst_beats<=0;response_tag<=0;
   offer_gen<=1;offer_id<=1;offer_slot<=0;traffic<=256'd1;end
  else begin
   if(offer_ready)begin offer_gen<=offer_gen+1'b1;offer_id<=offer_id+1'b1;offer_slot<=(offer_slot==2)?0:offer_slot+1'b1;end
   if(req_valid && req_ready)begin pending<=1;completion<=0;aborted<=0;beat_count<=0;burst_beats<=beats;response_tag<=req_tag;end
   if(rv && r_ready)begin
    traffic<={traffic[254:0],traffic[255]^traffic[253]^traffic[250]^traffic[245]};
    beat_count<=beat_count+1'b1;if(rl)completion<=1;
   end
   if(cancel && pending)begin aborted<=1;completion<=1;end
   if(completion && done_ready)begin pending<=0;completion<=0;end
  end
 hdmi_display display(.clk(pixel_clk),.rst_n(prn),.stream_enable(1'b1),.locked(1'b1),
 .offer_valid(1'b1),.offer_ready(offer_ready),.offer_base(32'h01800000+({30'd0,offer_slot}<<23)),
 .offer_generation(offer_gen),.offer_slot(offer_slot),.offer_epoch(64'd1),.offer_frame_id(offer_id),
 .release_valid(release_valid),.release_ready(1'b1),.release_slot(release_slot),.release_generation(release_gen),
 .frame_boundary(boundary),.hs(hs),.vs(vs),.de(de),.rgb(rgb),.x(x),.y(y),.tag_valid(tag_valid),
 .epoch(epoch),.source_frame_id(id),.generation(gen),.display_new_frames(new_frames),.display_repeat_frames(repeats),
 .display_failed_frames(failed),.underflow_events(uf),.underflow_pixels(ufpixels),.max_no_service_cycles(gap),.low_water_cycles(low),
 .display_scan_frames(scanned),.display_empty_frames(empty),
 .req_valid(req_valid),.req_ready(req_ready),.req_addr(addr),.req_beats(beats),.req_tag(req_tag),
 .r_valid(rv),.r_ready(r_ready),.r_data(traffic),.r_last(rl),.done(completion),.done_ready(done_ready),
 .cancelled(aborted),.error(1'b0),.done_tag(response_tag),.cancel(cancel),.urgent(urgent),.ready_lines(ready_lines),.dma_fault(fault));
 hdmi_rgb888_tx tx(.pixel_clk(pixel_clk),.serial_clk(serial_clk),.pixel_rst_n(prn),.serializer_reset(!video_div_reset_n),
 .rgb(rgb),.hs(hs),.vs(vs),.de(de),.tag_valid(tag_valid),.epoch(epoch),.source_frame_id(id),.generation(gen),
 .data_p(hdmi_data_p),.data_n(hdmi_data_n),.clock_p(hdmi_clk_p),.clock_n(hdmi_clk_n),
 .symbol_tag_valid(encoded_valid),.symbol_epoch(encoded_epoch),.symbol_source_frame_id(encoded_id),.symbol_generation(encoded_gen));
 // Status is a registered reduction for observability, never an acceptance LED.
 reg observe;
 always @(posedge pixel_clk)observe<=^{addr,gen,x,y,ready_lines,release_slot,release_gen,new_frames,repeats,
 failed,scanned,empty,uf,ufpixels,gap,low,epoch,id,encoded_epoch,encoded_id,encoded_gen,encoded_valid,release_valid,boundary,urgent,fault};
 assign status_led=observe;
endmodule
