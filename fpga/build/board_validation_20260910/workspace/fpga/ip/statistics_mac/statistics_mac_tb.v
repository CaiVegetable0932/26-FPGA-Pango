

/////////////////////////////////////////////////////////////////////////////
//
// Copyright (c) 2014 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
//
// THE SOURCE CODE CONTAINED HEREIN IS PROPRIETARY TO PANGO MICROSYSTEMS, INC.
// IT SHALL NOT BE REPRODUCED OR DISCLOSED IN WHOLE OR IN PART OR USED BY
// PARTIES WITHOUT WRITTEN AUTHORIZATION FROM THE OWNER.
//
//////////////////////////////////////////////////////////////////////////////
//
// Library:
// Filename:TB statistics_mac_tb.v
//////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ns

module statistics_mac_tb();

localparam  T_CLK_PERIOD       = 10     ;       //clock a half perid
localparam  T_RST_TIME         = 200    ;       //reset time
localparam  T_SIM_TIME         = 100000 ;       //simulation time


localparam ASIZE = 16 ; //@IPC int 2,52

localparam BSIZE = 16 ; //@IPC int 2,52

localparam PSIZE = 48 ; //@IPC enum 24,48,65,96,82,99

localparam A_SIGNED = 0 ; //@IPC enum 0,1

localparam B_SIGNED = 0 ; //@IPC enum 0,1

localparam ASYNC_RST = 1 ; //@IPC enum 0,1

localparam OPTIMAL_TIMING = 0 ; //@IPC enum 0,1

localparam INREG_EN = 1 ; //@IPC enum 0,1

localparam PIPEREG_EN = 1 ; //@IPC enum 0,1

localparam ACC_ADDSUB_OP = 0 ; //@IPC bool

localparam DYN_ACC_ADDSUB_OP = 0 ; //@IPC bool

localparam DYN_ACC_INIT = 1 ; //@IPC bool

localparam [PSIZE-1:0] ACC_INIT_VALUE = 48'h0 ; //@IPC string

//tmp variable for ipc purpose

localparam PIPE_STATUS = 2 ; //@IPC enum 0,1,2

localparam ASYNC_RST_BOOL = 1 ; //@IPC bool

localparam OPTIMAL_TIMING_BOOL = 0 ; //@IPC bool

//end of tmp variable


localparam ASIZE_SIGNED  = (A_SIGNED == 1) ? ASIZE : (ASIZE + 1);

localparam BSIZE_SIGNED  = (B_SIGNED == 1) ? BSIZE : (BSIZE + 1);

localparam MAX_DATA_SIZE = (ASIZE_SIGNED >= BSIZE_SIGNED)? ASIZE_SIGNED : BSIZE_SIGNED;

localparam MIN_DATA_SIZE = (ASIZE_SIGNED <  BSIZE_SIGNED)? ASIZE_SIGNED : BSIZE_SIGNED;

// variable declaration
reg                 clk;
reg                 rst;
reg                 ce;
reg  [ASIZE-1:0]    a;
reg  [BSIZE-1:0]    b;
wire [PSIZE-1:0]    p;
reg  [PSIZE-1:0]    p_comp;
wire [PSIZE-1:0]    p_acc;
reg  [PSIZE-1:0]    acc_init;
reg                 acc_addsub;
reg  [9:0]          reload_cunt;
wire                reload;

wire [143:0]        a_ext;
wire [143:0]        b_ext;
wire [287:0]        p_ext;
reg  [PSIZE-1:0]    product_p_ff;
reg  [PSIZE-1:0]    product_p_ff2;
wire [PSIZE-1:0]    p_check;

wire [PSIZE-1:0]    acc_init_comb;

reg                 pass;

initial
begin
    clk = 1'b1;
    rst = 1'b1;
    #T_RST_TIME
    rst = 1'b0;
end

always #T_CLK_PERIOD clk = ~clk;

initial
begin
    a           = {ASIZE{1'b0}};
    b           = {BSIZE{1'b0}};
    acc_init    = 1'b0         ;
    acc_addsub  = 1'b0         ;
end

GTP_GRS   GRS_INST( .GRS_N(1'b1) );

always@(posedge clk)
begin
    a <= {$random,$random};
    b <= {$random,$random};
    acc_addsub <= $random;
    acc_init   <= {$random,$random};
end

always@(negedge clk or posedge rst)
begin
    if(rst)
        ce <= 1'b1;
    else
        ce <= $random;
end

assign a_ext = {{(100-ASIZE){a[ASIZE-1]&&A_SIGNED}},a[ASIZE-1:0]};

assign b_ext = {{(100-BSIZE){b[BSIZE-1]&&B_SIGNED}},b[BSIZE-1:0]};

assign p_ext = ((a == 0) || (b ==0)) ? {288{1'b0}}
                                     : {{(288-ASIZE-BSIZE){(a_ext[ASIZE+BSIZE]&&A_SIGNED)^(b_ext[ASIZE+BSIZE]&&B_SIGNED)}},{a_ext[ASIZE+BSIZE-1:0] * b_ext[ASIZE+BSIZE-1:0]}};

assign acc_init_comb = (DYN_ACC_INIT == 1) ? acc_init : ACC_INIT_VALUE;

//reload
always@(negedge clk or posedge rst)
begin
    if(rst)
        reload_cunt <= 9'b0;
    else
        reload_cunt <= reload_cunt + 9'b1;
end

assign reload = reload_cunt[9];

always @(posedge clk or posedge rst)
begin
    if (rst)
        p_comp   <= {PSIZE{1'b0}};
    else if(ce)
    begin
        if (reload)
            p_comp <= acc_init_comb;
        else if (DYN_ACC_ADDSUB_OP)
        begin
            if (acc_addsub == 0)
                p_comp <= p_comp + p_ext;
            else
                p_comp <= p_comp - p_ext;
        end
        else if (ACC_ADDSUB_OP)
            p_comp <= p_comp - p_ext;
        else
            p_comp <= p_comp + p_ext;
    end
end

always @(posedge clk or posedge rst)
begin
    if(rst)
    begin
        product_p_ff  <= {PSIZE{1'b0}};
        product_p_ff2 <= {PSIZE{1'b0}};
    end
    else if(ce)
    begin
       product_p_ff  <= p_comp;
       product_p_ff2 <= product_p_ff;
    end
end

assign p_acc = ((INREG_EN ==0)&&(PIPEREG_EN ==0)) ? p_comp :
                      (((INREG_EN ==0)&&(PIPEREG_EN ==1))|((INREG_EN ==1)&&(PIPEREG_EN ==0))) ? product_p_ff : product_p_ff2 ;

assign p_check = p_acc;


integer  result_fid;
initial
begin
    $display("Simulation Starts ...\n");
    result_fid = $fopen ("sim_results.log","a");
    #T_SIM_TIME;
    $display("Simulation is done.\n");
    if (pass == 1)
        $display("Simulation Success!\n");
    else
        $display("Simulation Failed!\n");
    $finish;
end


always @(posedge clk or posedge rst)
begin
    if(rst)
        pass <= 1'b1;
    else if ( p_check !== p)
    begin
        $fdisplay(result_fid, "err_chk=1");
        $display("multacc error! multacc data = %h, product = %h",p_check,p);
        pass <= 1'b0;
    end
end

//***************************************************************** DUT  INST ********************************************************************************
statistics_mac  U_statistics_mac
(
    .ce         ( ce        ),
    .rst        ( rst       ),
    .clk        ( clk       ),
    .a          ( a         ),
    .b          ( b         ),

    .acc_init   (acc_init   ),      //@IPC show DYN_ACC_INIT

    .reload     (reload     ),
    .p          (p          )
);
 endmodule
