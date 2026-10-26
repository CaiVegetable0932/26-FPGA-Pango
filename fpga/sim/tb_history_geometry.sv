`timescale 1ns/1ps
// Real shared cache + lens + interpolation path with two distinct S1 memories.
// Identical tile addresses in the two domains must never alias. Only outside
// coordinates may use history; DMA errors must still invalidate the whole frame.
module tb_history_geometry;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,start=0,enable=1,inject_error=0;
 wire ready,ov,mask,done,failed,rejected,req,fr,domain;wire [23:0] rgb;wire [15:0] u,v;wire [1:0] provenance;
 reg [447:0] coefficients=0;wire [11:0] tx,ty;reg fv=0,fl=0,active=0,held_domain=0;reg [95:0] data;
 integer n=0,hx=0,hy=0,received=0,frame_index=0;reg request_ready=0;wire [31:0] current_count,history_count,invalid_count;
 geometry_rgb_pipeline #(.FRAME_TAG_BITS(64),.SET_BITS(2),.HISTORY_SUPPORT(1)) dut(
  .clk(clk),.rst_n(rst_n),.frame_valid(start),.frame_ready(ready),.frame_width(16'd64),.frame_height(16'd48),
  .frame_coefficients(coefficients),.frame_tag(64'd81),.frame_enhancement(2'd0),.frame_lut_version(32'd0),
  .frame_history_enable(enable),.frame_history_dx_q16(32'sd262144),.frame_history_dy_q16(32'sd0),
  .fill_history(domain),.out_provenance(provenance),.current_pixels(current_count),.history_pixels(history_count),.invalid_pixels(invalid_count),
  .lut_write(1'b0),.lut_addr(8'd0),.lut_data(8'd0),.lut_commit(1'b0),.lut_version(32'd0),.lut_page(1'b0),
  .out_valid(ov),.out_ready(1'b1),.out_rgb(rgb),.out_mask(mask),.out_u(u),.out_v(v),.out_frame_tag(),
  .fill_req_valid(req),.fill_req_ready(request_ready),.fill_tile_x(tx),.fill_tile_y(ty),
  .fill_valid(fv),.fill_ready(fr),.fill_rgb(data),.fill_last(fl),.fill_error(inject_error && held_domain && fv),.fill_bus_bytes(32'd768),
  .frame_done(done),.frame_failed(failed),.config_rejected(rejected),.active_lut_version(),.cache_misses(),.cache_stalls(),.cache_bus_bytes(),.queue_peak());
 function [23:0] pixel(input integer x,y,input old);begin pixel={8'(x*3+y),8'(x+y*5),8'(x*7+y*11)}^(old?24'h808080:24'd0);end endfunction
 always @(negedge clk)begin
  // Drive handshake inputs away from sampling edges; the memory-model state
  // change must not withdraw READY in the same simulator event as acceptance.
  request_ready=!active;fv=active;fl=n==63;
  for(integer j=0;j<4;j=j+1)data[j*24+:24]=pixel(hx*32+(n%16)*2+j%2,hy*8+(n/16)*2+j/2,held_domain);
 end
 always @(posedge clk)if(rst_n)begin
  if(req && request_ready)begin active=1;n=0;hx=tx;hy=ty;held_domain=domain;end
  if(fv && fr)begin if(fl)active=0;else n=n+1;end
  if(ov)begin
   received=received+1;
   if(frame_index!=1)begin
    if(u<62)begin if(!mask || provenance!=1 || rgb!==pixel(u+2,v,0))$fatal(1,"current source contaminated u=%d v=%d rgb=%h",u,v,rgb);end
    else if(enable && v<47)begin if(!mask || provenance!=2 || rgb!==pixel(u-2,v,1))$fatal(1,"history missing/aliased u=%d v=%d rgb=%h",u,v,rgb);end
    else if(mask || provenance!=0 || rgb!=0)$fatal(1,"invalid region masked as valid");
   end
  end
 end
 initial begin
  coefficients[0+:32]=2097152;coefficients[64+:32]=-62914560;coefficients[128+:32]=2097152;coefficients[160+:32]=-50331648;
  coefficients[320+:32]=2097152;coefficients[352+:32]=2097152;coefficients[384+:32]=2097152;coefficients[416+:32]=1572864;
  #21;rst_n=1;
  for(frame_index=0;frame_index<3;frame_index=frame_index+1)begin
   wait(ready);@(negedge clk);received=0;start=1;enable=frame_index!=2;inject_error=frame_index==1;
   @(negedge clk);start=0;wait(done);@(negedge clk);
   if(received!=3072 || failed!==(frame_index==1))$fatal(1,"completion/fault mismatch frame=%d n=%d failed=%b",frame_index,received,failed);
   if(frame_index==0 && (current_count!=2976 || history_count!=94 || invalid_count!=2))$fatal(1,"provenance counts %d/%d/%d",current_count,history_count,invalid_count);
   if(frame_index==2 && (history_count!=0 || invalid_count!=96))$fatal(1,"OFF history count");
  end
  $display("PASS real two-domain history interpolation/current-priority/provenance/OFF/DMA-fault");$finish;
 end
 initial begin #3000000;$fatal(1,"timeout frame=%d received=%d ready=%b req=%b fill=%b state=%d",frame_index,received,ready,req,active,dut.u_cache.state);end
endmodule
