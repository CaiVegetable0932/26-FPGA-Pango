// Purpose: own the three 4 MiB RAW slots from the authoritative DDR map.
// All signals are MEMORY-domain only. CDC adapters must transfer metadata as
// one held mailbox transaction, not independently synchronize frame-id bits.
// commit requires valid geometry AND an AXI/FIFO drain fence. Readers release
// only after all outstanding memory accesses have drained, including aborts.
// Purpose: BASE allows the identical lease rules to protect a separate
// grayscale result pool; default preserves the existing RAW DDR allocation.
module raw8_frame_pool #(parameter [27:0] BASE=28'h3000000)(
 input wire clk,reset_n,
 input wire capture_request,output reg capture_grant,
 output reg [1:0] capture_slot,output wire [27:0] capture_base,
 input wire capture_commit,capture_good,capture_drained,
 input wire [63:0] captured_id,captured_epoch,
 input wire hdmi_request,hdmi_release,output reg hdmi_grant,
 output reg hdmi_locked,output reg [1:0] hdmi_slot,
 output reg [63:0] hdmi_id,hdmi_epoch,
 // Purpose: publication sequence of the selected lease, not the live counter.
 // A concurrent commit must not make a reader skip an unprocessed newer frame.
 output reg [31:0] hdmi_publication,
 input wire net_request,net_release,output reg net_grant,
 output reg net_locked,output reg [1:0] net_slot,
 output reg [63:0] net_id,net_epoch,
 output reg [31:0] published,dropped,output reg protocol_error
);
 reg writing,latest_valid;
 reg [1:0] latest;
 reg [63:0] slot_id[0:2],slot_epoch[0:2];
 reg [31:0] slot_publication[0:2];
 reg found;reg [1:0] free_slot;
 integer i;
 assign capture_base=BASE+({26'b0,capture_slot}<<22);
 // Purpose: reserve latest even if neither reader has acquired it yet. The
 // writer cannot reuse either reader's old frame while a new frame is pending.
 always @* begin
  found=0;free_slot=0;
  for(i=0;i<3;i=i+1)
   if(!found && (!latest_valid || latest!=i) &&
      (!hdmi_locked || hdmi_slot!=i) && (!net_locked || net_slot!=i) &&
      (!writing || capture_slot!=i))begin found=1;free_slot=i;end
 end
 always @(posedge clk or negedge reset_n)
  if(!reset_n)begin
   writing<=0;latest_valid<=0;latest<=0;capture_slot<=0;
   capture_grant<=0;hdmi_grant<=0;net_grant<=0;
   hdmi_locked<=0;net_locked<=0;hdmi_slot<=0;net_slot<=0;
   hdmi_id<=0;net_id<=0;hdmi_epoch<=0;net_epoch<=0;
   hdmi_publication<=0;
   published<=0;dropped<=0;protocol_error<=0;
  end else begin
   capture_grant<=0;hdmi_grant<=0;net_grant<=0;
   if(hdmi_release)hdmi_locked<=0;
   if(net_release)net_locked<=0;
   if(capture_request)begin
    if(!writing && found && !capture_commit)begin
     capture_slot<=free_slot;writing<=1;capture_grant<=1;
    end else dropped<=dropped+1'b1;
   end
   // Purpose: an invalid/no-drain commit cannot silently free the writer slot;
   // fail closed until a later drained commit or global reset is supplied.
   if(capture_commit)begin
    if(!writing || !capture_drained)protocol_error<=1;
    else begin
     writing<=0;
     if(capture_good)begin
      latest<=capture_slot;latest_valid<=1;
      slot_id[capture_slot]<=captured_id;slot_epoch[capture_slot]<=captured_epoch;
      slot_publication[capture_slot]<=published+1'b1;
      published<=published+1'b1;
     end
    end
   end
   if(hdmi_request && !hdmi_locked && latest_valid)begin
    hdmi_locked<=1;hdmi_slot<=latest;hdmi_grant<=1;
    hdmi_id<=slot_id[latest];hdmi_epoch<=slot_epoch[latest];
    hdmi_publication<=slot_publication[latest];
   end
   if(net_request && !net_locked && latest_valid)begin
    net_locked<=1;net_slot<=latest;net_grant<=1;
    net_id<=slot_id[latest];net_epoch<=slot_epoch[latest];
   end
  end
endmodule
