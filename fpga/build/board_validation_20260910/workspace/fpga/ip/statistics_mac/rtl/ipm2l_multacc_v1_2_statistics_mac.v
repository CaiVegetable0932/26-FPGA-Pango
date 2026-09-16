
//////////////////////////////////////////////////////////////////////////////
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
// Filename:ipm2l_multacc.v
// Function: p=p+/-a*b
//           asize:2-42(singed)/41(unsigned)
//           bsize:2-52(singed)/51(unsigned)
//           psize:24,48,65,96,82,99
//////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps
module ipm2l_multacc_v1_2_statistics_mac
#(
    parameter               ASIZE               = 41,       //signed:2-42;unsigned:2-41
    parameter               BSIZE               = 51,       //signed:2-52;unsigned:2-51
    parameter               PSIZE               = 99,       //option:24,48,65,96,82,99

    parameter               OPTIMAL_TIMING      = 0,

    parameter               INREG_EN            = 0,        //X_REG Y_REG
    parameter               PIPEREG_EN_1        = 0,        //MULT_REG

    parameter               GRS_EN              = "FALSE",  //"TRUE","FALSE",enable global reset
    parameter               A_SIGNED            = 0,        //signedness of A
    parameter               B_SIGNED            = 0,        //signedness of B

    parameter               ASYNC_RST           = 1,        //RST is sync/async
    //init value
    parameter               DYN_ACC_INIT        = 0,        //1:dynamic reload 0:static reload
    parameter  [PSIZE-1:0]  ACC_INIT_VALUE      = 0,        //static reload value

    parameter               DYN_ACC_ADDSUB_OP   = 0,        //1:dynamic acc 0:static acc
    parameter               ACC_ADDSUB_OP       = 0
)(
    input                   ce          ,
    input                   rst         ,
    input                   clk         ,
    input       [ASIZE-1:0] a           ,
    input       [BSIZE-1:0] b           ,
    input       [PSIZE-1:0] acc_init    ,
    input                   reload      ,
    input                   acc_addsub  ,                   //0:add 1:sub
    output wire [PSIZE-1:0] p
);


localparam OPTIMAL_TIMING_BOOL = 0 ; //@IPC bool


localparam ASIZE_SIGNED  = (A_SIGNED == 1) ? ASIZE : (ASIZE + 1);

localparam BSIZE_SIGNED  = (B_SIGNED == 1) ? BSIZE : (BSIZE + 1);

localparam MAX_DATA_SIZE = (ASIZE_SIGNED >= BSIZE_SIGNED)? ASIZE_SIGNED : BSIZE_SIGNED;

localparam MIN_DATA_SIZE = (ASIZE_SIGNED <  BSIZE_SIGNED)? ASIZE_SIGNED : BSIZE_SIGNED;

localparam [0:0]MAX_DATA_SIZE_SIGNED = (ASIZE_SIGNED >= BSIZE_SIGNED)? A_SIGNED : B_SIGNED;

localparam [0:0]MIN_DATA_SIZE_SIGNED = (ASIZE_SIGNED <  BSIZE_SIGNED)? A_SIGNED : B_SIGNED;

localparam USE_SIMD      = (MAX_DATA_SIZE > 12 || MIN_DATA_SIZE > 9 ) ? 0 : ((PSIZE > 24 ) ? 0 : 1);   // single addsub25_mult25_add48 / dual addsub12_mult12_add24

localparam MODE_12_9_A   = (USE_SIMD == 1 ) ? 12 : 25;

localparam MODE_12_9_B   = (USE_SIMD == 1 ) ? 9  : 18;

localparam USE_POSTADD   = 1'b1 ;         //enable postadder 0/1

localparam P_REG         = 1'b1 ;         //enable P_REG

localparam [99:0] ACC_INIT_VALUE_IN = {{(100-PSIZE){1'b0}},ACC_INIT_VALUE};

//****************************************data_size error check**********************************************************
localparam N = (MIN_DATA_SIZE < 2  ) ? 0 :
               (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18 && (PSIZE == 48 ) ) ? 1  :       //MAC12x9/MAC25x18,psize=48
               (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18 && (PSIZE >  48 ) ) ? 2  :       //MAC25x18 psize>48
               (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 18) ? 3  :                          //MAC42X18
               (MAX_DATA_SIZE <= 35 && MIN_DATA_SIZE <= 25) ? 3  :                          //MAC25X35
               (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 25) ? 5  :                          //MAC25X52
               (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 35) ? 6  :                          //MAC42X35
               (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 42) ? 9  : 0;                       //MAC42X52

localparam GTP_APM_E2_NUM = N;
//****************************************************************DATA WIDTH****************************************
localparam M_A_DATA_WIDTH = (MAX_DATA_SIZE <= 12 && MIN_DATA_SIZE <= 9 ) ? MAX_DATA_SIZE :                 //MAC12x9
                            (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18) ? MAX_DATA_SIZE :                 //MAC25x18
                            (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 18) ? MAX_DATA_SIZE :                 //MAC42X18
                            (MAX_DATA_SIZE <= 35 && MIN_DATA_SIZE <= 25) ? MIN_DATA_SIZE :                 //MAC25X35
                            (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 25) ? MIN_DATA_SIZE :                 //MAC25X52
                            (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 35) ? MAX_DATA_SIZE :                 //MAC42X35
                            (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 42) ? MIN_DATA_SIZE : MAX_DATA_SIZE;  //MAC42X52

localparam M_B_DATA_WIDTH = (MAX_DATA_SIZE <= 12 && MIN_DATA_SIZE <= 9 ) ? MIN_DATA_SIZE :                 //MAC12x9
                            (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18) ? MIN_DATA_SIZE :                 //MAC25x18
                            (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 18) ? MIN_DATA_SIZE :                 //MAC42X18
                            (MAX_DATA_SIZE <= 35 && MIN_DATA_SIZE <= 25) ? MAX_DATA_SIZE :                 //MAC25X35
                            (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 25) ? MAX_DATA_SIZE :                 //MAC25X52
                            (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 35) ? MIN_DATA_SIZE :                 //MAC42X35
                            (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 42) ? MAX_DATA_SIZE : MIN_DATA_SIZE;  //MAC42X52

//****************************************************************GTP_APM_E2 cascade****************************************
localparam [8:0] X_SEL     = (MAX_DATA_SIZE <= 12 && MIN_DATA_SIZE <= 9 ) ? 9'b0 :                  //MAC12x9
                             (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18) ? 9'b0 :                  //MAC25x18
                             (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 18) ? 9'b0 :                  //MAC42X18
                             (MAX_DATA_SIZE <= 35 && MIN_DATA_SIZE <= 25) ? 9'b0_0000_0010 :        //MAC25X35
                             (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 25) ? 9'b0_0000_0010 :        //MAC25X52
                             (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 35) ? 9'b0_0000_0010 :        //MAC42X35
                             (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 42) ? 9'b0_0000_0010 : 9'b0;  //MAC42X52

localparam [48*9-1:0] ACC_INIT_VALUE_IN_CS = (MAX_DATA_SIZE <= 12 && MIN_DATA_SIZE <= 9 ) ? {384'b0,ACC_INIT_VALUE_IN[47:0]} :                                                      //MAC12x9
                                             (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18 && (PSIZE == 48 ) ) ? {384'b0,ACC_INIT_VALUE_IN[47:0]} :                                   //MAC25x18,psize=48
                                             (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18 && (PSIZE == 65 ) ) ? {336'b0,ACC_INIT_VALUE_IN[64:17],{31'b0,ACC_INIT_VALUE_IN[16:0]}} :  //MAC25x18 psize=65
                                             (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18 && (PSIZE == 96 ) ) ? {336'b0,ACC_INIT_VALUE_IN[95:48],ACC_INIT_VALUE_IN[47:0]} :          //MAC25x18 psize=96
                                             (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 18) ? {288'b0,ACC_INIT_VALUE_IN[64:17],48'b0,{31'b0,ACC_INIT_VALUE_IN[16:0]}} :               //MAC42X18
                                             (MAX_DATA_SIZE <= 35 && MIN_DATA_SIZE <= 25) ? {288'b0,ACC_INIT_VALUE_IN[64:17],48'b0,{31'b0,ACC_INIT_VALUE_IN[16:0]}} :               //MAC25X35
                                             (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 25) ? {192'b0,ACC_INIT_VALUE_IN[81:34],48'b0,{31'b0,ACC_INIT_VALUE_IN[33:17]},48'b0,{31'b0,ACC_INIT_VALUE_IN[16:0]}} :               //MAC25X35
                                             (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 35) ? {144'b0,ACC_INIT_VALUE_IN[81:34],48'b0,{31'b0,ACC_INIT_VALUE_IN[33:17]},48'b0,48'b0,{31'b0,ACC_INIT_VALUE_IN[16:0]}} :      //MAC42X35
                                             (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 42) ? {ACC_INIT_VALUE_IN[98:51],48'b0,{31'b0,ACC_INIT_VALUE_IN[50:34]},48'b0,48'b0,{31'b0,ACC_INIT_VALUE_IN[33:17]},48'b0,48'b0,{31'b0,ACC_INIT_VALUE_IN[16:0]}} : 48'b0;  //MAC42X52

localparam [8:0] CPO_REG   = (OPTIMAL_TIMING == 0 ) ? 9'b0 :
                             (MAX_DATA_SIZE <= 12 && MIN_DATA_SIZE <= 9 ) ? 9'b0 :                  //MAC12x9
                             (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18) ? 9'b0 :                  //MAC25x18
                             (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 18) ? 9'b0 :                  //MAC42X18
                             (MAX_DATA_SIZE <= 35 && MIN_DATA_SIZE <= 25) ? 9'b0 :                  //MAC25X35
                             (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 25) ? 9'b0_0000_1010 :        //MAC25X52
                             (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 35) ? 9'b0_0010_1010 :        //MAC42X35
                             (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 42) ? 9'b0_1010_1010 : 9'b0;  //MAC42X52

localparam [8:0] USE_ACCLOW = (MAX_DATA_SIZE <= 12 && MIN_DATA_SIZE <= 9 ) ? 9'b0  :                    //MAC12x9
                              (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18 && (PSIZE == 48 ) ) ? 9'b0 :  //MAC25x18,psize=48
                              (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18 && (PSIZE == 65 ) ) ? 9'b1 :  //MAC25x18 psize=65
                              (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18 && (PSIZE == 96 ) ) ? 9'b0 :  //MAC25x18 psize=96
                              (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 18) ? 9'b1 :                     //MAC42X18
                              (MAX_DATA_SIZE <= 35 && MIN_DATA_SIZE <= 25) ? 9'b1 :                     //MAC25X35
                              (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 25) ? 9'b0_0000_0101 :           //MAC25X52
                              (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 35) ? 9'b0_0000_1001 :           //MAC42X35
                              (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 42) ? 9'b0_0100_1001 : 9'b0 ;    //MAC42X52

localparam [8:0] CIN_SEL = (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18 && (PSIZE == 96 ) ) ? 9'b0_0000_0010  : 9'b0; //MAC25x18 psize=96


//**************************************************************************************************************************
initial
begin
    if (N == 0)
    begin
        $display("apm_mult parameter setting error!!! DATA_SIZE must between 2*2-42*52(signed)/41*51(unsigned)");
    end
end

//**********************************************************reg & wire******************************************************
wire [ASIZE_SIGNED-1:0]     a_signed            ;
wire [BSIZE_SIGNED-1:0]     b_signed            ;

wire [MAX_DATA_SIZE-1:0]    max_data            ;
wire [MIN_DATA_SIZE-1:0]    min_data            ;

wire [24:0]                 m_a_0               ;
wire [24:0]                 m_a_1               ;
wire [17:0]                 m_b_0               ;
wire [17:0]                 m_b_1               ;
wire [17:0]                 m_b_2               ;

wire [41:0]                 m_a_sign_ext        ;
wire [51:0]                 m_b_sign_ext        ;

reg                         acc_addsub_ff       ;
reg                         reload_ff           ;
reg  [PSIZE-1:0]            acc_init_ff         ;

wire                        acc_addsub_in       ;
wire                        reload_in           ;
wire [PSIZE-1:0]            acc_init_value      ;
wire [98:0]                 acc_init_in         ;


wire [M_A_DATA_WIDTH-1:0]   m_a                 ;
wire [M_B_DATA_WIDTH-1:0]   m_b                 ;
reg  [24:0]                 m_a_div[8:0]        ;
reg  [17:0]                 m_b_div[8:0]        ;
wire [24:0]                 m_a_in[8:0]         ;
wire [17:0]                 m_b_in[8:0]         ;

reg  [3:0]                  modez_in[8:0]       ;
reg  [2:0]                  modey_in[8:0]       ;
reg  [47:0]                 z_in[8:0]           ;

wire [47:0]                 m_p[8:0]            ;
wire [47:0]                 cpo[9:0]            ;
wire [29:0]                 cxo[9:0]            ;
wire [9:0]                  cout                ;

wire                        mult_sign           ;
reg                         mult_sign_ff        ;
wire                        mult_sign_in        ;

wire                        rst_async           ;
wire                        rst_sync            ;


//rst
assign rst_async = (ASYNC_RST == 1'b1) ? rst : 1'b0;
assign rst_sync  = (ASYNC_RST == 1'b0) ? rst : 1'b0;

assign a_signed  = (A_SIGNED == 1) ? a : {1'b0,a}; //unsigned -> signed
assign b_signed  = (B_SIGNED == 1) ? b : {1'b0,b}; //unsigned -> signed

assign max_data  = (ASIZE_SIGNED >= BSIZE_SIGNED) ? a_signed : b_signed;
assign min_data  = (ASIZE_SIGNED <  BSIZE_SIGNED) ? a_signed : b_signed;

generate
begin
    if(MAX_DATA_SIZE <= 12 && MIN_DATA_SIZE <= 9 )           //MAC12x9
    begin
        assign m_a = max_data;
        assign m_b = min_data;
    end
    else if (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18)    //MAC25x18
    begin
        assign m_a = max_data;
        assign m_b = min_data;
    end
    else if (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 18)    //MAC42X18
    begin
        assign m_a = max_data;
        assign m_b = min_data;
    end
    else if (MAX_DATA_SIZE <= 35 && MIN_DATA_SIZE <= 25)    //MAC25X35
    begin
        assign m_a = min_data;
        assign m_b = max_data;
    end
    else if (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 25)    //MAC25X52
    begin
        assign m_a = min_data;
        assign m_b = max_data;
    end
    else if (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 35)    //MAC42X35
    begin
        assign m_a = max_data;
        assign m_b = min_data;
    end
    else if (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 42)    //MAC42X52
    begin
        assign m_a = min_data;
        assign m_b = max_data;
    end
end
endgenerate

//*******************************************************partition input data***********************************************
generate
    if(M_A_DATA_WIDTH == 42)
        assign m_a_sign_ext = m_a;
    else
        assign m_a_sign_ext = {{{42-M_A_DATA_WIDTH}{m_a[M_A_DATA_WIDTH-1]}},m_a};
endgenerate
generate
    if(M_B_DATA_WIDTH == 52)
        assign m_b_sign_ext = m_b;
    else
        assign m_b_sign_ext = {{{52-M_B_DATA_WIDTH}{m_b[M_B_DATA_WIDTH-1]}},m_b};
endgenerate
//partition data a
generate
begin:partition_data_a
    if (M_A_DATA_WIDTH <= 25)
        assign m_a_0 = m_a_sign_ext[24:0];
    else if (M_A_DATA_WIDTH <= 42)
    begin
        assign m_a_0 = {8'b0,m_a_sign_ext[16:0]};
        assign m_a_1 = m_a_sign_ext[41:17];
    end
end
endgenerate

//partition data b
generate
begin:partition_data_b
    if (M_B_DATA_WIDTH <= 18)
        assign m_b_0 = m_b_sign_ext[17:0];
    else if (M_B_DATA_WIDTH <= 35)
    begin
        assign m_b_0 = {1'b0,m_b_sign_ext[16:0]};
        assign m_b_1 = m_b_sign_ext[34:17];
    end
    else if (M_B_DATA_WIDTH <= 52)
    begin
        assign m_b_0 = {1'b0,m_b_sign_ext[16:0]};
        assign m_b_1 = {1'b0,m_b_sign_ext[33:17]};
        assign m_b_2 = m_b_sign_ext[51:34];
    end
end
endgenerate
//**************************************addsub & reload**********************************************
always@(posedge clk or posedge rst_async)
begin
    if (rst_async)
    begin
        acc_addsub_ff  <= 1'b0;
        reload_ff      <= 1'b0;
        acc_init_ff    <= {PSIZE{1'b0}};
    end
    else if (rst_sync)
    begin
        acc_addsub_ff <= 1'b0;
        reload_ff     <= 1'b0;
        acc_init_ff   <= {PSIZE{1'b0}};
    end
    else if (ce)
    begin
        acc_addsub_ff <= (DYN_ACC_ADDSUB_OP == 0) ? ACC_ADDSUB_OP : acc_addsub;
        reload_ff     <= reload;
        acc_init_ff   <= acc_init;
    end
end

assign acc_addsub_in  = (PIPEREG_EN_1 == 1) ? acc_addsub_ff : (DYN_ACC_ADDSUB_OP == 0) ? ACC_ADDSUB_OP : acc_addsub;
assign reload_in      = (PIPEREG_EN_1 == 1) ? reload_ff     : reload;
assign acc_init_value = (PIPEREG_EN_1 == 1) ? acc_init_ff   : acc_init;
generate
    if(PSIZE == 99)
        assign acc_init_in = acc_init_value;
    else
        assign acc_init_in = {{(99-PSIZE){1'b0}},acc_init_value};
endgenerate

generate
begin
    if (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18 && (PSIZE == 96 )) //MAC25x18,psize=96
    begin:mode_25_18_P96_signed
    //for MAC25*18_P96

        assign mult_sign = ((MAX_DATA_SIZE_SIGNED[0] && m_a_in[0][24]) ^ (MIN_DATA_SIZE_SIGNED[0] && m_b_in[0][17])) && (|m_a_in[0] && |m_b_in[0]);

        always @ (posedge clk or posedge rst_async)
        begin
            if (rst_async)
                mult_sign_ff <= 1'b0;
            else if (rst_sync)
                mult_sign_ff <= 1'b0;
            else if (ce)
                mult_sign_ff <= mult_sign;
        end

        assign mult_sign_in = (PIPEREG_EN_1 == 1)? mult_sign_ff : mult_sign;
    end
end
endgenerate

//*******************************************************input data***********************************************************
generate
begin:data_for_GTP
    if (MAX_DATA_SIZE <= 12 && MIN_DATA_SIZE <= 9 ) //MAC12x9,psize=48
    begin:mode_12_9
        always@(*)
        begin
            m_a_div[0]  = m_a_0[MODE_12_9_A-1:0];
            m_b_div[0]  = m_b_0[MODE_12_9_B-1:0];

            modez_in[0] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0001;
            modey_in[0] = reload_in ? 3'b0 : {acc_addsub_in,2'b01};
            z_in [0]    = acc_init_in[47:0];
        end
    end
    else if (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18 && (PSIZE == 48 )) //MAC25x18,psize=48
    begin:mode_25_18_P48
        always@(*)
        begin
            m_a_div[0]  = m_a_0;
            m_b_div[0]  = m_b_0;

            modez_in[0] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0001;
            modey_in[0] = reload_in ? 3'b0 : {acc_addsub_in,2'b01};
            z_in [0]    = acc_init_in[47:0];
        end
    end
    else if (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18 && (PSIZE == 65 )) //MAC25x18,psize=65
    begin:mode_25_18_P66
        always@(*)
        begin
            m_a_div[0]  = m_a_0;
            m_a_div[1]  = {25{1'b1}};
            m_b_div[0]  = m_b_0;
            m_b_div[1]  = {18{1'b1}};

            modez_in[0] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0001;
            modez_in[1] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0100;
            modey_in[0] = reload_in ? 3'b0 : {acc_addsub_in,2'b01};
            modey_in[1] = reload_in ? 3'b0 : 3'b010;
            z_in [0]    = {31'b0,acc_init_in[16:0]};
            z_in [1]    = acc_init_in[64:17];
        end
    end
    else if (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18 && (PSIZE == 96 )) //MAC25x18,psize=96
    begin:mode_25_18_P96
        always@(*)
        begin
            m_a_div[0]  = m_a_0;
            m_a_div[1]  = {25{1'b1}};
            m_b_div[0]  = m_b_0;
            m_b_div[1]  = {18{1'b1}};

            modez_in[0] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0001;
            modez_in[1] = {{reload_in ? 1'b0 : acc_addsub_in},{reload_in ? (DYN_ACC_INIT ? 3'b010 : 3'b0) : 3'b010}};
            modey_in[0] = reload_in ? 3'b0 : {acc_addsub_in,2'b01};
            modey_in[1] = reload_in ? 3'b0 : 3'b010;
            z_in [0]    = acc_init_in[47:0];
            z_in [1]    = reload_in ? acc_init_in[95:48] : {48{mult_sign_in}};
        end
    end
    else if (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 18)  //MAC42X18,psize=65
    begin:mode_42_18
        always@(*)
        begin
            m_a_div[0]  = m_a_0;
            m_a_div[1]  = m_a_1;
            m_a_div[2]  = {25{1'b1}};
            m_b_div[0]  = m_b_0;
            m_b_div[1]  = m_b_0;
            m_b_div[2]  = {18{1'b1}};

            modez_in[0] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0001;
            modez_in[1] = 4'b0100;
            modez_in[2] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0011;
            modey_in[0] = reload_in ? 3'b0 : {acc_addsub_in,2'b01};
            modey_in[1] = {acc_addsub_in,2'b01};
            modey_in[2] = reload_in ? 3'b0 : 3'b010;
            z_in [0]    = {31'b0,acc_init_in[16:0]};
            z_in [1]    = 48'b0;
            z_in [2]    = acc_init_in[64:17];
        end
    end
    else if (MAX_DATA_SIZE <= 35 && MIN_DATA_SIZE <= 25)  //MAC25X35,psize=65
    begin:mode_25_35
        always@(*)
        begin
            m_a_div[0]  = m_a_0;
            m_a_div[1]  = m_a_0;
            m_a_div[2]  = {25{1'b1}};
            m_b_div[0]  = m_b_0;
            m_b_div[1]  = m_b_1;
            m_b_div[2]  = {18{1'b1}};

            modez_in[0] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0001;
            modez_in[1] = 4'b0100;
            modez_in[2] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0011;
            modey_in[0] = reload_in ? 3'b0 : {acc_addsub_in,2'b01};
            modey_in[1] = {acc_addsub_in,2'b01};
            modey_in[2] = reload_in ? 3'b0 : 3'b010;
            z_in [0]    = {31'b0,acc_init_in[16:0]};
            z_in [1]    = 48'b0;
            z_in [2]    = acc_init_in[64:17];
        end
    end
    else if (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 25)  //MAC25X52,psize=82
    begin:mode_25_52
        always@(*)
        begin
            m_a_div[0]  = m_a_0;
            m_a_div[1]  = m_a_0;
            m_a_div[2]  = {25{1'b1}};
            m_a_div[3]  = m_a_0;
            m_a_div[4]  = {25{1'b1}};
            m_b_div[0]  = m_b_0;
            m_b_div[1]  = m_b_1;
            m_b_div[2]  = {18{1'b1}};
            m_b_div[3]  = m_b_2;
            m_b_div[4]  = {18{1'b1}};

            modez_in[0] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0001;
            modez_in[1] = 4'b0100;
            modez_in[2] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0011;
            modez_in[3] = 4'b0100;
            modez_in[4] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0011;
            modey_in[0] = reload_in ? 3'b0 : {acc_addsub_in,2'b01};
            modey_in[1] = {acc_addsub_in,2'b01};
            modey_in[2] = reload_in ? 3'b0 : 3'b010;
            modey_in[3] = {acc_addsub_in,2'b01};
            modey_in[4] = reload_in ? 3'b0 : 3'b010;
            z_in [0]    = {31'b0,acc_init_in[16:0]};
            z_in [1]    = 48'b0;
            z_in [2]    = {31'b0,acc_init_in[33:17]};
            z_in [3]    = 48'b0;
            z_in [4]    = acc_init_in[81:34];
        end
    end
    else if (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 35)  //MAC42X35,psize=82
    begin:mode_42_35
        always@(*)
        begin
            m_a_div[0]  = m_a_0;
            m_a_div[1]  = m_a_0;
            m_a_div[2]  = m_a_1;
            m_a_div[3]  = {25{1'b1}};
            m_a_div[4]  = m_a_1;
            m_a_div[5]  = {25{1'b1}};
            m_b_div[0]  = m_b_0;
            m_b_div[1]  = m_b_1;
            m_b_div[2]  = m_b_0;
            m_b_div[3]  = {18{1'b1}};
            m_b_div[4]  = m_b_1;
            m_b_div[5]  = {18{1'b1}};

            modez_in[0] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0001;
            modez_in[1] = 4'b0100;
            modez_in[2] = 4'b0011;
            modez_in[3] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0011;
            modez_in[4] = 4'b0100;
            modez_in[5] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0011;
            modey_in[0] = reload_in ? 3'b0 : {acc_addsub_in,2'b01};
            modey_in[1] = {acc_addsub_in,2'b01};
            modey_in[2] = {acc_addsub_in,2'b01};
            modey_in[3] = reload_in ? 3'b0 : 3'b010;
            modey_in[4] = {acc_addsub_in,2'b01};
            modey_in[5] = reload_in ? 3'b0 : 3'b010;
            z_in [0]    = {31'b0,acc_init_in[16:0]};
            z_in [1]    = 48'b0;
            z_in [2]    = 48'b0;
            z_in [3]    = {31'b0,acc_init_in[33:17]};
            z_in [4]    = 48'b0;
            z_in [5]    = acc_init_in[81:34];
        end
    end
    else if (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 42)  //MAC42X52,psize=99
    begin:mode_42_52
        always@(*)
        begin
            m_a_div[0]  = m_a_0;
            m_a_div[1]  = m_a_0;
            m_a_div[2]  = m_a_1;
            m_a_div[3]  = {25{1'b1}};
            m_a_div[4]  = m_a_0;
            m_a_div[5]  = m_a_1;
            m_a_div[6]  = {25{1'b1}};
            m_a_div[7]  = m_a_1;
            m_a_div[8]  = {25{1'b1}};
            m_b_div[0]  = m_b_0;
            m_b_div[1]  = m_b_1;
            m_b_div[2]  = m_b_0;
            m_b_div[3]  = {18{1'b1}};
            m_b_div[4]  = m_b_2;
            m_b_div[5]  = m_b_1;
            m_b_div[6]  = {18{1'b1}};
            m_b_div[7]  = m_b_2;
            m_b_div[8]  = {18{1'b1}};

            modez_in[0] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0001;
            modez_in[1] = 4'b0100;
            modez_in[2] = 4'b0011;
            modez_in[3] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0011;
            modez_in[4] = 4'b0100;
            modez_in[5] = 4'b0011;
            modez_in[6] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0011;
            modez_in[7] = 4'b0100;
            modez_in[8] = reload_in ? (DYN_ACC_INIT ? 4'b0010 : 4'b0) : 4'b0011;

            modey_in[0] = reload_in ? 3'b0 : {acc_addsub_in,2'b01};
            modey_in[1] = {acc_addsub_in,2'b01};
            modey_in[2] = {acc_addsub_in,2'b01};
            modey_in[3] = reload_in ? 3'b0 : 3'b010;
            modey_in[4] = {acc_addsub_in,2'b01};
            modey_in[5] = {acc_addsub_in,2'b01};
            modey_in[6] = reload_in ? 3'b0 : 3'b010;
            modey_in[7] = {acc_addsub_in,2'b01};
            modey_in[8] = reload_in ? 3'b0 : 3'b010;
            z_in [0]    = {31'b0,acc_init_in[16:0]};
            z_in [1]    = 48'b0;
            z_in [2]    = 48'b0;
            z_in [3]    = {31'b0,acc_init_in[33:17]};
            z_in [4]    = 48'b0;
            z_in [5]    = 48'b0;
            z_in [6]    = {31'b0,acc_init_in[50:34]};
            z_in [7]    = 48'b0;
            z_in [8]    = acc_init_in[98:51];
        end
    end
end
endgenerate

genvar m_i;
generate
    for (m_i=0; m_i < GTP_APM_E2_NUM; m_i=m_i+1)
    begin:data_in
        assign m_a_in[m_i] = m_a_div[m_i];
        assign m_b_in[m_i] = m_b_div[m_i];
    end
endgenerate

//************************************************************GTP*********************************************************
genvar i;
generate
    for (i=0; i< GTP_APM_E2_NUM; i=i+1)
    begin:multacc
        GTP_APM_E2 #(

            .GRS_EN         ( GRS_EN                 ) ,  //"TRUE","FALSE",enable global reset
            .USE_POSTADD    ( USE_POSTADD            ) ,  //enable postadder 0/1
            .USE_PREADD     ( 1'b0                   ) ,  //enable preadder 0/1
            .PREADD_REG     ( 1'b0                   ) ,  //preadder reg 0/1

            .X_REG          ( INREG_EN               ) ,  //X input reg 0/1
            .CXO_REG        ( 2'b0                   ) ,  //X cascade out reg latency, 0/1/2/3
            .XB_REG         ( 1'b0                   ) ,  //XB input reg 0/1
            .Y_REG          ( INREG_EN               ) ,  //Y input reg 0/1
            .Z_REG          ( INREG_EN               ) ,  //Z input reg 0/1
            .MULT_REG       ( PIPEREG_EN_1           ) ,  //multiplier reg 0/1
            .P_REG          ( P_REG                  ) ,  //post adder reg 0/1
            .MODEY_REG      ( INREG_EN               ) ,  //MODEY reg
            .MODEZ_REG      ( INREG_EN               ) ,  //MODEZ reg
            .MODEIN_REG     ( 1'b0                   ) ,  //MODEZ reg

            .X_SEL          ( X_SEL[i]               ) ,  // mult X input select X/CXI
            .XB_SEL         ( 2'b0                   ) ,  //X back propagate mux select. 0/1/2/3
            .ASYNC_RST      ( ASYNC_RST              ) ,  // RST is sync/async
            .USE_SIMD       ( USE_SIMD               ) ,  // single addsub25_mult25_add48 / dual addsub12_mult12_add24
            .P_INIT0        ( {48{1'b0}}             ) ,  //P constant input0 (RTI parameter in APM of PG family) MAC INIT value
            .P_INIT1        ( ACC_INIT_VALUE_IN_CS[48*(i+1)-1:48*i] ) ,  //P constant input1 (RTI parameter in APM of PG family)
            .ROUNDMODE_SEL  ( 1'b0                   ) ,  //round mode selection

            .CPO_REG        ( CPO_REG[i]             ) ,  // CPO,COUT use register output
            .USE_ACCLOW     ( USE_ACCLOW[i]          ) ,  // accumulator use lower 18-bit feedback only
            .CIN_SEL        ( CIN_SEL[i]             )    // select CIN for postadder carry in

        )
        multacc
        (
            .P         ( m_p[i]                ) ,
            .CPO       ( cpo[i+1]              ) , //p cascade output
            .COUT      ( cout[i+1]             ) ,
            .CXO       ( cxo[i+1]              ) , //x cascade output
            .CXBO      (                       ) , //x backward cascade output

            .X         ( {{5{1'b1}},m_a_in[i]} ) ,
            .CXI       ( cxo[i]                ) , //x cascade input
            .CXBI      ( 25'b0                 ) , //x backward cascade input
            .XB        ( {25{1'b1}}            ) , //x backward cascade input
            .Y         ( m_b_in[i]             ) ,
            .Z         ( z_in[i]               ) ,
            .CPI       ( cpo[i]                ) , //p cascade input
            .CIN       ( cout[i]               ) ,
            .MODEY     ( modey_in[i]           ) ,
            .MODEZ     ( modez_in[i]           ) ,
            .MODEIN    ( 5'b00010              ) ,

            .CLK       ( clk)   ,

            .CEX1      ( ce )  ,  //X1 enable signals
            .CEX2      ( ce )  ,  //X2 enable signals
            .CEX3      ( ce )  ,  //X3 enable signals
            .CEXB      ( ce )  ,  //XB enable signals
            .CEY1      ( ce )  ,  //Y1 enable signals
            .CEY2      ( ce )  ,  //Y2 enable signals
            .CEZ       ( ce )  ,  //Z enable signals
            .CEPRE     ( ce )  ,  //PRE enable signals
            .CEM       ( ce )  ,  //M enable signals
            .CEP       ( ce )  ,  //P enable signals
            .CEMODEY   ( ce )  ,  //MODEY enable signals
            .CEMODEZ   ( ce )  ,  //MODEZ enable signals
            .CEMODEIN  ( ce )  ,  //MODEIN enable signals

            .RSTX      ( rst ) , //X reset signals
            .RSTXB     ( rst ) , //XB reset signals
            .RSTY      ( rst ) , //Y reset signals
            .RSTZ      ( rst ) , //Z reset signals
            .RSTPRE    ( rst ) , //PRE reset signals
            .RSTM      ( rst ) , //M reset signals
            .RSTP      ( rst ) , //P reset signals
            .RSTMODEY  ( rst ) , //MODEY reset signals
            .RSTMODEZ  ( 1'b0) , //MODEZ reset signals
            .RSTMODEIN ( rst )   //MODEIN reset signals

        );
    end
endgenerate


//*****************************************************************output***************************************************
 
generate
begin:outdata
    if (MAX_DATA_SIZE <= 12 && MIN_DATA_SIZE <= 9 && USE_SIMD == 1)  //MAC12x9
        assign p[23:0] = m_p[0][23:0];
    else if (MAX_DATA_SIZE <= 12 && MIN_DATA_SIZE <= 9 && USE_SIMD == 0)  //MAC12x9
        assign p[47:0] = m_p[0];
    else if (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18 && (PSIZE == 48 ))//MAC25x18,psize=48
        assign p[47:0] = m_p[0];
    else if (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18 && (PSIZE == 65 ))//MAC25x18 psize=65
        assign p[64:0] = {m_p[1],m_p[0][16:0]};
    else if (MAX_DATA_SIZE <= 25 && MIN_DATA_SIZE <= 18 && (PSIZE == 96 ))//MAC25x18 psize=96
        assign p[95:0] = {m_p[1],m_p[0]};
    else if (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 18) //MAC42X18
        assign p[64:0] = {m_p[2],m_p[0][16:0]};
    else if (MAX_DATA_SIZE <= 35 && MIN_DATA_SIZE <= 25) //MAC25X35
        assign p[64:0] = {m_p[2],m_p[0][16:0]};
    else if (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 25) //MAC25X52
        assign p[81:0] = {m_p[4],m_p[2][16:0],m_p[0][16:0]};
    else if (MAX_DATA_SIZE <= 42 && MIN_DATA_SIZE <= 35) //MAC42X35
        assign p[81:0] = {m_p[5],m_p[3][16:0],m_p[0][16:0]};
    else if (MAX_DATA_SIZE <= 52 && MIN_DATA_SIZE <= 42) //MAC42X52
        assign p[98:0] = {m_p[8],m_p[6][16:0],m_p[3][16:0],m_p[0][16:0]};
end
endgenerate

endmodule
