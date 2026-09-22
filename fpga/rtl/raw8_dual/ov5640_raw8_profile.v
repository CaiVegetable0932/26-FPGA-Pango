// Purpose: explicit 1080p RAW8 candidate overrides after the MINI analog table.
// Source: OV5640 datasheet v2.01 tables 6-2,7-5,7-7,7-15,7-18,7-21;
// DVP application guide clock formula. 24 MHz XCLK -> nominal 84 MHz sysclk,
// HTS=2500, VTS=1120 -> target 30 fps (MUST measure real DVP before acceptance).
// 501f=04 selects sensor RAW before ISP, unlike 03 (ISP DPC). 4300=00 requests
// BGGR order; physical Bayer phase is unverified until a color-target test.
// Fixed 768-line exposure / 2x gain avoids automatic VTS/frame-rate expansion
// during first bring-up. This is not final automatic exposure or color tuning.
module ov5640_raw8_profile(input wire [6:0] index,output reg [23:0] value,
 output wire last);
 assign last=index==60;
 always @* case(index)
  0:value=24'h303418; 1:value=24'h303511; 2:value=24'h303669;
  3:value=24'h303713; 4:value=24'h310801;
  // Purpose: non-binned 1952x1088 sensor window and 1920x1080 active output.
  5:value=24'h382040; 6:value=24'h382106;
  7:value=24'h381411; 8:value=24'h381511;
  9:value=24'h380001; 10:value=24'h380150;
  11:value=24'h380201; 12:value=24'h3803b2;
  13:value=24'h380408; 14:value=24'h3805ef;
  15:value=24'h380605; 16:value=24'h3807f1;
  17:value=24'h380807; 18:value=24'h380980;
  19:value=24'h380a04; 20:value=24'h380b38;
  21:value=24'h380c09; 22:value=24'h380dc4;
  23:value=24'h380e04; 24:value=24'h380f60;
  25:value=24'h381000; 26:value=24'h381110;
  27:value=24'h381200; 28:value=24'h381304;
  // Purpose: full-resolution analog/readout mode, no scaling or RGB formatter.
  29:value=24'h361804; 30:value=24'h36122b;
  31:value=24'h370852; 32:value=24'h370912; 33:value=24'h370c00;
  34:value=24'h400406; 35:value=24'h40051a;
  36:value=24'h430000; 37:value=24'h501f04;
  38:value=24'h500000; 39:value=24'h500100;
  40:value=24'h460b37; 41:value=24'h460c20; 42:value=24'h382401;
  // Purpose: retain DVP pad outputs, continuous PCLK and disabled test patterns.
  43:value=24'h300e58; 44:value=24'h3017ff; 45:value=24'h3018ff;
  46:value=24'h474020; 47:value=24'h474100; 48:value=24'h474500;
  49:value=24'h503d00; 50:value=24'h471303;
  // Purpose: make exposure/gain reproducible; every field is read back.
  51:value=24'h350303; 52:value=24'h350000; 53:value=24'h350130;
  54:value=24'h350200; 55:value=24'h350a00; 56:value=24'h350b20;
  57:value=24'h350c00; 58:value=24'h350d00;
  59:value=24'h340601; 60:value=24'h310303;
  default:value=24'h503d00;
 endcase
endmodule
