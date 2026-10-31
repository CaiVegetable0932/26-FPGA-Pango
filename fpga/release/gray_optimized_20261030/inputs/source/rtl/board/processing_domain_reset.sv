`timescale 1ns/1ps
// Experimental cold-reset coordinator. Native memory must initialize while
// the processing PLL is still locking, so startup does not gate controller
// reset on memory_ready. Once armed, ANY health loss resets controller and
// every client together. Business release waits for arming, closing the gap
// between a fast client reset chain and the slower control-domain arm chain.
// Native reset must asynchronously clear initialization status; this contract
// is required by the existing controller/client cold-reset integration too.
module processing_domain_reset(
 input control_clk,external_reset_n,video_lock,processing_lock,
 input memory_lock,memory_ready,business_fault,camera_lost,
 output joint_reset_n,fabric_async_reset_n,output reg fault_latched,memory_armed
);
 wire control_reset_n;
 wire health=video_lock && processing_lock && memory_lock && memory_ready;
 (* syn_preserve=1 *) reg health_meta,health_sync,fault_meta,fault_sync;
 reset_sync control_release(control_clk,external_reset_n,control_reset_n);
 assign joint_reset_n=external_reset_n && video_lock && !fault_latched &&
  (!memory_armed || health);
 assign fabric_async_reset_n=joint_reset_n && health && memory_armed;
 always @(posedge control_clk or negedge control_reset_n)begin
  if(!control_reset_n)begin
   health_meta<=0;health_sync<=0;fault_meta<=0;fault_sync<=0;
   fault_latched<=0;memory_armed<=0;
  end else begin
   health_meta<=health;health_sync<=health_meta;
   fault_meta<=business_fault;fault_sync<=fault_meta;
   if(health_sync)memory_armed<=1;
   if(fault_sync || camera_lost || (memory_armed && !health_sync))fault_latched<=1;
  end
 end
endmodule
