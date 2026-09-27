`timescale 1ns/1ps
// Purpose: verify same-CFA median and deterministic fixed tone across every
// code and abrupt changes in previous-frame brightness; no source RAW changes.
module tb_raw8_display_enhance;
 reg clk=0,reset_n=0,line_active=0,line_end=0,pixel_accept=0;
 reg [7:0] sample=0;wire [7:0] luma;
 always #5 clk=~clk;
 raw8_display_enhance dut(.clk(clk),.reset_n(reset_n),
  .line_active(line_active),.line_end(line_end),
  .pixel_accept(pixel_accept),.sample(sample),.luma(luma));
 // Purpose: independently evaluate every input code of the bright-scene tone
 // curve, including both knee joins and the unmodified saturated white code.
 function automatic [7:0] expected_tone(input integer value);
  integer delta;
  begin
   if(value<=24)expected_tone=0;
   else if(value<=80)expected_tone=(value-24)*2;
   else if(value<=144)expected_tone=112+(value-80)+((value-80)>>2);
   else if(value==255)expected_tone=255;
   else begin delta=value-144;expected_tone=192+(delta>>1)+(delta>>4)+(delta>>6);end
  end
 endfunction
 // Purpose: check all low-light knees and the unmodified sensor white code
 // independently of the RTL shifts and arithmetic widths.
 function automatic [7:0] expected_dark(input integer value);
  integer delta;
  begin
   if(value<=8)expected_dark=0;
   else if(value<=16)expected_dark=(value-8)*4;
   else if(value<=32)expected_dark=32+(value-16)*7;
   else if(value<=64)expected_dark=144+(value-32)*2;
   else if(value<=128)expected_dark=208+((value-64)>>1);
   else if(value<=240)expected_dark=240+((value-128)>>4);
   else if(value==255)expected_dark=255;
   else begin delta=value-240;expected_dark=247+(delta>>1);end
  end
 endfunction
 // Purpose: independently calculate the nine-bit rounded midpoint so a
 // return to the former 50% frame selector fails this regression immediately.
 function automatic [7:0] expected_fixed(input integer value);
  integer sum;
  begin sum=integer'(expected_tone(value))+integer'(expected_dark(value))+1;
   expected_fixed=sum>>1;
  end
 endfunction
 task push(input [7:0] value,expected);
  begin
   @(negedge clk);line_active=1;pixel_accept=1;sample=value;
   #1;if(luma!==expected)$fatal(1,"RAW8_ENHANCE_FAIL in=%0d got=%0d expected=%0d",value,luma,expected);
   @(posedge clk);#1;
  end
 endtask
 // Purpose: emulate strongly different preceding frames without relying on
 // same-phase median output during contiguous pixels.
 task feed(input [7:0] value);
  begin
   @(negedge clk);line_active=1;pixel_accept=1;sample=value;
   @(posedge clk);#1;
  end
 endtask
 task end_line;
  begin @(negedge clk);line_active=0;pixel_accept=0;@(posedge clk);#1;end
 endtask
 // Purpose: emulate a frame gap and clear Bayer median history. The tone map
 // must not depend on any preceding frame, regardless of its brightness.
 task next_frame;
  begin
   @(negedge clk);line_active=0;pixel_accept=0;
   @(posedge clk);#1;
  end
 endtask
 integer code;
 initial begin
  repeat(2)@(negedge clk);reset_n=1;
  // Purpose: cover knee transitions and confirm the line-local same-phase
  // median rejects an isolated bright defect without smearing adjacent rows.
  push(0,0);push(24,expected_fixed(24));push(25,expected_fixed(25));
  push(80,expected_fixed(80));end_line();
  push(81,expected_fixed(81));push(144,expected_fixed(144));
  push(145,expected_fixed(145));push(254,254);end_line();
  push(40,expected_fixed(40));push(40,expected_fixed(40));
  push(40,expected_fixed(40));push(40,expected_fixed(40));
  // At x=4 the isolated 255 spike is rejected by x=0/x=2 same-CFA history.
  push(255,expected_fixed(40));end_line();
  push(255,255);end_line();
  // Purpose: Ethernet has no blanking cycle between rows. Its accepted last
  // pixel must clear the median history without changing that pixel's tone.
  push(40,expected_fixed(40));push(40,expected_fixed(40));
  push(40,expected_fixed(40));push(40,expected_fixed(40));
  @(negedge clk);line_active=1;pixel_accept=1;line_end=1;sample=40;
  #1;if(luma!==expected_fixed(40))$fatal(1,"RAW8_LINE_END_LAST_PIXEL");
  @(posedge clk);#1;
  @(negedge clk);line_end=0;sample=255;
  #1;if(luma!==8'd255)$fatal(1,"RAW8_LINE_END_NEXT_ROW");
  @(posedge clk);#1;end_line();
  // Purpose: exhaustively test the fixed map and monotonicity with median
  // history cleared between independent tone samples.
  for(code=0;code<256;code=code+1)begin
   end_line();push(code[7:0],expected_fixed(code));
   if(code>0 && expected_fixed(code)<expected_fixed(code-1))$fatal(1,"RAW8_ENHANCE_NONMONOTONIC %0d",code);
  end
  // Purpose: cross the old dark-majority boundary using a constant 63-code
  // probe. Its fixed output 142 is midway between the former 78/206 flicker.
  next_frame();
  for(code=0;code<256;code=code+1)
   feed(code>=96 && code<160 ? 8'd255 : 8'd12);
  end_line();
  next_frame();push(8'd63,8'd142);
  next_frame();
  for(code=0;code<256;code=code+1)feed(8'd192);
  next_frame();push(8'd63,8'd142);
  $display("RAW8_DISPLAY_ENHANCE_PASS");$finish;
 end
endmodule
