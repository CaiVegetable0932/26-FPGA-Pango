

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
// Filename:statistics_mac.v                 
//////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ns
module statistics_mac
( 
     ce         ,
     rst        ,
     clk        ,
     a          ,
     b          ,

     acc_init   ,	//@IPC show DYN_ACC_INIT

     reload     ,
     p
);



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
 
 localparam  GRS_EN       = "FALSE"        ;


 input                ce                   ;
 input                rst                  ;
 input                clk                  ;
 input  [ASIZE-1:0]   a                    ;
 input  [BSIZE-1:0]   b                    ;

 input  [PSIZE-1:0]   acc_init             ;	//@IPC show DYN_ACC_INIT

 input                reload               ;
 output [PSIZE-1:0]   p                    ;

ipm2l_multacc_v1_2_statistics_mac
#(  
    .ASIZE              ( ASIZE             ),
    .BSIZE              ( BSIZE             ),
    .PSIZE              ( PSIZE             ),
    .OPTIMAL_TIMING     ( OPTIMAL_TIMING    ),
    .INREG_EN           ( INREG_EN          ),     
    .PIPEREG_EN_1       ( PIPEREG_EN        ),   
    .GRS_EN             ( GRS_EN            ), 
    .A_SIGNED           ( A_SIGNED          ),    
    .B_SIGNED           ( B_SIGNED          ),    
    .ASYNC_RST          ( ASYNC_RST         ),     
    .ACC_INIT_VALUE     ( ACC_INIT_VALUE    ), 
    .DYN_ACC_INIT       ( DYN_ACC_INIT      ),
    .ACC_ADDSUB_OP      ( ACC_ADDSUB_OP     ),   
    .DYN_ACC_ADDSUB_OP  ( DYN_ACC_ADDSUB_OP ) 
) 
u_ipm2l_multacc_statistics_mac
(
    .ce         ( ce        ),
    .rst        ( rst       ),
    .clk        ( clk       ),
    .a          ( a         ),
    .b          ( b         ),

    .acc_init   ( acc_init  ),   //@IPC show DYN_ACC_INIT

    .acc_addsub ( 1'b0      ),	 //@IPC show DYN_ACC_ADDSUB_OP

    .reload     ( reload    ),
    .p          ( p         )
);

endmodule
