// Purpose: PRAW V1 wire-compatible frame packetizer for a DDR/DMA byte stream.
// Two packet banks overlap CRC/header construction with downstream transmission.
// Input is COMPACT RAW8 or RGB888 snapshots, never the existing RGB565 camera bus.
// Every descriptor is latched; errors discard the unpublished packet and leave
// earlier packets incomplete at the receiver rather than fabricating valid pixels.
module praw_packetizer #(
 parameter MAX_FRAME_BYTES=8388608, parameter INPUT_TIMEOUT=1250000
)(
 input wire clk,reset_n,
 input wire frame_start, output wire frame_ready,
 input wire [63:0] stream_epoch,frame_id,
 input wire [31:0] param_version,descriptor_id,
 input wire [15:0] width,height,
 input wire [7:0] packet_type,bayer_code,
 input wire pixel_valid,pixel_last,input wire [7:0] pixel_data,
 output wire pixel_ready,
 output wire datagram_start,input wire datagram_ready,
 output wire [15:0] datagram_length,
 output wire payload_valid,input wire payload_ready,output wire [7:0] payload_data,
 output reg frame_done,frame_error,output reg [3:0] error_code,
 output reg [31:0] packets_emitted
);
 localparam IDLE=0,WAIT_BANK=1,HEADER=2,PIXELS=3,PATCH=4,DRAIN=5,
            SIZE_STRIDE=6,SIZE_MULT=7,SIZE_CHECK=8,SIZE_DIVIDE=9;
 reg [3:0] state;
 reg bank_write,bank_read,tx_active;
 reg [1:0] full;
 reg [7:0] mem0[0:1463],mem1[0:1463];
 reg [10:0] length0,length1,write_pos,read_pos,chunk_length;
 reg last0,last1;
 reg [6:0] header_pos;
 reg [2:0] patch_pos;
 reg [31:0] crc,timeout_count,offset,total_bytes,stride;
 reg [15:0] index,count,w,h;
 reg [63:0] epoch_latched,id_latched;
 reg [31:0] param_latched,descriptor_latched;
 reg [7:0] type_latched,bayer_latched;
 reg failed_frame;
 // Purpose: registered size setup and a 32-cycle constant divider keep metadata
 // multiplication/division off the single-cycle descriptor admission path.
 // This setup latency occurs once per frame, not once per pixel or packet.
 reg [33:0] size_product;
 reg [31:0] quotient_work;
 reg [10:0] remainder_work;
 reg [5:0] divide_steps;
 wire [11:0] divide_trial={remainder_work,quotient_work[31]};
 wire divide_ge=divide_trial>=12'd1400;
 wire legal=(packet_type==1 && bayer_code>=1 && bayer_code<=4) ||
            ((packet_type==2 || packet_type==3) && bayer_code==0);
 wire [10:0] read_length=bank_read ? length1 : length0;
 wire read_last=bank_read ? last1 : last0;
 assign frame_ready=state==IDLE && full==0 && !tx_active;
 assign pixel_ready=state==PIXELS;
 assign datagram_start=!tx_active && full[bank_read];
 assign datagram_length={5'b0,read_length};
 assign payload_valid=tx_active;
 assign payload_data=bank_read ? mem1[read_pos] : mem0[read_pos];

 // Purpose: reflected ISO-HDLC byte update; final xor is patched at offset 56.
 function [31:0] crc_byte;
  input [31:0] previous;input [7:0] data;integer j;reg [31:0] c;
  begin c=previous^{24'b0,data};for(j=0;j<8;j=j+1)
   c=c[0] ? (c>>1)^32'hedb88320 : c>>1;crc_byte=c;end
 endfunction
 // Purpose: one authoritative little-endian header definition; CRC bytes are
 // zero during accumulation and replaced only after all real payload is present.
 function [7:0] header_byte;
  input [6:0] n;
  begin
   header_byte=0;
   case(n)
    0:header_byte=8'h50;1:header_byte=8'h52;2:header_byte=8'h41;3:header_byte=8'h57;
    4:header_byte=1;6:header_byte=64;8:header_byte=type_latched;
    9:header_byte=(index==count-1) ? 2 : 0;
    10:header_byte=type_latched==1 ? 1 : 2;
    32:header_byte=w[7:0];33:header_byte=w[15:8];
    34:header_byte=h[7:0];35:header_byte=h[15:8];
    48:header_byte=chunk_length[7:0];49:header_byte={5'b0,chunk_length[10:8]};
    50:header_byte=bayer_latched;51:header_byte=8;
    52:header_byte=index[7:0];53:header_byte=index[15:8];
    54:header_byte=count[7:0];55:header_byte=count[15:8];
    default:begin
     if(n>=12 && n<20)header_byte=epoch_latched>>((n-12)*8);
     else if(n>=20 && n<28)header_byte=id_latched>>((n-20)*8);
     else if(n>=28 && n<32)header_byte=param_latched>>((n-28)*8);
     else if(n>=36 && n<40)header_byte=stride>>((n-36)*8);
     else if(n>=40 && n<44)header_byte=total_bytes>>((n-40)*8);
     else if(n>=44 && n<48)header_byte=offset>>((n-44)*8);
     else if(n>=60)header_byte=descriptor_latched>>((n-60)*8);
    end
   endcase
  end
 endfunction

 // Purpose: independent ping-pong reader; valid/data remain stable on backpressure.
 // frame_done means final datagram accepted by the MAC queue, not wire delivery.
 always @(posedge clk or negedge reset_n) begin
  if(!reset_n)begin
   state<=IDLE;bank_write<=0;bank_read<=0;tx_active<=0;full<=0;
   length0<=0;length1<=0;last0<=0;last1<=0;read_pos<=0;write_pos<=0;
   chunk_length<=0;header_pos<=0;patch_pos<=0;crc<=32'hffffffff;
   timeout_count<=0;offset<=0;total_bytes<=0;stride<=0;index<=0;count<=0;
   w<=0;h<=0;epoch_latched<=0;id_latched<=0;param_latched<=0;
   descriptor_latched<=0;type_latched<=0;bayer_latched<=0;failed_frame<=0;
   size_product<=0;quotient_work<=0;remainder_work<=0;divide_steps<=0;
   frame_done<=0;frame_error<=0;error_code<=0;packets_emitted<=0;
  end else begin
   frame_done<=0;frame_error<=0;
   if(datagram_start && datagram_ready)begin tx_active<=1;read_pos<=0;end
   if(payload_valid && payload_ready)begin
    if(read_pos==read_length-1)begin
     tx_active<=0;full[bank_read]<=0;bank_read<=!bank_read;
     packets_emitted<=packets_emitted+1'b1;
     if(read_last && !failed_frame)frame_done<=1;
    end else read_pos<=read_pos+1'b1;
   end
   case(state)
    IDLE:if(frame_start && frame_ready)begin
     if(!legal || width==0 || height==0)begin
      frame_error<=1;error_code<=1;
     end else begin
      epoch_latched<=stream_epoch;id_latched<=frame_id;param_latched<=param_version;
      descriptor_latched<=descriptor_id;w<=width;h<=height;type_latched<=packet_type;
      bayer_latched<=bayer_code;index<=0;offset<=0;failed_frame<=0;
      error_code<=0;state<=SIZE_STRIDE;
     end
    end
    SIZE_STRIDE:begin
     stride<={16'b0,w}+(type_latched==1 ? 32'd0 : ({16'b0,w}<<1));
     state<=SIZE_MULT;
    end
    SIZE_MULT:begin size_product<=stride[17:0]*h;state<=SIZE_CHECK;end
    SIZE_CHECK:begin
     if(size_product==0 || size_product>MAX_FRAME_BYTES)begin
      frame_error<=1;error_code<=1;state<=IDLE;
     end else begin
      total_bytes<=size_product[31:0];quotient_work<=size_product[31:0]+32'd1399;
      remainder_work<=0;divide_steps<=31;state<=SIZE_DIVIDE;
     end
    end
    SIZE_DIVIDE:begin
     remainder_work<=divide_ge ? divide_trial-12'd1400 : divide_trial;
     quotient_work<={quotient_work[30:0],divide_ge};
     if(divide_steps==0)begin count<={quotient_work[14:0],divide_ge};state<=WAIT_BANK;end
     else divide_steps<=divide_steps-1'b1;
    end
    WAIT_BANK:if(!full[bank_write])begin
     chunk_length<=(total_bytes-offset>1400) ? 11'd1400 : total_bytes-offset;
     header_pos<=0;crc<=32'hffffffff;state<=HEADER;
    end
    HEADER:begin
     if(bank_write)mem1[header_pos]<=header_byte(header_pos);
     else mem0[header_pos]<=header_byte(header_pos);
     crc<=crc_byte(crc,header_byte(header_pos));
     if(header_pos==63)begin write_pos<=0;timeout_count<=0;state<=PIXELS;end
     else header_pos<=header_pos+1'b1;
    end
    PIXELS:begin
     if(pixel_valid)begin
      timeout_count<=0;
      // A missing/early end marker poisons this frame; never publish partial bank.
      if(pixel_last != (offset+write_pos==total_bytes-1))begin
       failed_frame<=1;frame_error<=1;error_code<=2;state<=DRAIN;
      end else begin
       if(bank_write)mem1[64+write_pos]<=pixel_data;else mem0[64+write_pos]<=pixel_data;
       crc<=crc_byte(crc,pixel_data);
       if(write_pos==chunk_length-1)begin patch_pos<=0;state<=PATCH;end
       else write_pos<=write_pos+1'b1;
      end
     end else if(timeout_count==INPUT_TIMEOUT-1)begin
      failed_frame<=1;frame_error<=1;error_code<=3;state<=DRAIN;
     end else timeout_count<=timeout_count+1'b1;
    end
    PATCH:begin
     if(bank_write)mem1[56+patch_pos]<=(~crc)>>(8*patch_pos);
     else mem0[56+patch_pos]<=(~crc)>>(8*patch_pos);
     if(patch_pos==3)begin
      full[bank_write]<=1;
      if(bank_write)begin length1<=64+chunk_length;last1<=index==count-1;end
      else begin length0<=64+chunk_length;last0<=index==count-1;end
      bank_write<=!bank_write;
      if(index==count-1)state<=DRAIN;
      else begin index<=index+1'b1;offset<=offset+chunk_length;state<=WAIT_BANK;end
     end else patch_pos<=patch_pos+1'b1;
    end
    DRAIN:if(full==0 && !tx_active)begin
     // Reset both ring cursors after failure: the unpublished bank was not advanced.
     bank_write<=0;bank_read<=0;state<=IDLE;
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
