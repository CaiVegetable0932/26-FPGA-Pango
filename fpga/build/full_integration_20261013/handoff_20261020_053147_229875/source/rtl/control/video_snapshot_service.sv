`timescale 1ns/1ps
import frame_manager_pkg::*;
// A requested pair is copied into independent snapshot banks, then exported
// sequentially over the existing commissioned PC connection. Main SRC/DST
// claims are released after verified copy, before any slow network transfer.
// One DMA client is shared between copy and export; accepted work always drains.
module video_snapshot_service #(parameter WIDTH=1920,HEIGHT=1080,WAIT_CYCLES=125000000)(
 input clk,rst_n,fabric_ready,input pair_request,output pair_request_ready,
 input [1:0] pair_ss,pair_rs,input [31:0] pair_sg,pair_rg,input [543:0] pair_geometry,
 input [5*RSP_BITS-1:0] response,output [5*CMD_BITS-1:0] command,
 output frame_valid,input frame_ready,output frame_meta_t metadata,output [7:0] image_type,
 output reg [31:0] descriptor,output reg [767:0] s1_status,result_status,geometry_status,output byte_valid,input byte_ready,output [7:0] byte_data,
 input net_cancel,net_release,output net_drained,net_release_ready,output net_abort,
 output req_valid,input req_ready,output req_write,output [31:0] req_addr,req_tag,
 output [4:0] req_beats,output [2:0] req_bank,req_owner,output [1:0] req_slot,output [31:0] req_generation,
 output w_valid,input w_ready,output [255:0] w_data,output [31:0] w_strb,
 input r_valid,output r_ready,input [255:0] r_data,
 input dma_done,output dma_done_ready,input dma_error,dma_cancelled,input [31:0] done_tag,output dma_cancel
);
 wire [5*CMD_BITS-1:0] pair_command;
 wire copy_valid,copy_ready,copy_done,copy_failed,copy_drained,copy_abort,pair_ready;
 wire [1:0] ss,rs;wire [31:0] sg,rg,dsg,drg;
 reg [543:0] retained_geometry;frame_meta_t source_metadata;
 frame_snapshot_pair #(.WAIT_CYCLES(WAIT_CYCLES)) pair(.clk(clk),.reset_n(rst_n),.fabric_ready(fabric_ready),
  .request(pair_request),.request_ready(pair_request_ready),.cancel(1'b0),.source_slot(pair_ss),.result_slot(pair_rs),.source_gen(pair_sg),.result_gen(pair_rg),
  .response(response),.command(pair_command),.copy_valid(copy_valid),.copy_ready(copy_ready),.copy_done(copy_done),.copy_error(copy_failed),.copy_drained(copy_drained),.copy_cancel(copy_abort),
  .copy_source_slot(ss),.copy_result_slot(rs),.copy_source_gen(sg),.copy_result_gen(rg),.copy_s1_gen(dsg),.copy_dst_gen(drg),
  .source_meta(source_metadata),.result_meta(),.pair_ready(pair_ready),.busy(),.failed(),.completed_pairs(),.failed_pairs());
 localparam IDLE=0,ACQUIRE=1,WAIT=2,ACTIVE=3,RELEASE=4;
 reg [2:0] state;reg image,reader_drained,pair_consumed;reg [31:0] generation,timer;
 frame_rsp_t selected_response;frame_cmd_t export_command;
 reg [5*CMD_BITS-1:0] export_commands;
 wire active=state==ACTIVE;
 wire [31:0] base=image?32'h04400000:32'h03c00000;
 wire reader_ready,reader_done,reader_failed;
 wire export_req,export_rready,export_done_ready,export_cancel;wire [31:0] export_addr;wire [4:0] export_beats;
 wire copy_req,copy_write,copy_wvalid,copy_rready,copy_done_ready,copy_cancel;
 wire [31:0] copy_addr,copy_tag,copy_strb,copy_generation;wire [2:0] copy_bank,copy_owner;wire [1:0] copy_slot;wire [255:0] copy_data;
 assign selected_response=image?response[SNAP_RESULT*RSP_BITS+:RSP_BITS]:response[SNAP_S1*RSP_BITS+:RSP_BITS];
 assign frame_valid=state==WAIT && reader_ready && pair_ready && fabric_ready,image_type=image?8'd3:8'd2;
 assign net_drained=reader_drained,net_release_ready=state==RELEASE && selected_response.release_ok[NETWORK];
 assign net_abort=active && reader_failed;
 wire start=frame_valid && frame_ready;
 // Pair allocation/SNAPSHOT lanes and dedicated NETWORK lanes are disjoint;
 // every unused packed field is zero before this explicit command merge.
 always @*begin
  export_command='0;export_commands='0;
  if(state==ACQUIRE && pair_ready)export_command.acquire[NETWORK]=1;
  if(state==RELEASE)begin export_command.release_mask[NETWORK]=1;export_command.release_gens={32'd0,generation,64'd0};end
  if(image)export_commands[SNAP_RESULT*CMD_BITS+:CMD_BITS]=export_command;
  else export_commands[SNAP_S1*CMD_BITS+:CMD_BITS]=export_command;
 end
 assign command=pair_command | export_commands;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;image<=0;generation<=0;metadata<='0;reader_drained<=0;pair_consumed<=0;timer<=0;descriptor<=0;s1_status<=0;result_status<=0;geometry_status<=0;retained_geometry<=0;end
  else begin
   // EXPORT remains asserted briefly while the final released slot becomes
   // free. Consume that level once, then wait for the coordinator to rearm.
   if(!pair_ready)pair_consumed<=0;
   // The source parameter record cannot be overwritten while its snapshot
   // claim is held. Retain it before copying, and publish the record with the
   // corresponding S1 descriptor so later active parameters remain unrelated.
   if(pair_request && pair_request_ready)retained_geometry<=pair_geometry;
   case(state)
   IDLE:if(pair_ready && !pair_consumed)begin state<=ACQUIRE;image<=0;pair_consumed<=1;end
   // A pair invalidated by the other image's export cannot provide a second
   // acquisition. Exit without claiming a canceled bank. Already-held owners
   // in WAIT/ACTIVE still pass through their normal drain and release states.
   ACQUIRE:if(!pair_ready)state<=IDLE;
   else if(selected_response.acquire_ok[NETWORK])begin generation<=selected_response.acquire_gens[NETWORK*32+:32];
    metadata<=selected_response.acquire_meta[NETWORK*META_BITS+:META_BITS];descriptor<=descriptor+1'b1;
    // Retain both immutable descriptors after export for PC readback. Each
    // contains the exact PRAW descriptor ID and full packed source metadata.
    if(!image)begin
     geometry_status<={8'h47,24'd0,source_metadata.frame_id,source_metadata.epoch,source_metadata.geometry_version,source_metadata.calibration_entity,retained_geometry};
     s1_status<={120'd0,descriptor+32'd1,selected_response.acquire_meta[NETWORK*META_BITS+:META_BITS]};end
    else result_status<={120'd0,descriptor+32'd1,selected_response.acquire_meta[NETWORK*META_BITS+:META_BITS]};timer<=0;state<=WAIT;end
   WAIT:begin
    if(start)begin state<=ACTIVE;reader_drained<=0;end
    else if(!pair_ready || timer==WAIT_CYCLES-1)state<=RELEASE;
    else timer<=timer+1'b1;
   end
   ACTIVE:begin
    if(reader_done)reader_drained<=1;
    if(net_release && reader_drained)state<=RELEASE;
   end
   RELEASE:if(net_release_ready)begin
    if(!image && pair_ready)begin image<=1;state<=ACQUIRE;end else state<=IDLE;
   end
   endcase
  end
 end
 snapshot_copy_dma #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) copy(.clk(clk),.rst_n(rst_n),.start(copy_valid),.ready(copy_ready),.cancel(copy_abort),
  .source_slot(ss),.result_slot(rs),.source_gen(sg),.result_gen(rg),.s1_gen(dsg),.dst_gen(drg),.done(copy_done),.failed(copy_failed),.drained(copy_drained),
  .req_valid(copy_req),.req_ready(req_ready && !active),.req_write(copy_write),.req_addr(copy_addr),.req_tag(copy_tag),.req_bank(copy_bank),.req_owner(copy_owner),.req_slot(copy_slot),.req_generation(copy_generation),
  .w_valid(copy_wvalid),.w_ready(w_ready && !active),.w_data(copy_data),.w_strb(copy_strb),
  .r_valid(r_valid && !active),.r_ready(copy_rready),.r_data(r_data),.dma_done(dma_done && !active),.dma_done_ready(copy_done_ready),
  .dma_error(dma_error),.dma_cancelled(dma_cancelled),.done_tag(done_tag),.dma_cancel(copy_cancel));
 // Dedicated RGB snapshot slots use aligned bases and 6144-byte rows.
 raw_dma_reader #(.WIDTH(WIDTH*3),.HEIGHT(HEIGHT),.STRIDE(6144),.ALIGNED_ROWS(1)) reader(.clk(clk),.rst_n(rst_n),.start(start),.start_ready(reader_ready),
  .base_addr(base),.slot_begin(base),.slot_end(base+32'h00800000),.cancel(net_cancel),.done(reader_done),.failed(reader_failed),
  .req_valid(export_req),.req_ready(req_ready && active),.req_addr(export_addr),.req_beats(export_beats),
  .r_valid(r_valid && active),.r_ready(export_rready),.r_data(r_data),.dma_done(dma_done && active),.dma_done_ready(export_done_ready),
  .dma_error(dma_error || dma_cancelled || done_tag!=generation),.dma_cancel(export_cancel),.byte_valid(byte_valid),.byte_ready(byte_ready),.byte_data(byte_data));
 assign req_valid=active?export_req:copy_req,req_addr=active?export_addr:copy_addr;
 assign req_tag=active?generation:copy_tag,req_beats=active?export_beats:5'd1,req_write=!active && copy_write;
 assign req_bank=active?(image?3'd4:3'd3):copy_bank,req_owner=active?3'd3:copy_owner;
 assign req_slot=active?2'd0:copy_slot,req_generation=active?generation:copy_generation;
 assign w_valid=!active && copy_wvalid,w_data=copy_data,w_strb=copy_strb;
 assign r_ready=active?export_rready:copy_rready,dma_done_ready=active?export_done_ready:copy_done_ready,dma_cancel=active?export_cancel:copy_cancel;
endmodule
