`timescale 1ns/1ps
// Purpose: immutable per-channel tone curve adapted from the historical MINI
// c8c7206e raw8_display_enhance.v tone_value only. The Bayer-phase median is
// not copied into RGB. Version 1 identifies this reference curve, not optical
// calibration. Geometry applies it through its real pre/post LUT banks.
module legacy_tone_lut(input [7:0] address,output [7:0] value);
 function [7:0] tone_value(input [7:0] v);
  reg [7:0] bright,dark,d;reg [8:0] sum;
  begin
   if(v<=24)bright=0;
   else if(v<=80)begin d=v-24;bright=d<<1;end
   else if(v<=144)begin d=v-80;bright=112+d+(d>>2);end
   else if(v==255)bright=255;
   else begin d=v-144;bright=192+(d>>1)+(d>>4)+(d>>6);end
   if(v<=8)dark=0;
   else if(v<=16)begin d=v-8;dark=d<<2;end
   else if(v<=32)begin d=v-16;dark=32+(d<<3)-d;end
   else if(v<=64)begin d=v-32;dark=144+(d<<1);end
   else if(v<=128)begin d=v-64;dark=208+(d>>1);end
   else if(v<=240)begin d=v-128;dark=240+(d>>4);end
   else if(v==255)dark=255;
   else begin d=v-240;dark=247+(d>>1);end
   sum={1'b0,bright}+{1'b0,dark}+9'd1;tone_value=sum[8:1];
  end
 endfunction
 reg [7:0] table_data[0:255] /* synthesis syn_romstyle="lut_rom" */;
 integer entry;
 initial for(entry=0;entry<256;entry=entry+1)table_data[entry]=tone_value(entry[7:0]);
 assign value=table_data[address];
endmodule
