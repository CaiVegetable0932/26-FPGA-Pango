`timescale 1ns/1ps
// Internal whole-entity guard, NOT a new UART command or wire format. Field
// limits and layout come from the frozen model/configuration validator; they
// must include positive focal length, mode/scale/domain requirements. Signed
// coefficient words are checked individually, then whole-entity CRC32 before
// publishing immutable bytes. It never drops high-order calibration terms.
// Parameterized whole-entity storage is internal only; the integration uses
// 76 bytes for the 19-word geometry request before its separate CRC word. Unsupported models/format/reserved bits
// are represented by format_supported=0 and cannot be committed.
module parameter_entity_guard #(parameter WORDS=16)(
 input clk,input rst_n,input submit_valid,output submit_ready,
 input [WORDS*32-1:0] entity,lower_bounds,upper_bounds,
 input [31:0] expected_crc,input format_supported,
 output reg result_valid,input result_ready,output reg validated,
 output reg [WORDS*32-1:0] result_entity,output reg [1:0] reject_reason
);
 localparam IDLE=0,RANGE=1,CRC=2,FINISH=3;
 reg [1:0] state;
 // The sequential scan addresses WORDS*4 bytes, never an unbounded integer
 // address. Keep its mux/counter width explicit for native ADS synthesis.
 localparam INDEX_BITS=$clog2(WORDS*4);reg [INDEX_BITS-1:0] index;
 reg [WORDS*32-1:0] low,high;
 reg [31:0] crc,crc_expected;reg legal;
 assign submit_ready=state==IDLE && !result_valid;
 function automatic [31:0] update(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer i;begin v=c^b;for(i=0;i<8;i=i+1) v=(v>>1)^(v[0]?32'hedb88320:0);update=v;end
 endfunction
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin state<=IDLE;index<=0;low<=0;high<=0;crc<=0;crc_expected<=0;legal<=0;
   result_valid<=0;validated<=0;result_entity<=0;reject_reason<=0;end
  else begin
   if(result_valid && result_ready) result_valid<=0;
   case(state)
    IDLE: if(submit_valid && submit_ready) begin
     result_entity<=entity;low<=lower_bounds;high<=upper_bounds;crc_expected<=expected_crc;
     legal<=format_supported;reject_reason<=format_supported?0:1;index<=0;state<=RANGE;
    end
    RANGE: begin
     if($signed(low[index*32+:32])>$signed(high[index*32+:32]) ||
        $signed(result_entity[index*32+:32])<$signed(low[index*32+:32]) ||
        $signed(result_entity[index*32+:32])>$signed(high[index*32+:32])) begin legal<=0;reject_reason<=2;end
     if(index==WORDS-1) begin index<=0;crc<=32'hffffffff;state<=CRC;end else index<=index+1;
    end
    CRC: begin
     crc<=update(crc,result_entity[index*8+:8]);
     if(index==WORDS*4-1) state<=FINISH;else index<=index+1;
    end
    FINISH: begin
     result_valid<=1;validated<=legal && ~crc==crc_expected;state<=IDLE;
     if(~crc!=crc_expected) reject_reason<=3;
    end
   endcase
  end
 end
endmodule
