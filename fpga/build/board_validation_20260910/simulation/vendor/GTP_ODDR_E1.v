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
// Filename: GTP_ODDR_E1.v
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

module GTP_ODDR_E1 #(
    parameter ODDR_MODE = "SAME_EDGE",     //"OPPOSITE_EDGE"; "SAME_EDGE";
    parameter GRS_EN    = "TRUE",          //"TRUE"; "FALSE"
    parameter RS_TYPE   = "ASYNC_RESET"    //"ASYNC_RESET"; "ASYNC_SET"; "SYNC_RESET"; "SYNC_SET" 
)(
    output  Q,
    input   D0,
    input   D1,
    input   CLK,
    input   CE,
    input   RS
);
//synthesis translate_off
reg ce;
reg do_pos;
reg do_neg;
reg pos_d0;
reg pos_d1;
reg neg_d1;
reg tmp_d1;


wire setn;
wire resetn;
wire global_rstn;
wire lasync_rstn;
wire lasync_setn;
wire lsync_rstn;
wire lsync_setn;


initial begin
    if(GRS_EN != "TRUE" && GRS_EN != "FALSE")
    begin $display("Error: Illegal setting GRS_EN of %s",GRS_EN);$finish;end

    if(ODDR_MODE != "OPPOSITE_EDGE" && ODDR_MODE != "SAME_EDGE")
    begin $display("Error: Illegal setting ODDR_MODE of %s",ODDR_MODE);$finish;end

    if(RS_TYPE != "ASYNC_RESET" && RS_TYPE != "ASYNC_SET" && RS_TYPE != "SYNC_RESET" && RS_TYPE != "SYNC_SET")
    begin $display("Error: Illegal setting RS_TYPE of %s",RS_TYPE);$finish;end
end


initial begin
    do_pos  = 0;  
    do_neg  = 0;  
    pos_d0  = 0;
    pos_d1  = 0;
    neg_d1  = 0;
end

assign global_rstn = (GRS_EN == "TRUE") ? GRS_INST.GRSNET : 1'b1;
assign lasync_rstn = (RS_TYPE == "ASYNC_RESET") ? (~RS) : 1'b1;
assign lasync_setn = (RS_TYPE == "ASYNC_SET")   ? (~RS) : 1'b1;
assign lsync_rst   = (RS_TYPE == "SYNC_RESET")  ? RS : 1'b0;
assign lsync_set   = (RS_TYPE == "SYNC_SET")    ? RS : 1'b0;


always @(posedge CLK or negedge global_rstn or negedge lasync_rstn or negedge lasync_setn) begin
    if (!global_rstn) begin
        do_neg <= 1'b0;
        pos_d0 <= 1'b0;
        pos_d1 <= 1'b0;
    end
    else if (!lasync_rstn) begin
        do_neg <= 1'b0;
        pos_d0 <= 1'b0;
        pos_d1 <= 1'b0;
    end
    else if (!lasync_setn) begin
        do_neg <= 1'b1;
        pos_d0 <= 1'b1;
        pos_d1 <= 1'b1;
    end
    else if (lsync_rst) begin
        do_neg <= 1'b0;
        pos_d0 <= 1'b0;
        pos_d1 <= 1'b0;
    end
    else if (lsync_set) begin
        do_neg <= 1'b1;
        pos_d0 <= 1'b1;
        pos_d1 <= 1'b1;
    end
    else if(CE) begin
        do_neg <= tmp_d1;
        pos_d0 <= D0;
        pos_d1 <= D1;
    end
    else begin
        do_neg <= do_neg;
        pos_d0 <= pos_d0;
        pos_d1 <= pos_d1;
    end
end

always @(negedge CLK or negedge global_rstn or negedge lasync_rstn or negedge lasync_setn) begin
    if (!global_rstn) begin
        neg_d1 <= 1'b0;
        do_pos <= 1'b0;
    end
    else if (!lasync_rstn) begin
        neg_d1 <= 1'b0;
        do_pos <= 1'b0;
    end
    else if (!lasync_setn) begin
        neg_d1 <= 1'b1;
        do_pos <= 1'b1;
    end
    else if (lsync_rst) begin
        neg_d1 <= 1'b0;
        do_pos <= 1'b0;
    end
    else if (lsync_set) begin
        neg_d1 <= 1'b1;
        do_pos <= 1'b1;
    end
    else if(CE) begin
        neg_d1 <= D1;
        do_pos <= pos_d0;
    end
    else begin
        neg_d1 <= neg_d1;
        do_pos <= do_pos;
    end
end

always @(*) begin
    case (ODDR_MODE)
        "SAME_EDGE" : begin
            tmp_d1 = pos_d1;
            end
        "OPPOSITE_EDGE" : begin
            tmp_d1 = neg_d1;
            end
        default : begin
            tmp_d1 = 1'bx;
            end
    endcase
end

always @(*) begin
    if(!CLK)
        ce = CE;
    else
        ce = ce;
end

assign Q = (CLK & ce) ? do_pos : do_neg;      
//synthesis translate_on

endmodule
