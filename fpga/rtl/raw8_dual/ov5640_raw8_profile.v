// Purpose: explicit 1080p RAW8 candidate overrides after the MINI analog table.
// Source: OV5640 datasheet v2.01 tables 6-2,7-5,7-7,7-15,7-18,7-21;
// DVP application guide pp56-57: bit_div2x=4 for 3034=18, NOT 5.
// 24/3*84/1/2*2/4/2 = 84 MHz sysclk; old multiplier105 gave105 MHz.
// HTS=2500, VTS=1120 -> target 30 fps (MUST measure real DVP before acceptance).
// 501f=03 selects ISP RAW (DPC) so the programmed DVP output window is applied.
// The earlier 04 SNR RAW trial produced a repeatable 1952-byte line artifact
// and 1086 rows on hardware; this is a controlled candidate, not yet proof.
// 4300=00 requests BGGR order; physical Bayer phase remains unverified.
// Purpose: bias auto AEC/AGC slightly brighter than the sensor's default
// stable range for both RAW8 Ethernet and HDMI. Night mode stays disabled;
// exposure remains below VTS=1120 to preserve 1080p30 geometry. A 5x gain
// ceiling gives dim regions limited extra headroom without unlimited noise.
// FPGA HDMI tone mapping and Ethernet S0 remain unchanged for comparison.
module ov5640_raw8_profile(input wire [6:0] index,output reg [23:0] value,
 output wire last);
 assign last=index==73;
 always @* case(index)
  0:value=24'h303418; 1:value=24'h303511; 2:value=24'h303654;
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
  // Purpose: retain baseline BLC. The 4004=00 trial still measured 1086
  // physical HREF rows, so changing this register is not the frame-size fix.
  34:value=24'h400406; 35:value=24'h40051a;
  // Purpose: pass RAW through the ISP output/crop path, rather than the
  // physical sensor-window RAW tap whose observed width was 1952 samples.
  36:value=24'h430000; 37:value=24'h501f03;
  38:value=24'h500000; 39:value=24'h500100;
  40:value=24'h460b37; 41:value=24'h460c20; 42:value=24'h382401;
  // Purpose: retain DVP pad outputs, continuous PCLK and disabled test patterns.
  43:value=24'h300e58; 44:value=24'h3017ff; 45:value=24'h3018ff;
  // Purpose: the camera module ALREADY connects sensor D[9:2] to CAM1_D[7:0].
  // The 4745=02 debug rotation moves sensor D[1:0] into those top two wires,
  // which hardware captures showed as independent random noise. Keep normal
  // 10-bit pad order so the connector carries the upper eight RAW bits.
  46:value=24'h474020; 47:value=24'h474100; 48:value=24'h474500;
  49:value=24'h503d00; 50:value=24'h471303;
  // Purpose: keep auto-exposure within one 1120-line frame, with no night
  // mode or frame-rate reduction. The 1104-line ceiling leaves 16 blank rows.
  51:value=24'h3a0078; 52:value=24'h3a0530;
  53:value=24'h3a0204; 54:value=24'h3a0350;
  55:value=24'h3a1404; 56:value=24'h3a1550;
  // Purpose: move the documented default AEC stable window up by eight
  // code points (0x68..0x78 -> 0x70..0x80) for a modest brightness increase.
  // Permit AGC up to 5x (real-gain code 0x50) if exposure reaches its cap;
  // retain both enter/go-out thresholds equal for predictable convergence.
  57:value=24'h3a1800; 58:value=24'h3a1950;
  59:value=24'h3a0f80; 60:value=24'h3a1070;
  61:value=24'h3a1b80; 62:value=24'h3a1e70;
  63:value=24'h3a11d0; 64:value=24'h3a1f40;
  // Purpose: update 50/60 Hz anti-banding steps for 84 MHz/2500 HTS:
  // 33,600 rows/s gives 336 rows at 50 Hz and 280 at 60 Hz.
  65:value=24'h3a0801; 66:value=24'h3a0950;
  67:value=24'h3a0a01; 68:value=24'h3a0b18;
  69:value=24'h3a0d03; 70:value=24'h3a0e03;
  // Purpose: enable sensor-controlled exposure and gain only after writing
  // their static limits. Do not include volatile 3500..3502/350A..350D in
  // this readback-verified table: the sensor changes them after stream-on.
  71:value=24'h350300; 72:value=24'h340601; 73:value=24'h310303;
  default:value=24'h503d00;
 endcase
endmodule
