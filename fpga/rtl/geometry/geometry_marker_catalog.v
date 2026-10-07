// Purpose: canonical integer source pixels and RGB colors from
// host/web/fisheye-preview.js markerPixels; rounding is positive Math.round.
module geometry_marker_catalog #(parameter WIDTH=1920,HEIGHT=1080)(
 input wire [4:0] index,output wire [15:0] x,y,output wire [23:0] color
);
 localparam R=WIDTH-1,B=HEIGHT-1,CX=WIDTH/2,CY=HEIGHT/2;
 localparam QX=(R+2)/4,QY=(B+2)/4,TX=(R+1)/3,TY=(B+1)/3;
 // A continuous function also evaluates for constant-index color instances.
 function [55:0] lookup;
  input [4:0] idx;reg [15:0] x,y;reg [23:0] color;
  begin
  x=0;y=0;color=0;
  case(idx)
   0:begin x=0;y=0;color=24'hff3864;end
   1:begin x=R;y=0;color=24'h00e5ff;end
   2:begin x=R;y=B;color=24'hffe600;end
   3:begin x=0;y=B;color=24'h58ff42;end
   4:begin x=CX;y=0;color=24'hff52ef;end
   5:begin x=R;y=CY;color=24'hff8b18;end
   6:begin x=CX;y=B;color=24'h7d9cff;end
   7:begin x=0;y=CY;color=24'h00ffb3;end
   8:begin x=CX;y=CY;color=24'hffffff;end
   9:begin x=QX;y=QY;color=24'hff4040;end
   10:begin x=R-QX;y=B-QY;color=24'h22dfff;end
   11:begin x=R-QX;y=QY;color=24'heeff00;end
   12:begin x=QX;y=B-QY;color=24'hff65ed;end
   13:begin x=QX;y=CY;color=24'hffb000;end
   14:begin x=R-QX;y=CY;color=24'h00ff74;end
   15:begin x=CX;y=QY;color=24'hbf80ff;end
   16:begin x=CX;y=B-QY;color=24'hff734d;end
   17:begin x=TX;y=TY;color=24'h00ffff;end
   18:begin x=R-TX;y=B-TY;color=24'hdfff00;end
   19:begin x=R-TX;y=TY;color=24'hff70c8;end
  endcase
  lookup={y,x,color};
  end
 endfunction
 assign {y,x,color}=lookup(index);
endmodule
