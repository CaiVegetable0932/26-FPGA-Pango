`timescale 1ns/1ps
// Purpose: one bounded schema-1 entity upload. The historical module name is
// retained for reference interoperability; image/reference and MCU policy
// kind12 share staging and CRC. MCU policy owns no video frame storage.
// A byte-at-a-time CRC engine avoids a 64-byte combinational CRC network.
// Only the last contiguous chunk may be retried, with byte-exact comparison.
// Staging never changes active state; COMMIT dispatches to the selected
// consumer (video frame bank or immediately fenced MCU link policy).
module pc_reference_upload #(parameter [15:0] ENTITY_MASK=16'h0200,parameter UNQUALIFIED_SUBMIT=0,parameter STREAM_CCM=0)(
 input clk,rst_n,input [63:0] now_us,
 input request_valid,output request_ready,input [7:0] command,
 input [6:0] length,input [639:0] payload,
 output response_valid,input response_ready,output reg [7:0] response_code,
 output [31:0] transaction,output [15:0] accepted_bytes,
 output reference_submit_valid,output [511:0] reference_entity,
 output [2047:0] entity_body,output [15:0] entity_kind,entity_length,
 output [31:0] reference_version,reference_id,input [7:0] reference_code
);
 localparam IDLE=0,WRITE=1,RETRY=2,COMMIT=3,RESPONSE=4;
 // Allocate only bodies advertised by this build. Removing custom LUT upload
 // must remove its storage as well, while preserving the public packed bus.
 localparam BODY_BYTES=ENTITY_MASK[2]?256:(ENTITY_MASK[8] || ENTITY_MASK[13])?128:64;
 reg [2:0] state;reg active,have_chunk,committed;
 reg [6:0] validation_wait;
 reg [191:0] header,committed_header;
 wire [2047:0] staging;
 wire [7:0] write_address=frontier[7:0]+cursor;
 wire [7:0] write_byte=payload[64+cursor*8+:8];
 reg [8:0] frontier,last_offset;
 reg [6:0] cursor,count,last_count;
 // Retry always walks a previously accepted, bounded contiguous chunk. Load
 // its first byte address once instead of recomputing last_offset+cursor on
 // every read of the wide staging mux. The byte width follows the allocated
 // body; accepted chunks prove that no address wraps before the final byte.
 // ADS syn_maxfan applies to this ordinary register (not a reset/clock) and
 // permits local copies of the read-select bits at the mux consumers.
 localparam RETRY_ADDRESS_BITS=$clog2(BODY_BYTES);
 reg [RETRY_ADDRESS_BITS-1:0] retry_address /* synthesis syn_maxfan = 32 */;
 wire [BODY_BYTES*8-1:0] retry_body=staging[BODY_BYTES*8-1:0];
 wire [7:0] retry_byte=retry_body[{retry_address,3'b000}+:8];
 reg [31:0] crc,committed_txid,committed_crc;
 reg [63:0] touched;
 // The sole UART upload path proves LUT monotonicity while its existing CRC
 // engine consumes each new contiguous byte. Retries neither advance nor reset
 // this proof; it spans chunk boundaries and is required before kind2 COMMIT.
 reg [7:0] previous_lut_byte;reg lut_decreasing;
 // The optional board gateway validates the nine signed CCM words while
 // consuming new CRC bytes. One absolute-value unit and row accumulator
 // replace nine parallel validators at the consumer. Retried chunks never
 // advance this proof; the exact complete body and CRC are still required.
 reg [23:0] ccm_bytes;reg [19:0] ccm_row_sum;reg ccm_bad;
 wire [31:0] ccm_word={write_byte,ccm_bytes};
 wire [17:0] ccm_magnitude=ccm_word[17] ? (~ccm_word[17:0]+18'd1):ccm_word[17:0];
 wire ccm_row_first=write_address==19 || write_address==31 || write_address==43;
 wire ccm_row_last=write_address==27 || write_address==39 || write_address==51;
 wire [19:0] ccm_sum_next=(ccm_row_first?20'd0:ccm_row_sum)+{2'd0,ccm_magnitude};
 assign request_ready=state==IDLE;
 assign response_valid=state==RESPONSE;
 // The board splits this raw attempt by kind before qualifying each consumer.
 // Thus a reference validator cannot feed MCU/event enables through a shared
 // result mux. Standalone legacy users retain accepted-only pulses by default.
 assign reference_submit_valid=state==COMMIT && (UNQUALIFIED_SUBMIT || reference_code==0);
 assign reference_entity=staging[511:0],reference_version=header[95:64],reference_id=header[127:96];
 assign entity_body=staging,entity_kind=header[15:0],entity_length=header[143:128];
 assign transaction=active?header[63:32]:0,accepted_bytes={7'd0,frontier};
 // Each supported schema has a fixed size. BODY_BYTES follows ENTITY_MASK;
 // the protocol's 1024-byte ceiling is not advertised as actual storage.
 function [15:0] body_length(input [15:0] kind);
  begin case(kind)
   1,4,5:body_length=32;
   2:body_length=256;
   3,9,12:body_length=64;
   6:body_length=16;
   7:body_length=48;
   8,13:body_length=128;
   default:body_length=0;
  endcase end
 endfunction
 function [31:0] crc_byte(input [31:0] current,input [7:0] value);
  reg [31:0] c;integer bit_index;
  begin c=current^value;
   for(bit_index=0;bit_index<8;bit_index=bit_index+1)c=(c>>1)^(c[0]?32'hedb88320:0);
   crc_byte=c;
  end
 endfunction
 // Decode one bounded byte address into independent byte enables. A dynamic
 // packed part-select write otherwise creates a full 2048-bit barrel merge.
 // Every accepted body's bytes are overwritten before CRC-checked COMMIT;
 // bytes outside its fixed schema are ignored by that consumer.
 genvar byte_index;
 generate for(byte_index=0;byte_index<BODY_BYTES;byte_index=byte_index+1)begin:stage_bytes
  reg [7:0] value;
  assign staging[byte_index*8+:8]=value;
  always @(posedge clk or negedge rst_n)
   if(!rst_n)value<=0;
   else if(state==WRITE && write_address==byte_index)value<=write_byte;
 end
 if(BODY_BYTES<256)begin:unused_body
  assign staging[2047:BODY_BYTES*8]=0;
 end endgenerate
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=IDLE;active<=0;have_chunk<=0;committed<=0;header<=0;committed_header<=0;
   frontier<=0;cursor<=0;count<=0;last_count<=0;last_offset<=0;retry_address<=0;
   previous_lut_byte<=0;lut_decreasing<=0;ccm_bytes<=0;ccm_row_sum<=0;ccm_bad<=0;crc<=32'hffffffff;committed_txid<=0;committed_crc<=0;touched<=0;response_code<=0;validation_wait<=0;
  end else begin
   // Timeout reclaims staging only. Published references are owned elsewhere.
   if(state==IDLE && !request_valid && active && now_us-touched>=64'd2000000)begin
    active<=0;frontier<=0;have_chunk<=0;
   end
   if(state==IDLE && request_valid)begin
    response_code<=0;state<=RESPONSE;touched<=now_us;
    case(command)
     8'ha1:begin
      if(length!=24 || payload[15:0]>13 || body_length(payload[15:0])==0 ||
         !ENTITY_MASK[payload[3:0]] || payload[31:16]!=1)response_code<=6;
      else if(payload[63:32]==0 || payload[95:64]==0 || payload[95] ||
              payload[127:96]==0 || payload[127] || payload[143:128]!=body_length(payload[15:0]) || payload[159:144]!=0)
       response_code<=11;
      else if(committed && payload[63:32]==committed_txid)begin
       if(payload[191:0]!=committed_header)response_code<=11;
      end else if(active)begin
       if(payload[191:0]!=header)response_code<=4;
      end else begin
       active<=1;header<=payload[191:0];frontier<=0;have_chunk<=0;crc<=32'hffffffff;previous_lut_byte<=0;lut_decreasing<=0;ccm_bytes<=0;ccm_row_sum<=0;ccm_bad<=0;
      end
     end
     8'ha2:begin
      if(!active || payload[31:0]!=header[63:32] || payload[63:56]!=0 ||
         payload[55:48]==0 || payload[55:48]>64 || length!=8+payload[55:48] ||
         {1'b0,payload[47:32]}+{9'd0,payload[55:48]}>{1'b0,header[143:128]})response_code<=11;
      else if(payload[47:32]==frontier)begin
       cursor<=0;count<=payload[54:48];state<=WRITE;
      end else if(have_chunk && payload[47:32]==last_offset && payload[55:48]==last_count)begin
       cursor<=0;count<=payload[54:48];retry_address<=last_offset[RETRY_ADDRESS_BITS-1:0];state<=RETRY;
      end else response_code<=11;
     end
     8'ha3:begin
      if(length!=12 || payload[95:64]!=0)response_code<=11;
      else if(committed && payload[31:0]==committed_txid && payload[63:32]==committed_crc)begin end
      else if(!active || payload[31:0]!=header[63:32] || frontier!=header[143:128] ||
              payload[63:32]!=header[191:160] || ~crc!=header[191:160] || (header[15:0]==2 && lut_decreasing) || (STREAM_CCM && header[15:0]==3 && ccm_bad))response_code<=11;
      else begin state<=COMMIT;validation_wait<=0;end
     end
     8'ha5:begin
      // action 1 cancels the matching uncommitted upload; action 2 queries.
      if(length!=8 || payload[31:16]!=0 || (payload[15:0]!=1 && payload[15:0]!=2))response_code<=11;
      else if(payload[15:0]==1)begin
       if(!active || payload[63:32]!=header[63:32])response_code<=11;
       else begin active<=0;frontier<=0;have_chunk<=0;end
      end
     end
     default:response_code<=6;
    endcase
   end
   if(state==WRITE)begin
    crc<=crc_byte(crc,write_byte);
    if(STREAM_CCM && header[15:0]==3 && write_address>=16 && write_address<52)begin
     ccm_bytes<={write_byte,ccm_bytes[23:8]};
     if(write_address[1:0]==3)begin
      ccm_row_sum<=ccm_sum_next;
      if(ccm_word[31:18]!={14{ccm_word[17]}} || (ccm_row_last && ccm_sum_next>131072))ccm_bad<=1;
     end
    end
    if(header[15:0]==2)begin
     if((frontier!=0 || cursor!=0) && write_byte<previous_lut_byte)lut_decreasing<=1;
     previous_lut_byte<=write_byte;
    end
    if(cursor==count-1'b1)begin
     last_offset<=frontier;last_count<=count;have_chunk<=1;frontier<=frontier+count;state<=RESPONSE;
    end else cursor<=cursor+1'b1;
   end
   if(state==RETRY)begin
    // Preserve byte-exact comparison and its response cycle. CRC, frontier
    // and staging remain unchanged on either a matching or rejected retry.
    if(retry_byte!=payload[64+cursor*8+:8])begin
     response_code<=11;state<=RESPONSE;
    end else if(cursor==count-1'b1)state<=RESPONSE;
    else begin cursor<=cursor+1'b1;retry_address<=retry_address+1'b1;end
   end
   if(state==COMMIT)begin
    // 0xff is an INTERNAL kind7/9/13 validation-wait token, never a wire reply.
    // Staging/header stay immutable throughout this bounded wait. Timeout
    // reports ordinary busy and retains the transaction for an exact retry.
    if((header[15:0]==7 || header[15:0]==9 || header[15:0]==13) && reference_code==8'hff)begin
     if(validation_wait==127)begin response_code<=4;state<=RESPONSE;end
     else validation_wait<=validation_wait+1'b1;
    end else begin
     response_code<=reference_code;state<=RESPONSE;
     if(reference_code==0)begin
      active<=0;committed<=1;committed_txid<=header[63:32];
      committed_crc<=header[191:160];committed_header<=header;
     end
    end
   end
   if(state==RESPONSE && response_ready)state<=IDLE;
  end
 end
endmodule
