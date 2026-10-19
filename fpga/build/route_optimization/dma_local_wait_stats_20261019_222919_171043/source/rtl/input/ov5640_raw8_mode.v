`timescale 1ns/1ps
// 用途：将明确的 RAW8 模式实体逐寄存器提交到读改写/校验服务，不继承720p时钟常量。
// 完整模拟/读回仍不是实物1080p30证明；输入必须由07按XCLK、有效位/裁剪及01时序核验。
// 501f selection must be explicit at integration: 4 is SNR RAW; the historical
// MINI DVP profile uses 3 (ISP RAW with sensor processing disabled separately)
// to retain the output crop. Register readback alone does not prove pixel size.
module ov5640_raw8_mode #(parameter GROUP_TIMEOUT=27000000,parameter [7:0] RAW_OUTPUT_SELECT=8'h04)(
 input wire clk,rst_n,quiesced,input wire apply,output wire apply_ready,
 input wire [15:0] width,height,hts,vts,x_start,y_start,x_end,y_end,x_offset,y_offset,
 input wire [7:0] pll3034,pll3035,pll3036,pll3037,root3108,x_inc,y_inc,flip3820,mirror3821,
 input wire [2:0] bayer_code,input wire [19:0] exposure,input wire [9:0] gain,
 input wire [31:0] requested_version,parameter_entity,
 output reg cmd_valid,input wire cmd_ready,output wire cmd_write,
 output reg [15:0] cmd_addr,output reg [7:0] cmd_value,cmd_mask,
 output wire [31:0] cmd_cookie,input wire rsp_valid,input wire [2:0] rsp_status,
 input wire [7:0] rsp_value,input wire [31:0] rsp_cookie,
 output reg done,rejected,output reg [2:0] status,output reg mode_ready,
 output reg [31:0] active_version,active_entity
);
 localparam IDLE=0,SEND=1,WAIT=2;reg [1:0] state;
 reg [5:0] index;reg [1:0] phase;reg [31:0] saved_version,saved_entity;
 reg [31:0] deadline;
 reg [31:0] entry[0:42]; // {address,value,mask}，提交时锁存，忙时参数输入不能改变本组。
 assign apply_ready=state==IDLE && cmd_ready;assign cmd_write=phase==1;assign cmd_cookie={24'b0,phase,index};
 // mode_ready 只在整个配置组成功时置1；任何部分失败保持关闭，需完整重提交或复位。
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=IDLE;index<=0;phase<=0;deadline<=0;cmd_valid<=0;cmd_addr<=0;cmd_value<=0;cmd_mask<=0;
   done<=0;rejected<=0;status<=0;mode_ready<=0;active_version<=0;active_entity<=0;
   saved_version<=0;saved_entity<=0;
  end else begin
   cmd_valid<=0;done<=0;rejected<=apply && !apply_ready;
   if(state!=IDLE)deadline<=deadline+1'b1;else deadline<=0;
   // 组级期限独立于单寄存器服务，避免消费者永远不给 cmd_ready/rsp_valid。
   if(state!=IDLE && (!quiesced || deadline>=GROUP_TIMEOUT-1))begin
    state<=IDLE;done<=1;status<=!quiesced ? 6 : 2;mode_ready<=0;
   end else case(state)
   IDLE:if(apply && apply_ready)begin
    mode_ready<=0;status<=0;
    if(!quiesced)begin done<=1;status<=6;end
    else if((RAW_OUTPUT_SELECT!=3 && RAW_OUTPUT_SELECT!=4) ||
       width!=1920 || height!=1080 || hts<width || vts<height+4 ||
       x_end<x_start || y_end<y_start || x_end-x_start+1<width || y_end-y_start+1<height ||
       bayer_code<1 || bayer_code>4 || exposure==0 || exposure>(vts-4)*16 || gain<16 ||
       hts>8191 || x_start>4095 || y_start>4095 || x_end>4095 || y_end>2047 ||
       x_offset>4095 || y_offset>2047 || mirror3821[5] || mirror3821[0] ||
       pll3036<4 || pll3036>252 || (pll3036>=128 && pll3036[0]) ||
       (pll3037[3:0]!=1 && pll3037[3:0]!=2 && pll3037[3:0]!=3 &&
        pll3037[3:0]!=4 && pll3037[3:0]!=6 && pll3037[3:0]!=8) || (pll3034[3:0]!=8 && pll3034[3:0]!=10) ||
       x_inc!=8'h11 || y_inc!=8'h11)begin done<=1;status<=5;end
    else begin
     // 依手册保留 timing/debug 高位，不把16位参数宽度当作所有寄存器的有效位宽。
     // PLL/HTS/VTS/裁剪由实体提供；RAW tap由工程参数明确选择，不据寄存器值宣称30fps。
     entry[0]<={16'h3034,pll3034,8'h0f};entry[1]<={16'h3035,pll3035,8'hff};
     entry[2]<={16'h3036,pll3036,8'hff};entry[3]<={16'h3037,pll3037,8'h1f};
     entry[4]<={16'h3108,root3108,8'h03};
     entry[5]<={16'h3800,x_start[15:8],8'h0f};entry[6]<={16'h3801,x_start[7:0],8'hff};
     entry[7]<={16'h3802,y_start[15:8],8'h0f};entry[8]<={16'h3803,y_start[7:0],8'hff};
     entry[9]<={16'h3804,x_end[15:8],8'h0f};entry[10]<={16'h3805,x_end[7:0],8'hff};
     entry[11]<={16'h3806,y_end[15:8],8'h07};entry[12]<={16'h3807,y_end[7:0],8'hff};
     entry[13]<={16'h3808,width[15:8],8'h0f};entry[14]<={16'h3809,width[7:0],8'hff};
     entry[15]<={16'h380a,height[15:8],8'h07};entry[16]<={16'h380b,height[7:0],8'hff};
     entry[17]<={16'h380c,hts[15:8],8'h1f};entry[18]<={16'h380d,hts[7:0],8'hff};
     entry[19]<={16'h380e,vts[15:8],8'hff};entry[20]<={16'h380f,vts[7:0],8'hff};
     entry[21]<={16'h3810,x_offset[15:8],8'h0f};entry[22]<={16'h3811,x_offset[7:0],8'hff};
     entry[23]<={16'h3812,y_offset[15:8],8'h07};entry[24]<={16'h3813,y_offset[7:0],8'hff};
     entry[25]<={16'h3814,x_inc,8'hff};entry[26]<={16'h3815,y_inc,8'hff};
     entry[27]<={16'h3820,flip3820,8'h06};entry[28]<={16'h3821,mirror3821,8'h27};
     // 4300 序列0/1/2/3对应BGGR/GBRG/GRBG/RGGB；外部 bayer_code 为1/2/3/4。
     entry[29]<={16'h4300,(8'd4-{5'b0,bayer_code}),8'hff};
     entry[30]<={16'h501f,RAW_OUTPUT_SELECT,8'h07};
     entry[31]<=32'h35030303;entry[32]<=32'h3a000004;
     entry[33]<=32'h350c00ff;entry[34]<=32'h350d00ff;
     entry[35]<={16'h3500,4'b0,exposure[19:16],8'h0f};
     entry[36]<={16'h3501,exposure[15:8],8'hff};entry[37]<={16'h3502,exposure[7:0],8'hff};
     entry[38]<={16'h350a,6'b0,gain[9:8],8'h03};entry[39]<={16'h350b,gain[7:0],8'hff};
     // 显式DVP极性/引脚使能。实际驱动边沿与采样窗口必须由01签核后给出。
     entry[40]<=32'h3017ffff;entry[41]<=32'h3018ffff;
     entry[42]<=32'h47400003; // HREF高、VSYNC高消隐；保留PCLK输出沿等其他位。
     saved_version<=requested_version;saved_entity<=parameter_entity;index<=0;phase<=0;state<=SEND;
    end
   end
   SEND:if(cmd_ready)begin
    // 首先核验ID和PLL旁路；整组写后再次读全部43项，避免后续写破坏此前已校验值。
    cmd_addr<=phase==0 ? (index==2 ? 16'h3039 : 16'h300a+index) : entry[index][31:16];
    cmd_value<=phase==1 ? entry[index][15:8] : 0;
    cmd_mask<=phase==1 ? entry[index][7:0] : 0;
    cmd_valid<=1;state<=WAIT;
   end
   WAIT:if(rsp_valid)begin
    if(rsp_status!=0)begin done<=1;status<=rsp_status;state<=IDLE;mode_ready<=0;end
    else if(rsp_cookie!=cmd_cookie)begin done<=1;status<=5;state<=IDLE;end
    else if(phase==0)begin
     if((index==0 && rsp_value!=8'h56) || (index==1 && rsp_value!=8'h40))begin
      done<=1;status<=4;state<=IDLE;
     end else if(index==2 && rsp_value[7])begin done<=1;status<=5;state<=IDLE;end
     else if(index==2)begin phase<=1;index<=0;state<=SEND;end
     else begin index<=index+1'b1;state<=SEND;end
    end else if(phase==2 && (rsp_value & entry[index][7:0])!=(entry[index][15:8] & entry[index][7:0]))begin
     done<=1;status<=3;state<=IDLE;
    end else if(index==42)begin
     if(phase==1)begin phase<=2;index<=0;state<=SEND;end
     else begin done<=1;state<=IDLE;mode_ready<=1;active_version<=saved_version;active_entity<=saved_entity;end
    end else begin index<=index+1'b1;state<=SEND;end
   end
   default:begin state<=IDLE;done<=1;status<=2;mode_ready<=0;end
   endcase
  end
 end
endmodule
