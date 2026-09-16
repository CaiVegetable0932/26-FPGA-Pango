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
// Filename: GTP_OSERDES_E2.v
//
// Functional description:
//
// Parameter description:
//
// Port description:
//
// Revision:
//////////////////////////////////////////////////////////////////////////////
`timescale 1ps / 1ps

module GTP_OSERDES_E2 #(
	parameter         GRS_EN          =  "TRUE",        // "TRUE","FALSE"   
	parameter         OSERDES_MODE    =  "SDR4TO1",     // "SDR2TO1","SDR3TO1","SDR4TO1","SDR5TO1","SDR6TO1","SDR7TO1","SDR8TO1",
                                                        // "DDR2TO1_SAME_EDGE","DDR2TO1_OPPOSITE_EDGE",
                                                        // "DDR4TO1","DDR8TO1","DDR10TO1","DDR14TO1",
                                                        // "HMSDR4TO1","HMSDR8TO1","OLATCH","ODFF",
                                                        
	parameter         TSERDES_EN      =  "FALSE",     // "FALSE","TRUE"
	parameter         UPD0_SHIFT_EN   =  "FALSE",     // "FALSE","TRUE"
	parameter         UPD1_SHIFT_EN   =  "FALSE",     // "FALSE","TRUE"
	parameter [1:0]   INIT_SET        =  2'b00,         // 2'b00,2'b01,2'b10,2'b11
	parameter         GRS_TYPE_DQ     =  "RESET",       // "RESET" "SET"
	parameter         LRS_TYPE_DQ0    =  "ASYNC_RESET", // ASYNC_SET  ASYNC_RESET  SYNC_SET SYNC_RESET  
	parameter         LRS_TYPE_DQ1    =  "ASYNC_RESET", // ASYNC_SET  ASYNC_RESET  SYNC_SET SYNC_RESET
	parameter         LRS_TYPE_DQ2    =  "ASYNC_RESET", // ASYNC_SET  ASYNC_RESET  SYNC_SET SYNC_RESET
	parameter         LRS_TYPE_DQ3    =  "ASYNC_RESET", // ASYNC_SET  ASYNC_RESET  SYNC_SET SYNC_RESET
	parameter         GRS_TYPE_TQ     =  "RESET",       // "RESET" "SET"
	parameter         LRS_TYPE_TQ0    =  "ASYNC_RESET", // ASYNC_SET  ASYNC_RESET  SYNC_SET SYNC_RESET    
	parameter         LRS_TYPE_TQ1    =  "ASYNC_RESET", // ASYNC_SET  ASYNC_RESET  SYNC_SET SYNC_RESET
	parameter         LRS_TYPE_TQ2    =  "ASYNC_RESET", // ASYNC_SET  ASYNC_RESET  SYNC_SET SYNC_RESET
	parameter         LRS_TYPE_TQ3    =  "ASYNC_RESET", // ASYNC_SET  ASYNC_RESET  SYNC_SET SYNC_RESET
	parameter         TRI_EN          =  "FALSE",     // "FALSE","TRUE"
	parameter         TBYTE_EN        =  "FALSE",     // "FALSE","TRUE"
	parameter         MIPI_EN         =  "FALSE",     // "FALSE","TRUE"
	parameter         OCASCADE_EN     =  "FALSE",     // "FALSE","TRUE"

/**************************************************************************/
    parameter         HPIO            =  "FALSE",   //

    parameter         ODELAY_EN         =  "FALSE",   //
    parameter         TDELAY_EN         =  "FALSE",   //

    parameter         TSERDES_MODE    =  "SDR4TO1", // "SDR2TO1","SDR4TO1","SDR8TO1","TLATCH","TDFF","DDR2TO1_SAME_EDGE","DDR2TO1_OPPOSITE_EDGE","DDR4TO1","DDR8TO1","HMSDR4TO1","HMSDR8TO1"
    parameter         TUPD0_SHIFT_EN  =  "FALSE",   // "FALSE","TRUE"
    parameter         TUPD1_SHIFT_EN  =  "FALSE",   // "FALSE","TRUE"
    parameter         TINIT_SET       =  2'b00  ,   //2'b00,2'b01,2'b10,2'b11
//    parameter         TSERDES_EN      =  "FALSE" ,  //
    parameter         TERMBYTE_EN     =  "FALSE" ,  //
    parameter         TERM_EN         =  "FALSE" ,  //
    parameter         TERM_OFF_SET    =  2'b00  ,   //2'b00,2'b01,2'b10,2'b11
    parameter         TERM_ON_SET     =  2'b00      //2'b00,2'b01,2'b10,2'b11

/**************************************************************************/
)(
    //input         GRS_N,
    input         RST,
    input         OCE,
    input         TCE,
    input         OCLKDIV,
    //input         OCLKDIVB,
    input         SERCLK,
    //input         SERCLKB,
    input         OCLK,
    //input         OCLKB,
    input         MIPI_CTRL,
    input         UPD0_SHIFT,
    input         UPD1_SHIFT,
    input         OSHIFTIN0,
    input         OSHIFTIN1,
    input [7:0]   DI,
    input [7:0]   TI,             //modify, 8 bit
    input         TBYTE_IN,
    output        OSHIFTOUT0,
    output        OSHIFTOUT1,
    output        TQ,
    output        DO,
    output        TFB,
    output        TERM_FB

);

wire         osr_iolhr;
wire         osr_iolhp; //add
wire         gwen;
wire         glogen;
wire         grs_n;
wire         oce;
wire         tce;
wire         oclkdiv;
wire         oclkdivb;
wire         serclk;
wire         serclkb;
wire         oclk;
wire         oclkb;
wire         mipi_sw_dyn_i;
wire         inbuf_dyn_dis_n_i;
wire         upd0_shift;
wire         upd1_shift;
wire         do_cas_in;
wire         oshiftin0;
wire         oshiftin1;
wire [7:0]   tx_data;
wire [7:0]   ts_ctrl;   //modfiy, 8bit
wire         tbyte_in;
wire         termbyte_in;      
wire         to_cas_in;
wire         term_cas_in;
wire         dly_odly_in;
wire         oshiftout0;
wire         oshiftout1;
wire         do_p;
wire         to;
wire         tfb;
wire         term_fb;
///////////////////////////////////////////// sc --> cp /////////////
reg  [3:0]   sc_oserdes_mode;
wire         sc_osr_pol;
wire         sc_sro_en;
wire         sc_srt_en;
//wire         sc_t_sync;
wire         sc_grs_dis;
wire         sc_clk_pol4;
wire         sc_clk_pol5;
wire         sc_clk_pol6;
wire         sc_upd0_shiften;
wire         sc_upd1_shiften;
wire [1:0]   sc_init_set;
wire         sc_tbyte_en;
wire         sc_mipi_en;
wire         sc_pdiff;
wire         sc_do_sel;       //used in mipi application
wire         sc_ocascade_en;
wire         sc_tri_en;
wire         sc_odly_en;
//wire [1:0]   sc_dqmode;

reg  [1:0]   sc_dqmode;
reg  [1:0]   sc_tqmode;
reg          sc_o_sync;
reg          sc_t_sync;
reg          sc_init_dq;
reg          sc_init_tq;
reg  [3:0]   sc_srval_dq;
reg  [3:0]   sc_srval_tq;
reg          sc_oserdes_en;
reg          sc_ser_ddren;
reg          sc_ser_sdren;
reg          sc_ohsmem_en;
reg          sc_opposite_en;
reg          sc_olthen;
reg          sc_odffen;

/********************************/

wire [3:0]   sc_term_offset;
wire [1:0]   sc_termmode;
wire sc_tser_upd0_shiften;
wire sc_tser_upd1_shiften;
wire [1:0]   sc_tser_init_set;
wire sc_tdly_en;
wire sc_termbyte_en;

reg sc_tserdes_en;
reg sc_thsmem_en;
reg sc_tser_ddren;
reg sc_tser_sdren;
reg sc_tlthen;
reg sc_tdffen;
reg [1:0] sc_tserdes_mode;

/********************************/


// parameter
assign  sc_osr_pol       =  1'b0;
assign  sc_sro_en		 =  1'b1;
assign  sc_srt_en		 =  1'b1;
//assign  sc_t_sync		 =  1'b0;
assign  sc_grs_dis		 = (GRS_EN=="TRUE")    ? 1'b0 : 1'b1;
assign  sc_clk_pol4		 =  1'b0;
assign  sc_clk_pol5		 =  1'b0;
assign  sc_clk_pol6		 =  1'b0;
assign  sc_upd0_shiften	 = (UPD0_SHIFT_EN=="FALSE") ? 1'b0 : 1'b1;
assign  sc_upd1_shiften	 = (UPD1_SHIFT_EN=="FALSE") ? 1'b0 : 1'b1;
assign  sc_init_set		 =  INIT_SET;
assign  sc_tbyte_en		 = (TBYTE_EN    =="FALSE") ? 1'b0 : 1'b1;
assign  sc_mipi_en		 = (MIPI_EN     =="FALSE") ? 1'b0 : 1'b1;
assign  sc_pdiff		 =  1'b0;
assign  sc_do_sel		 =  1'b0;       //used in mipi application
assign  sc_ocascade_en	 = (OCASCADE_EN =="FALSE") ? 1'b0 : 1'b1;
assign  sc_tri_en   	 = (TRI_EN =="FALSE") ? 1'b0 : 1'b1;

assign  sc_odly_en		 = 1'b0;
//assign  sc_odly_en		 = (ODELAY_EN=="TRUE")? 1'b1 : 1'b0;

//assign  sc_dqmode	     = sc_mipi_en ? 2'b00 : sc_dqmode;



// input
assign  gwen             = 1'b1;
assign  glogen           = 1'b1;
assign  grs_n            = (GRS_EN == "TRUE") ? GRS_INST.GRSNET : 1'b1;
//assign  grs_n            =  1'b1;
//assign  grs_n            =  GRS_N;

assign  osr_iolhr	      = RST;

assign  osr_iolhp	      = RST;//add

assign  oce		          = OCE;
assign  tce		          = TCE;
assign  oclkdiv		      = OCLKDIV;
assign  oclkdivb	      = ~OCLKDIV;
assign  serclk		      = SERCLK;
assign  serclkb		      = ~SERCLK;
assign  oclk		      = OCLK;
assign  oclkb		      = ~OCLK;
assign  mipi_sw_dyn_i     = MIPI_CTRL;
assign  inbuf_dyn_dis_n_i = 1'b0;
assign  upd0_shift		  = UPD0_SHIFT;
assign  upd1_shift		  = UPD1_SHIFT;
assign  do_cas_in		  = 1'b0;
assign  oshiftin0		  = OSHIFTIN0;
assign  oshiftin1		  = OSHIFTIN1;
assign  tx_data		      = DI;
assign  ts_ctrl		      = TI;
assign  tbyte_in		  = TBYTE_IN;
assign  termbyte_in		  = 1'b0;      
assign  to_cas_in		  = 1'b0;
assign  term_cas_in		  = 1'b0;
assign  dly_odly_in		  = 1'b0;

// output
assign  OSHIFTOUT0		  = oshiftout0;
assign  OSHIFTOUT1		  = oshiftout1;
assign  DO		          = do_p;
assign  TQ		          = to;
assign  TFB               = tfb;
assign  TERM_FB           = term_fb;

initial begin
    if(GRS_EN != "TRUE" && GRS_EN != "FALSE")
    begin $display("Error: Illegal setting GRS_EN of %s",GRS_EN);$finish;end

    if(UPD0_SHIFT_EN != "TRUE" && UPD0_SHIFT_EN != "FALSE")
    begin $display("Error: Illegal setting UPD0_SHIFT_EN of %s",UPD0_SHIFT_EN);$finish;end

    if(UPD1_SHIFT_EN != "TRUE" && UPD1_SHIFT_EN != "FALSE")
    begin $display("Error: Illegal setting UPD1_SHIFT_EN of %s",UPD1_SHIFT_EN);$finish;end

    if(INIT_SET != 2'b00 && INIT_SET != 2'b01 && INIT_SET != 2'b10 && INIT_SET != 2'b11)
    begin $display("Error: Illegal setting INIT_SET of %b",INIT_SET);$finish;end

    if(GRS_TYPE_DQ != "RESET" && GRS_TYPE_DQ != "SET")
    begin $display("Error: Illegal setting GRS_TYPE_DQ of %s",GRS_TYPE_DQ);$finish;end



    if(LRS_TYPE_DQ0 != "ASYNC_RESET" && LRS_TYPE_DQ0 != "ASYNC_SET" && LRS_TYPE_DQ0 != "SYNC_RESET" && LRS_TYPE_DQ0 != "SYNC_SET")
    begin $display("Error: Illegal setting LRS_TYPE_DQ0 of %s",LRS_TYPE_DQ0);$finish;end

    if(LRS_TYPE_DQ1 != "ASYNC_RESET" && LRS_TYPE_DQ1 != "ASYNC_SET" && LRS_TYPE_DQ1 != "SYNC_RESET" && LRS_TYPE_DQ1 != "SYNC_SET")
    begin $display("Error: Illegal setting LRS_TYPE_DQ1 of %s",LRS_TYPE_DQ1);$finish;end

    if(LRS_TYPE_DQ2 != "ASYNC_RESET" && LRS_TYPE_DQ2 != "ASYNC_SET" && LRS_TYPE_DQ2 != "SYNC_RESET" && LRS_TYPE_DQ2 != "SYNC_SET")
    begin $display("Error: Illegal setting LRS_TYPE_DQ2 of %s",LRS_TYPE_DQ2);$finish;end

    if(LRS_TYPE_DQ3 != "ASYNC_RESET" && LRS_TYPE_DQ3 != "ASYNC_SET" && LRS_TYPE_DQ3 != "SYNC_RESET" && LRS_TYPE_DQ3 != "SYNC_SET")
    begin $display("Error: Illegal setting LRS_TYPE_DQ3 of %s",LRS_TYPE_DQ3);$finish;end



    if(GRS_TYPE_TQ != "RESET" && GRS_TYPE_TQ != "SET")
    begin $display("Error: Illegal setting GRS_TYPE_TQ of %s",GRS_TYPE_TQ);$finish;end



    if(LRS_TYPE_TQ0 != "ASYNC_RESET" && LRS_TYPE_TQ0 != "ASYNC_SET" && LRS_TYPE_TQ0 != "SYNC_RESET" && LRS_TYPE_TQ0 != "SYNC_SET")
    begin $display("Error: Illegal setting LRS_TYPE_TQ0 of %s",LRS_TYPE_TQ0);$finish;end

    if(LRS_TYPE_TQ1 != "ASYNC_RESET" && LRS_TYPE_TQ1 != "ASYNC_SET" && LRS_TYPE_TQ1 != "SYNC_RESET" && LRS_TYPE_TQ1 != "SYNC_SET")
    begin $display("Error: Illegal setting LRS_TYPE_TQ1 of %s",LRS_TYPE_TQ1);$finish;end

    if(LRS_TYPE_TQ2 != "ASYNC_RESET" && LRS_TYPE_TQ2 != "ASYNC_SET" && LRS_TYPE_TQ2 != "SYNC_RESET" && LRS_TYPE_TQ2 != "SYNC_SET")
    begin $display("Error: Illegal setting LRS_TYPE_TQ2 of %s",LRS_TYPE_TQ2);$finish;end

    if(LRS_TYPE_TQ3 != "ASYNC_RESET" && LRS_TYPE_TQ3 != "ASYNC_SET" && LRS_TYPE_TQ3 != "SYNC_RESET" && LRS_TYPE_TQ3 != "SYNC_SET")
    begin $display("Error: Illegal setting LRS_TYPE_TQ3 of %s",LRS_TYPE_TQ3);$finish;end



    if((LRS_TYPE_DQ0 == "ASYNC_RESET" || LRS_TYPE_DQ0 == "ASYNC_SET" || LRS_TYPE_DQ1 == "ASYNC_RESET" || LRS_TYPE_DQ1 == "ASYNC_SET" 
        || LRS_TYPE_DQ2 == "ASYNC_RESET" || LRS_TYPE_DQ2 == "ASYNC_SET" || LRS_TYPE_DQ3 == "ASYNC_RESET" || LRS_TYPE_DQ3 == "ASYNC_SET") 
        && (LRS_TYPE_DQ0 == "SYNC_RESET" || LRS_TYPE_DQ0 == "SYNC_SET" || LRS_TYPE_DQ1 == "SYNC_RESET" || LRS_TYPE_DQ1 == "SYNC_SET" 
        ||  LRS_TYPE_DQ2 == "SYNC_RESET" || LRS_TYPE_DQ2 == "SYNC_SET" || LRS_TYPE_DQ3 == "SYNC_RESET" || LRS_TYPE_DQ3 == "SYNC_SET"))
    begin $display("Error: LRS_TYPE_DQx must be all of ASYNC_ or SYNC_.");$finish;end


    if((LRS_TYPE_TQ0 == "ASYNC_RESET" || LRS_TYPE_TQ0 == "ASYNC_SET" || LRS_TYPE_TQ1 == "ASYNC_RESET" || LRS_TYPE_TQ1 == "ASYNC_SET" 
        || LRS_TYPE_TQ2 == "ASYNC_RESET" || LRS_TYPE_TQ2 == "ASYNC_SET" || LRS_TYPE_TQ3 == "ASYNC_RESET" || LRS_TYPE_TQ3 == "ASYNC_SET") 
        && (LRS_TYPE_TQ0 == "SYNC_RESET" || LRS_TYPE_TQ0 == "SYNC_SET" || LRS_TYPE_TQ1 == "SYNC_RESET" || LRS_TYPE_TQ1 == "SYNC_SET" 
        ||  LRS_TYPE_TQ2 == "SYNC_RESET" || LRS_TYPE_TQ2 == "SYNC_SET" || LRS_TYPE_TQ3 == "SYNC_RESET" || LRS_TYPE_TQ3 == "SYNC_SET"))
    begin $display("Error: LRS_TYPE_TQx must be all of ASYNC_ or SYNC_.");$finish;end



    if(TBYTE_EN != "TRUE" && TBYTE_EN != "FALSE")
    begin $display("Error: Illegal setting TBYTE_EN of %s",TBYTE_EN);$finish;end

    if(MIPI_EN != "TRUE" && MIPI_EN != "FALSE")
    begin $display("Error: Illegal setting MIPI_EN of %s",MIPI_EN);$finish;end

    if(OCASCADE_EN != "TRUE" && OCASCADE_EN != "FALSE")
    begin $display("Error: Illegal setting OCASCADE_EN of %s",OCASCADE_EN);$finish;end

    if(TRI_EN != "TRUE" && TRI_EN != "FALSE")
    begin $display("Error: Illegal setting TRI_EN of %s",TRI_EN);$finish;end

    if((TSERDES_EN == "TRUE")) begin
        if(OSERDES_MODE == "SDR2TO1" || OSERDES_MODE == "SDR4TO1" || OSERDES_MODE == "SDR8TO1" 
            || OSERDES_MODE == "DDR4TO1" || OSERDES_MODE == "DDR8TO1" 
            || OSERDES_MODE == "HMSDR4TO1" || OSERDES_MODE == "HMSDR8TO1")
            ;
        else begin $display("Error: Illegal setting OSERDES_MODE of %s when TSERDES_EN == TRUE",OSERDES_MODE);$finish;end
    end
end


// sc_oserdes_mode
initial begin
// default value
    sc_oserdes_mode = 4'b0000;
    sc_dqmode	= 2'b00;
    sc_tqmode       = 2'b00;
    sc_oserdes_en   = 1'b0;
    sc_ser_sdren    = 1'b0;
    sc_ser_ddren    = 1'b0;
    sc_ohsmem_en    = 1'b0;
    sc_opposite_en  = 1'b0;
    sc_olthen       = 1'b0;
    sc_odffen       = 1'b0;
//
    case (OSERDES_MODE)
// SDR
        "SDR2TO1" :begin
                    sc_oserdes_mode = 4'b0101;
                    sc_dqmode	= 2'b01;
                    sc_tqmode       = 2'b01;
                    sc_oserdes_en   = 1'b1;
                    sc_ser_sdren    = 1'b1;
                   end 
        "SDR3TO1" :begin
                    sc_oserdes_mode = 4'b0110;
                    sc_dqmode	= 2'b01;
                    sc_tqmode       = 2'b01;
                    sc_oserdes_en   = 1'b1;
                    sc_ser_sdren    = 1'b1;
                   end 
        "SDR4TO1" :begin
                    sc_oserdes_mode = 4'b0000;
                    sc_dqmode	= 2'b01;
                    sc_tqmode       = 2'b01;
                    sc_oserdes_en   = 1'b1;
                    sc_ser_sdren    = 1'b1;
                   end 
        "SDR5TO1" :begin
                    sc_oserdes_mode = 4'b0011;
                    sc_dqmode	= 2'b01;
                    sc_tqmode       = 2'b01;
                    sc_oserdes_en   = 1'b1;
                    sc_ser_sdren    = 1'b1;
                   end 
        "SDR6TO1" :begin
                    sc_oserdes_mode = 4'b1000;
                    sc_dqmode	= 2'b01;
                    sc_tqmode       = 2'b01;
                    sc_oserdes_en   = 1'b1;
                    sc_ser_sdren    = 1'b1;
                   end 
        "SDR7TO1" :begin
                    sc_oserdes_mode = 4'b0010;
                    sc_dqmode	= 2'b01;
                    sc_tqmode       = 2'b01;
                    sc_oserdes_en   = 1'b1;
                    sc_ser_sdren    = 1'b1;
                   end 
        "SDR8TO1" :begin
                    sc_oserdes_mode = 4'b0001;
                    sc_dqmode	= 2'b01;
                    sc_tqmode       = 2'b01;
                    sc_oserdes_en   = 1'b1;
                    sc_ser_sdren    = 1'b1;
                   end 
// DDR  
        "OLATCH" :begin
                    sc_dqmode	= 2'b01;
                    sc_tqmode       = 2'b01;
                    sc_oserdes_en   = 1'b0;
                    sc_olthen       = 1'b1;
                   end 
        "ODFF" :begin
                    sc_dqmode	= 2'b01;
                    sc_tqmode       = 2'b01;
                    sc_oserdes_en   = 1'b0;
                    sc_odffen       = 1'b1;
                   end 
        "DDR2TO1_SAME_EDGE" :begin
                    sc_oserdes_en   = 1'b0;
                    sc_dqmode	= 2'b10;
                    sc_tqmode       = 2'b10;
                    sc_ser_ddren    = 1'b1;
                    sc_opposite_en  = 1'b0;
                   end 
        "DDR2TO1_OPPOSITE_EDGE" :begin
                    sc_oserdes_en   = 1'b0;
                    sc_dqmode	= 2'b10;
                    sc_tqmode       = 2'b10;
                    sc_ser_ddren    = 1'b1;
                    sc_opposite_en  = 1'b1;
                   end 
        "DDR4TO1" :begin
                    sc_oserdes_mode = 4'b0000;
                    sc_dqmode	= 2'b10;
                    sc_tqmode       = 2'b10;
                    sc_oserdes_en   = 1'b1;
                    sc_ser_ddren    = 1'b1;
                   end 
        "DDR6TO1" :begin
                    sc_oserdes_mode = 4'b1000;
                    sc_dqmode	= 2'b10;
                    sc_tqmode       = 2'b10;
                    sc_oserdes_en   = 1'b1;
                    sc_ser_ddren    = 1'b1;
                   end 
        "DDR8TO1" :begin
                    sc_oserdes_mode = 4'b0001;
                    sc_dqmode	= 2'b10;
                    sc_tqmode       = 2'b10;
                    sc_oserdes_en   = 1'b1;
                    sc_ser_ddren    = 1'b1;
                   end 
        "DDR10TO1" :begin
                    sc_oserdes_mode = 4'b0100;
                    sc_dqmode	= 2'b10;
                    sc_tqmode       = 2'b10;
                    sc_oserdes_en   = 1'b1;
                    sc_ser_ddren    = 1'b1;
                   end 
        "DDR14TO1" :begin
                    sc_oserdes_mode = 4'b0111;
                    sc_dqmode	= 2'b10;
                    sc_tqmode       = 2'b10;
                    sc_oserdes_en   = 1'b1;
                    sc_ser_ddren    = 1'b1;
                   end 
// High Speed Memory 
//         "HMSDR2TO1" :begin
//                     sc_ser_sdren    = 1'b1;
//                     sc_ohsmem_en    = 1'b1;
//                    end 
        "HMSDR4TO1" :begin
                    sc_oserdes_mode = 4'b0000;
                    sc_dqmode	= 2'b01;
                    sc_tqmode       = 2'b01;
                    sc_oserdes_en   = 1'b1;
                    sc_ser_sdren    = 1'b1;
                    sc_ohsmem_en    = 1'b1;
                   end
        "HMSDR8TO1" :begin
                    sc_oserdes_mode = 4'b0001;
                    sc_dqmode	= 2'b01;
                    sc_tqmode       = 2'b01;
                    sc_oserdes_en   = 1'b1;
                    sc_ser_sdren    = 1'b1;
                    sc_ohsmem_en    = 1'b1;
                   end
        default:    begin 
                    sc_oserdes_mode = 4'b0000; 
                    $display("Error: Illegal setting OSERDES_MODE of %s",OSERDES_MODE);
                    $finish; 
                    end
        endcase
end

initial begin
    case (GRS_TYPE_DQ)
        "SET"  :begin sc_init_dq=1'b1; end
        "RESET":begin sc_init_dq=1'b0; end
    endcase
end

initial begin
    case (LRS_TYPE_DQ0)
        "ASYNC_SET"  :begin sc_o_sync=1'b0; sc_srval_dq[0]=1'b1; end
        "ASYNC_RESET":begin sc_o_sync=1'b0; sc_srval_dq[0]=1'b0; end
        "SYNC_SET"   :begin sc_o_sync=1'b1; sc_srval_dq[0]=1'b1; end
        "SYNC_RESET" :begin sc_o_sync=1'b1; sc_srval_dq[0]=1'b0; end
    endcase
end

initial begin
    case (LRS_TYPE_DQ1)
        "ASYNC_SET"  :begin sc_o_sync=1'b0; sc_srval_dq[1]=1'b1; end
        "ASYNC_RESET":begin sc_o_sync=1'b0; sc_srval_dq[1]=1'b0; end
        "SYNC_SET"   :begin sc_o_sync=1'b1; sc_srval_dq[1]=1'b1; end
        "SYNC_RESET" :begin sc_o_sync=1'b1; sc_srval_dq[1]=1'b0; end
    endcase
end

initial begin
    case (LRS_TYPE_DQ2)
        "ASYNC_SET"  :begin sc_o_sync=1'b0; sc_srval_dq[2]=1'b1; end
        "ASYNC_RESET":begin sc_o_sync=1'b0; sc_srval_dq[2]=1'b0; end
        "SYNC_SET"   :begin sc_o_sync=1'b1; sc_srval_dq[2]=1'b1; end
        "SYNC_RESET" :begin sc_o_sync=1'b1; sc_srval_dq[2]=1'b0; end
    endcase
end

initial begin
    case (LRS_TYPE_DQ3)
        "ASYNC_SET"  :begin sc_o_sync=1'b0; sc_srval_dq[3]=1'b1; end
        "ASYNC_RESET":begin sc_o_sync=1'b0; sc_srval_dq[3]=1'b0; end
        "SYNC_SET"   :begin sc_o_sync=1'b1; sc_srval_dq[3]=1'b1; end
        "SYNC_RESET" :begin sc_o_sync=1'b1; sc_srval_dq[3]=1'b0; end
    endcase
end

initial begin
    case (GRS_TYPE_TQ)
        "SET"  :begin sc_init_tq=1'b1; end
        "RESET":begin sc_init_tq=1'b0; end
    endcase
end

initial begin
    case (LRS_TYPE_TQ0)
        "ASYNC_SET"  :begin sc_t_sync=1'b0; sc_srval_tq[0]=1'b1; end
        "ASYNC_RESET":begin sc_t_sync=1'b0; sc_srval_tq[0]=1'b0; end
        "SYNC_SET"   :begin sc_t_sync=1'b1; sc_srval_tq[0]=1'b1; end
        "SYNC_RESET" :begin sc_t_sync=1'b1; sc_srval_tq[0]=1'b0; end
    endcase
end

initial begin
    case (LRS_TYPE_TQ1)
        "ASYNC_SET"  :begin sc_t_sync=1'b0; sc_srval_tq[1]=1'b1; end
        "ASYNC_RESET":begin sc_t_sync=1'b0; sc_srval_tq[1]=1'b0; end
        "SYNC_SET"   :begin sc_t_sync=1'b1; sc_srval_tq[1]=1'b1; end
        "SYNC_RESET" :begin sc_t_sync=1'b1; sc_srval_tq[1]=1'b0; end
    endcase
end

initial begin
    case (LRS_TYPE_TQ2)
        "ASYNC_SET"  :begin sc_t_sync=1'b0; sc_srval_tq[2]=1'b1; end
        "ASYNC_RESET":begin sc_t_sync=1'b0; sc_srval_tq[2]=1'b0; end
        "SYNC_SET"   :begin sc_t_sync=1'b1; sc_srval_tq[2]=1'b1; end
        "SYNC_RESET" :begin sc_t_sync=1'b1; sc_srval_tq[2]=1'b0; end
    endcase
end

initial begin
    case (LRS_TYPE_TQ3)
        "ASYNC_SET"  :begin sc_t_sync=1'b0; sc_srval_tq[3]=1'b1; end
        "ASYNC_RESET":begin sc_t_sync=1'b0; sc_srval_tq[3]=1'b0; end
        "SYNC_SET"   :begin sc_t_sync=1'b1; sc_srval_tq[3]=1'b1; end
        "SYNC_RESET" :begin sc_t_sync=1'b1; sc_srval_tq[3]=1'b0; end
    endcase
end


/****************************************************************************************************************/

assign  sc_term_offset[1:0]=TERM_ON_SET;
assign  sc_term_offset[3:2]=TERM_OFF_SET;
assign  sc_termmode=(TERM_EN=="TRUE")? sc_tqmode : 2'b11 ;
//assign  sc_thsmem_en=("TSERDES_EN=="TRUE")? sc_ohsmem_en : 1'b0;
assign  sc_tser_upd0_shiften=(TUPD0_SHIFT_EN=="TRUE")? 1'b1 : 1'b0;
assign  sc_tser_upd1_shiften=(TUPD1_SHIFT_EN=="TRUE")? 1'b1 : 1'b0;
assign  sc_tser_init_set=TINIT_SET;
//assign  sc_tdly_en=(TDELAY_EN=="TRUE")? 1'b1 : 1'b0;
assign  sc_tdly_en= 1'b0;

assign  sc_termbyte_en=(TERMBYTE_EN=="TRUE")? 1'b1 : 1'b0;  


initial
begin
sc_tserdes_en=1'b0;
sc_thsmem_en=1'b0;
sc_tser_ddren=1'b0;
sc_tser_sdren=1'b0;
sc_tlthen=1'b0;
sc_tdffen=1'b0;
sc_tserdes_mode=2'b00;
if(TSERDES_EN=="TRUE") begin
  case(TSERDES_MODE)
"SDR2TO1":
  begin
    sc_tserdes_en=1'b1;
    sc_tser_sdren=1'b1;
    sc_tserdes_mode=2'b10;
  end
"SDR4TO1":
  begin
    sc_tserdes_en=1'b1;
    sc_tser_sdren=1'b1;
    sc_tserdes_mode=2'b00;
  end
"SDR8TO1":
  begin
    sc_tserdes_en=1'b1;
    sc_tser_sdren=1'b1;
    sc_tserdes_mode=2'b01;
  end
"TLATCH" :
  begin
    sc_tlthen=1'b1;
  end
"TDFF":
  begin
    sc_tdffen=1'b1;
  end
"DDR2TO1_SAME_EDGE":
  begin
    sc_tser_ddren=1'b1;
    if(OSERDES_MODE!="DDR2TO1_SAME_EDGE") 
      begin    
        $display("Error: Not the same DDR2TO1_SAME_EDGE setting");
        $finish;
      end
  end
"DDR2TO1_OPPOSITE_EDGE":
  begin
    sc_tser_ddren=1'b1;
    if(OSERDES_MODE!="DDR2TO1_OPPOSITE_EDGE") 
      begin    
        $display("Error: Not the same DDR2TO1_OPPOSITE_EDGE setting");
        $finish;
      end
  end
"DDR4TO1":
  begin
    sc_tserdes_en=1'b1;
    sc_tser_ddren=1'b1;
    sc_tserdes_mode=2'b00;
  end
"DDR8TO1":
  begin
    sc_tserdes_en=1'b1;
    sc_tser_ddren=1'b1;
    sc_tserdes_mode=2'b01;
  end
"HMSDR4TO1":
  begin
    sc_tserdes_en=1'b1;
    sc_tser_sdren=1'b1;
    sc_tserdes_mode=2'b00;
    sc_thsmem_en=1'b1;
  end
"HMSDR8TO1":
  begin
    sc_tserdes_en=1'b1;
    sc_tser_sdren=1'b1;
    sc_tserdes_mode=2'b01;
    sc_thsmem_en=1'b1;
  end
  default: ;
  endcase
  end
end
/****************************************************************************************************************/

generate
if(HPIO == "FALSE") 

oserdes_e2_iolhr_ol xoserdes_e2_iolhr_ol(
               .sc_osr_pol(sc_osr_pol),
               .sc_sro_en(sc_sro_en),
               .sc_o_sync(sc_o_sync),
               .sc_srt_en(sc_srt_en),
               .sc_t_sync(sc_t_sync),
               .sc_grs_dis(sc_grs_dis),
               .sc_clk_pol4(sc_clk_pol4),
               .sc_clk_pol5(sc_clk_pol5),
               .sc_clk_pol6(sc_clk_pol6),
               .sc_opposite_en(sc_opposite_en),
               .sc_ohsmem_en(sc_ohsmem_en),
               .sc_oserdes_en(sc_oserdes_en),
               .sc_ser_ddren(sc_ser_ddren),
               .sc_ser_sdren(sc_ser_sdren),
               .sc_olthen(sc_olthen),
               .sc_odffen(sc_odffen),
               .sc_oserdes_mode(sc_oserdes_mode),
               .sc_upd0_shiften(sc_upd0_shiften),
               .sc_upd1_shiften(sc_upd1_shiften),
               .sc_init_set(sc_init_set),
               .sc_init_dq(sc_init_dq),
               .sc_srval_dq(sc_srval_dq),
               .sc_mipi_en(sc_mipi_en),
               .sc_pdiff(sc_pdiff),
               .sc_do_sel(sc_do_sel),       //used in mipi application
               .sc_ocascade_en(sc_ocascade_en),
               .sc_dqmode(sc_dqmode),
               .sc_tri_en(sc_tri_en),
               .sc_odly_en(sc_odly_en),
               .osr_iolhr(osr_iolhr),
                .gwen(gwen),
               .glogen(glogen),
               .grs_n(grs_n),
               //.por_n(por_n),
               .oce(oce),
               .tce(tce),
               .oclkdiv(oclkdiv),
               .oclkdivb(oclkdivb),
               .serclk(serclk),
               .serclkb(serclkb),
               .oclk(oclk),
               .oclkb(oclkb),
               .upd0_shift(upd0_shift),
               .upd1_shift(upd1_shift),
               .do_cas_in(do_cas_in),
               .oshiftin0(oshiftin0),
               .oshiftin1(oshiftin1),
               .tx_data(tx_data),
               .mipi_sw_dyn_i(mipi_sw_dyn_i),
               .inbuf_dyn_dis_n_i(inbuf_dyn_dis_n_i),
               .sc_srval_tq(sc_srval_tq),
               .sc_init_tq(sc_init_tq),
               .sc_tqmode(sc_tqmode),
               .sc_tbyte_en(sc_tbyte_en),
               .ts_ctrl(ts_ctrl),
               .tbyte_in(tbyte_in),
               .termbyte_in(termbyte_in),      
               .to_cas_in(to_cas_in),
               .term_cas_in(term_cas_in),
               .dly_odly_in(dly_odly_in),
               .term(),
               .tfb(tfb),
               .term_fb(term_fb),
               .to_cas_out(),
               .term_cas_out(),
               .oshiftout0(oshiftout0),
               .oshiftout1(oshiftout1),
               .do_p(do_p),
               .do_n(),
               .to(to),
               .do_cas_out(),
               .ofb(),
               .mipi_sw_dyn_o(),
               .inbuf_dyn_dis_n_o()
              );

else              

oserdes_e2_iolhp_ol xoserdes_e2_xiolhp_ol(
               .sc_osr_pol(sc_osr_pol),
               .sc_sro_en(sc_sro_en),
               .sc_o_sync(sc_o_sync),
               .sc_srt_en(sc_srt_en),
               .sc_t_sync(sc_t_sync),
               .sc_grs_dis(sc_grs_dis),
               .sc_clk_pol4(sc_clk_pol4),
               .sc_clk_pol5(sc_clk_pol5),
               .sc_clk_pol6(sc_clk_pol6),
               .sc_opposite_en(sc_opposite_en),
               .sc_ohsmem_en(sc_ohsmem_en),
               .sc_oserdes_en(sc_oserdes_en),
               .sc_ser_ddren(sc_ser_ddren),
               .sc_ser_sdren(sc_ser_sdren),
               .sc_olthen(sc_olthen),
               .sc_odffen(sc_odffen),
               .sc_oserdes_mode(sc_oserdes_mode),
               .sc_upd0_shiften(sc_upd0_shiften),
               .sc_upd1_shiften(sc_upd1_shiften),
               .sc_init_set(sc_init_set),
               .sc_init_dq(sc_init_dq),
               .sc_srval_dq(sc_srval_dq),
               .sc_mipi_en(sc_mipi_en),
               .sc_pdiff(sc_pdiff),
               .sc_do_sel(sc_do_sel),       //used in mipi application
               .sc_ocascade_en(sc_ocascade_en),
               .sc_dqmode(sc_dqmode),
               .sc_tri_en(sc_tri_en),
               .sc_odly_en(sc_odly_en),
/******************************/
//add cfg
               .sc_term_offset(sc_term_offset), //[3:2]:TERM_OFF_SET  [1:0]:TERM_ON_SET
               .sc_termmode(sc_termmode),       //("TERM_EN=TRUE")? sc_tqmode : 2'b11 ;
               .sc_thsmem_en(sc_thsmem_en),
               .sc_tserdes_en(sc_tserdes_en),   //TSERDES_EN
               .sc_tser_ddren(sc_tser_ddren),
               .sc_tser_sdren(sc_tser_sdren),
               .sc_tlthen(sc_tlthen),
               .sc_tdffen(sc_tdffen),
               .sc_tserdes_mode(sc_tserdes_mode),  //TSERDES_MODE
               .sc_tser_upd0_shiften(sc_tser_upd0_shiften), //TUPD0_SHIFT_EN
               .sc_tser_upd1_shiften(sc_tser_upd1_shiften), //TUPD1_SHIFT_EN
               .sc_tser_init_set(sc_tser_init_set), //TINIT_SET
               .sc_tdly_en(sc_tdly_en),         //CP_TDLY_EN
               .sc_termbyte_en(sc_termbyte_en), //TERMBYTE_EN 
//add input
               .to_dly_in(),
//add output
               .tbyte_out(),
               .termbyte_out(),
/******************************/
               .osr_iolhp(osr_iolhp),
               .gwen(gwen),
               .glogen(glogen),
               .grs_n(grs_n),
               //.por_n(por_n),
               .oce(oce),
               .tce(tce),
               .oclkdiv(oclkdiv),
               .oclkdivb(oclkdivb),
               .serclk(serclk),
               .serclkb(serclkb),
               .oclk(oclk),
               .oclkb(oclkb),
               .upd0_shift(upd0_shift),
               .upd1_shift(upd1_shift),
               .do_cas_in(do_cas_in),
               .oshiftin0(oshiftin0),
               .oshiftin1(oshiftin1),
               .tx_data(tx_data),
               .mipi_sw_dyn_i(mipi_sw_dyn_i),
               .inbuf_dyn_dis_n_i(inbuf_dyn_dis_n_i),
               .sc_srval_tq(sc_srval_tq),
               .sc_init_tq(sc_init_tq),
               .sc_tqmode(sc_tqmode),
               .sc_tbyte_en(sc_tbyte_en),
               .ts_ctrl(ts_ctrl),
               .tbyte_in(t_bytein),
               .termbyte_in(term_bytein),      
               .to_cas_in(to_cas_in),
               .term_cas_in(term_cas_in),
               .dly_odly_in(dly_odly_in),
               .term(),
               .tfb(tfb),
               .term_fb(term_fb),
               .to_cas_out(),
               .term_cas_out(),
               .oshiftout0(oshiftout0),
               .oshiftout1(oshiftout1),
               .do_p(do_p),
               .do_n(),
               .to(to),        // add
               .do_cas_out(),
               .ofb(),
               .mipi_sw_dyn_o(),
               .inbuf_dyn_dis_n_o()
              );

endgenerate

//GTP_GRS GRS_INST(.GRS_N(1'b1));


endmodule
