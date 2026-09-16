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
// Filename: GTP_CLKBUFG.v
//
// Functional description: Global Clock Buffer
//
// Parameter description:
//
// Port description:
//
// Revision:
//    06/18/14 - Initial version.
//    05/11/14 - 
//////////////////////////////////////////////////////////////////////////////

`timescale 1 ns / 1 ps

module GTP_CLKBUFG
(
    output CLKOUT,
    input CLKIN
);

    assign CLKOUT = CLKIN;

endmodule
