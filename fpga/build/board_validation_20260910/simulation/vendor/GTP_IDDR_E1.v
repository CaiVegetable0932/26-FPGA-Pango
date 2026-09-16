//////////////////////////////////////////////////////////////////////////////
//
// Copyright (c) 2014 PANGO MICROSYSTEMS, INC
// ALL RIGHTS RESERVED.
//
// THE SOURCE CODE CONTAINED HEREIN IS PROPRIETARY TO PANGO MICROSYSTEMS, INC.
// IT SHALL NOT BE REPRODUCED OR DISCLOSED IN WHOLE OR IN PART OR USED BY
// PARTIES WITHOUT WRITTEN AUTHORIZATION FROM THE OWNER.
//
//////////////////////////////////////////////////////////////////////////////
//
// Library: General technology primitive
// Filename: GTP_IDDR_E1.v
//
// Functional description:
//
// Parameter description:
//
// Port description:
//
// Revision:
// 2020/09/09 create by xqlin
//
//////////////////////////////////////////////////////////////////////////////

`timescale 1 ns / 1 ps

module GTP_IDDR_E1 #(
    parameter GRS_EN     = "TRUE",          //"TRUE"; "FALSE"
    parameter IDDR_MODE  = "OPPOSITE_EDGE", //"OPPOSITE_EDGE"; "SAME_EDGE"; "SAME_PIPELINED"
    parameter RS_TYPE    = "ASYNC_RESET"    //"ASYNC_RESET"; "ASYNC_SET"; "SYNC_RESET"; "SYNC_SET" 
)(
    output  Q0,
    output  Q1,
    input   D,
    input   CLK,
    input   CE,
    input   RS
);
//synthesis translate_off
reg di_pos;
reg di_neg;
reg syn_pos;
reg syn_neg;
reg [1:0] q_mode;

wire setn;
wire resetn;
wire syn_pos_w;
wire syn_neg_w;
wire global_rstn;
wire lasync_rstn;
wire lasync_setn;
wire lsync_rstn;
wire lsync_setn;

initial begin
    if(GRS_EN != "TRUE" && GRS_EN != "FALSE")
    begin $display("Error: Illegal setting GRS_EN of %s",GRS_EN);$finish;end

    if(IDDR_MODE != "OPPOSITE_EDGE" && IDDR_MODE != "SAME_EDGE" && IDDR_MODE != "SAME_PIPELINED")
    begin $display("Error: Illegal setting IDDR_MODE of %s",IDDR_MODE);$finish;end

    if(RS_TYPE != "ASYNC_RESET" && RS_TYPE != "ASYNC_SET" && RS_TYPE != "SYNC_RESET" && RS_TYPE != "SYNC_SET")
    begin $display("Error: Illegal setting RS_TYPE of %s",RS_TYPE);$finish;end
end

initial begin
    di_pos   = 0;  
    di_neg   = 0;  
    syn_pos  = 0;
    syn_neg  = 0;
end

assign global_rstn = (GRS_EN == "TRUE") ? GRS_INST.GRSNET : 1'b1;
assign lasync_rstn = (RS_TYPE == "ASYNC_RESET") ? (~RS) : 1'b1;
assign lasync_setn = (RS_TYPE == "ASYNC_SET")   ? (~RS) : 1'b1;
assign lsync_rst   = (RS_TYPE == "SYNC_RESET")  ? RS : 1'b0;
assign lsync_set   = (RS_TYPE == "SYNC_SET")    ? RS : 1'b0;


always @(posedge CLK or negedge global_rstn or negedge lasync_rstn or negedge lasync_setn) begin
    if (!global_rstn) begin
        di_pos  <= 1'b0;
        syn_pos <= 1'b0;
        syn_neg <= 1'b0;
    end
    else if (!lasync_rstn) begin
        di_pos  <= 1'b0;
        syn_pos <= 1'b0;
        syn_neg <= 1'b0;
    end
    else if (!lasync_setn) begin
        di_pos  <= 1'b1;
        syn_pos <= 1'b1;
        syn_neg <= 1'b1;
    end
    else if (lsync_rst) begin
        di_pos  <= 1'b0;
        syn_pos <= 1'b0;
        syn_neg <= 1'b0;
    end
    else if (lsync_set) begin
        di_pos  <= 1'b1;
        syn_pos <= 1'b1;
        syn_neg <= 1'b1;
    end
    else if(CE) begin
        di_pos  <= D;
        syn_pos <= di_pos;
        syn_neg <= di_neg;
    end
    else begin
        di_pos  <= di_pos;
        syn_pos <= syn_pos;
        syn_neg <= syn_neg;
    end
end

always @(negedge CLK or negedge global_rstn or negedge lasync_rstn or negedge lasync_setn) begin
    if (!global_rstn) 
        di_neg  <= 1'b0;
    else if (!lasync_rstn) 
        di_neg  <= 1'b0;
    else if (!lasync_setn) 
        di_neg  <= 1'b1;
    else if (lsync_rst)
        di_neg  <= 1'b0;
    else if (lsync_set)
        di_neg  <= 1'b1;
    else if(CE) 
        di_neg  <= D;
    else
        di_neg  <= di_neg;
end

assign #0.001 {syn_neg_w,syn_pos_w} = {syn_neg,syn_pos};

always @(*) begin
    case (IDDR_MODE)
        "OPPOSITE_EDGE" : q_mode = {di_neg,di_pos};
        "SAME_EDGE"     : q_mode = {syn_neg_w,di_pos};
        "SAME_PIPELINED": q_mode = {syn_neg_w,syn_pos_w};
        default: q_mode = 2'b00; 
    endcase
end

assign Q0 = q_mode[0];      
assign Q1 = q_mode[1];      
//synthesis translate_on

endmodule
