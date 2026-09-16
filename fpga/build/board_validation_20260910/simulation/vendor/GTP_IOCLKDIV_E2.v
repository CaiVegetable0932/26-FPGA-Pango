//////////////////////////////////////////////////////////////////////////////
//
// Copyright (c) 2016 PANGO MICROSYSTEMS, INC
// ALL RIGHTS RESERVED.
//
// THE SOURCE CODE CONTAINED HEREIN IS PROPRIETARY TO PANGO MICROSYSTEMS, INC.
// IT SHALL NOT BE REPRODUCED OR DISCLOSED IN WHOLE OR IN PART OR USED BY
// PARTIES WITHOUT WRITTEN AUTHORIZATION FROM THE OWNER.
//
//////////////////////////////////////////////////////////////////////////////
//
// Library: General technology primitive
// Filename: GTP_IOCLKDIV_E2.v
//
// Functional description:
//
// Parameter description: DIV_FACTOR
//
// Port description:
//
// Revision:
//////////////////////////////////////////////////////////////////////////////

`timescale 1 ns / 1 ps

module GTP_IOCLKDIV_E2
#(
    parameter DIV_FACTOR = "BYPASS" //1, 2, 3, 4, 5, 6, 7, 8, BYPASS
) (
    output CLKDIVOUT,
    input CLKIN,
    input RST_N,
    input CE
);

//synthesis translate_off

    initial begin
        if (DIV_FACTOR != "BYPASS" && DIV_FACTOR != "1" && DIV_FACTOR != "2" && DIV_FACTOR != "3" && DIV_FACTOR != "4" && DIV_FACTOR != "5" && DIV_FACTOR != "6" && DIV_FACTOR != "7" && DIV_FACTOR != "8") begin
            $display("ERROR: The attribute DIV_FACTOR on instance %m is %s. Legal values are BYPASS or 1 or 2 or 3 or 4 or 5 or 6 or 7 or 8.", DIV_FACTOR);
            $finish;
        end
    end

    reg [3:0] div_mode;
    initial
    begin
        if(DIV_FACTOR == "BYPASS")
            div_mode=4'h0;
        else if(DIV_FACTOR == "1")
            div_mode=4'h1;
        else if(DIV_FACTOR == "2")
            div_mode=4'h2;
        else if(DIV_FACTOR == "3")
            div_mode=4'h3;
        else if(DIV_FACTOR == "4")
            div_mode=4'h4;
        else if(DIV_FACTOR == "5")
            div_mode=4'h5;
        else if(DIV_FACTOR == "6")
            div_mode=4'h6;
        else if(DIV_FACTOR == "7")
            div_mode=4'h7;
        else if(DIV_FACTOR == "8")
            div_mode=4'h8;
        else 
            div_mode=4'hx;
    end

    wire [3:0] idivider;
    wire div1;
    wire [3:0] duty_ctrl;
    wire clk_out_div;
    wire clk_out_mode;
    wire rst_n;
    reg rstn_idiv;
    reg [3:0] counter;
    reg clkdivr;
    reg div1_en;
    wire clk_in_div;
    
    assign idivider = div_mode;
    assign div1 = (idivider == 4'h1)?1:0;
    assign duty_ctrl = (idivider[0] == 1)?(idivider-1)>>1:idivider>>1;
    assign clk_out_div = (div1_en==1'b1)? clk_in_div:clkdivr;
    assign clk_out_mode = (idivider == 4'h0)? CLKIN:clk_out_div;
    assign CLKDIVOUT = clk_out_mode;
    assign rst_n = RST_N;
    assign clk_in_div  = CLKIN & CE;

    always @(posedge clk_in_div or negedge rst_n)
    begin
        if(!rst_n)
            rstn_idiv <= 1'b0;
        else
            rstn_idiv <= 1'b1;
    end 

    always @(posedge clk_in_div or negedge rstn_idiv)
    begin
        if(!rstn_idiv)
            counter <= 4'h0;
        else
        begin
            if(counter == idivider-1)
                counter <= 4'h0;
            else
                counter <= counter+1;
        end
    end

    always @(posedge clk_in_div or negedge rstn_idiv)
    begin
        if(!rstn_idiv)
            clkdivr <= 0;
        else
        begin
            if(counter < duty_ctrl)
                clkdivr <= 1;
            else 
                clkdivr <= 0;
        end
    end

    always @(posedge clk_in_div or negedge rstn_idiv)
    begin
        if(!rstn_idiv)
            div1_en <= 1'b0;
        else
        begin
            if(div1)
                div1_en <= 1'b1;
            else
                div1_en <= 1'b0;
        end
    end

      
//synthesis translate_on
endmodule
