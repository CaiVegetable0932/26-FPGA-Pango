// Purpose: portable encoder-only elaboration placeholder. No serial behavior
// is simulated; actual bit order requires the licensed native PDS models.
// This file must never be added to a synthesis or native-serializer project.
`ifdef HDMI_ENCODER_ONLY
module tmds_serializer(input pixel_clk,serial_clk,reset,input [9:0] symbol,
 output data_p,data_n);
 assign data_p=1'b0;assign data_n=1'b1;
endmodule
`endif
