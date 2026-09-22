// Purpose: cold-reset, identify, program in standby, verify the complete RAW8
// profile, and only then enable capture. Runs on 27 MHz even if PCLK is absent.
// Failure latches until reset; never fall back silently to RGB565 or a pattern.
module ov5640_raw8_startup #(
 parameter SYS_CLK=27000000,SCCB_CLK=100000,
 parameter RESET_CYCLES=270000,BOOT_CYCLES=1080000,
 parameter WRITE_WAIT=27000,SOFT_RESET_WAIT=135000,SETTLE_CYCLES=1350000
)(
 input wire clk,rst_n,inout wire scl,sda,
 output wire reset_n,ready,failed,
 output reg [3:0] error_code,output reg [6:0] verify_index,
 output reg [7:0] last_read
);
 localparam HOLD=0,BOOT=1,ID_HI=2,ID_LO=3,PAD=4,BASE=5,
  PATCH=6,WAIT_WRITE=7,STREAM=8,SETTLE=9,VERIFY=10,CHECK_RUN=11,READY=12,FAIL=13;
 reg [3:0] state;
 reg [31:0] timer;
 reg pending,start,read_cmd;
 reg [23:0] command;
 wire done,error,busy;
 wire [7:0] read_data;
 wire base_start,base_done;
 wire [23:0] base_data,profile;
 wire profile_last;
 assign reset_n=rst_n && state!=HOLD && state!=FAIL;
 assign ready=state==READY;
 assign failed=state==FAIL;
 // Purpose: preserve the board-proven analog initialization, but keep streaming
 // disabled throughout it. The later explicit profile supersedes its 720p/RGB.
 wire [23:0] standby=base_data==24'h300802 ? 24'h300842 :
                          base_data==24'h310302 ? 24'h310303 : base_data;
 data_init #(.CNT_WAIT_MAX(WRITE_WAIT),.RESET_WAIT_MAX(SOFT_RESET_WAIT)) u_base(
  .sys_clk(clk),.sys_rst_n(rst_n && state==BASE),.cfg_end(done && !error && state==BASE),
  .cfg_start(base_start),.cfg_data(base_data),.cfg_done(base_done));
 ov5640_raw8_profile u_profile(.index(verify_index),.value(profile),.last(profile_last));
 ov5640_sccb #(.SYS_CLK(SYS_CLK),.SCCB_CLK(SCCB_CLK),.STRETCH_TIMEOUT(SYS_CLK/100)) u_bus(
  .clk(clk),.rst_n(rst_n && state!=HOLD && state!=FAIL),
  .sccb_start(state==BASE ? base_start : start),
  .data_in(state==BASE ? standby : command),
  .read_enable(state==BASE ? 1'b0 : read_cmd),.read_data(read_data),
  .SCL(scl),.SDA(sda),.sccb_done(done),.sccb_error(error),.busy(busy));
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin
   state<=HOLD;timer<=0;pending<=0;start<=0;read_cmd<=0;command<=0;
   verify_index<=0;last_read<=0;error_code<=0;
  end else begin
   start<=0;
   case(state)
    HOLD:if(timer==RESET_CYCLES-1)begin timer<=0;state<=BOOT;end else timer<=timer+1'b1;
    BOOT:if(timer==BOOT_CYCLES-1)begin timer<=0;state<=ID_HI;end else timer<=timer+1'b1;
    BASE:begin
     if(done && error)begin error_code<=3;state<=FAIL;end
     else if(base_done)begin verify_index<=0;state<=PATCH;end
    end
    WAIT_WRITE:if(timer==WRITE_WAIT-1)begin
     timer<=0;
     if(profile_last)state<=STREAM;
     else begin verify_index<=verify_index+1'b1;state<=PATCH;end
    end else timer<=timer+1'b1;
    SETTLE:if(timer==SETTLE_CYCLES-1)begin
     timer<=0;verify_index<=0;state<=VERIFY;
    end else timer<=timer+1'b1;
    READY:begin end
    FAIL:begin pending<=0;end
    default:begin
     if(!pending && !busy)begin
      pending<=1;start<=1;
      read_cmd<=state==ID_HI || state==ID_LO || state==VERIFY || state==CHECK_RUN;
      case(state)
       ID_HI:command<=24'h300a00;
       ID_LO:command<=24'h300b00;
       PAD:command<=24'h310311;
       PATCH:command<=profile;
       STREAM:command<=24'h300802;
       CHECK_RUN:command<=24'h300800;
       default:command<={profile[23:8],8'b0};
      endcase
     end else if(pending && done)begin
      pending<=0;last_read<=read_data;
      if(error)begin state<=FAIL;error_code<=1;end
      else case(state)
       ID_HI:if(read_data==8'h56)state<=ID_LO;else begin state<=FAIL;error_code<=2;end
       ID_LO:if(read_data==8'h40)state<=PAD;else begin state<=FAIL;error_code<=2;end
       PAD:state<=BASE;
       PATCH:begin timer<=0;state<=WAIT_WRITE;end
       STREAM:begin timer<=0;state<=SETTLE;end
       VERIFY:if(read_data!=profile[7:0])begin state<=FAIL;error_code<=4;end
              else if(profile_last)state<=CHECK_RUN;else verify_index<=verify_index+1'b1;
       CHECK_RUN:if((read_data & 8'hc0)==0)state<=READY;
                 else begin state<=FAIL;error_code<=5;end
       default:begin state<=FAIL;error_code<=6;end
      endcase
     end
    end
   endcase
  end
endmodule
