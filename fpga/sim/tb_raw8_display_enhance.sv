`timescale 1ns/1ps
// Purpose: verify FPGA-only same-CFA median and frame-latched dark/bright
// curves, including incomplete-frame hold and no source RAW mutation.
module tb_raw8_display_enhance;
 reg clk=0,reset_n=0,frame_boundary=0,line_active=0,line_end=0,pixel_accept=0;
 reg [7:0] sample=0;wire [7:0] luma;
 always #5 clk=~clk;
 raw8_display_enhance #(.MIN_SAMPLES(4)) dut(.clk(clk),.reset_n(reset_n),
  .frame_boundary(frame_boundary),.line_active(line_active),.line_end(line_end),
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
 task push(input [7:0] value,expected);
  begin
   @(negedge clk);line_active=1;pixel_accept=1;sample=value;
   #1;if(luma!==expected)$fatal(1,"RAW8_ENHANCE_FAIL in=%0d got=%0d expected=%0d",value,luma,expected);
   @(posedge clk);#1;
  end
 endtask
 // Purpose: train the frame classifier without assuming the line-local
 // median output during a contiguous saturated lamp strip.
 task feed(input [7:0] value);
  begin
   @(negedge clk);line_active=1;pixel_accept=1;sample=value;
   @(posedge clk);#1;
  end
 endtask
 task end_line;
  begin @(negedge clk);line_active=0;pixel_accept=0;@(posedge clk);#1;end
 endtask
 // Purpose: emulate a complete HDMI frame boundary without changing the
 // current pixel; this is the only point where the selected curve may change.
 task next_frame;
  begin
   @(negedge clk);line_active=0;pixel_accept=0;frame_boundary=1;
   @(posedge clk);#1;@(negedge clk);frame_boundary=0;
  end
 endtask
 integer code;
 initial begin
  repeat(2)@(negedge clk);reset_n=1;
  // Purpose: cover knee transitions and confirm the line-local same-phase
  // median rejects an isolated bright defect without smearing adjacent rows.
  push(0,0);push(24,0);push(25,2);push(80,112);end_line();
  push(81,113);push(144,192);push(145,192);push(254,254);end_line();
  push(40,32);push(40,32);push(40,32);push(40,32);
  // At x=4 the isolated 255 spike is rejected by x=0/x=2 same-CFA history.
  push(255,32);end_line();
  push(255,255);end_line();
  // Purpose: Ethernet has no blanking cycle between rows. Its accepted last
  // pixel must clear the median history without changing that pixel's tone.
  push(40,32);push(40,32);push(40,32);push(40,32);
  @(negedge clk);line_active=1;pixel_accept=1;line_end=1;sample=40;
  #1;if(luma!==8'd32)$fatal(1,"RAW8_LINE_END_LAST_PIXEL");
  @(posedge clk);#1;
  @(negedge clk);line_end=0;sample=255;
  #1;if(luma!==8'd255)$fatal(1,"RAW8_LINE_END_NEXT_ROW");
  @(posedge clk);#1;end_line();
  // Purpose: exhaustively test the unchanged bright curve with the median
  // history cleared between independent tone samples.
  for(code=0;code<256;code=code+1)begin
   end_line();push(code[7:0],expected_tone(code));
   if(code>0 && expected_tone(code)<expected_tone(code-1))$fatal(1,"RAW8_ENHANCE_NONMONOTONIC %0d",code);
  end
  // Purpose: train a dark majority despite a contiguous saturated lamp strip
  // covering one of four sampling positions. This reproduces the board's
  // failure mode where the mean was pulled high by the light source.
  next_frame();
  for(code=0;code<256;code=code+1)
   feed(code>=96 && code<160 ? 8'd255 : 8'd12);
  end_line();
  push(8'd14,expected_tone(14));
  next_frame();
  push(8'd14,expected_dark(14));
  next_frame();
  push(8'd32,expected_dark(32));
  // Purpose: exhaustively test the low-light curve and its monotonicity,
  // including the high shoulder that protects true white.
  for(code=0;code<256;code=code+1)begin
   end_line();push(code[7:0],expected_dark(code));
   if(code>0 && expected_dark(code)<expected_dark(code-1))$fatal(1,"RAW8_DARK_NONMONOTONIC %0d",code);
  end
  // The evenly sampled rising sweep has no dark majority (0 and 64 tie with
  // 128 and 192); verify the previous-frame decision returns to bright mode.
  next_frame();end_line();push(8'd32,expected_tone(32));
  $display("RAW8_DISPLAY_ENHANCE_PASS");$finish;
 end
endmodule
