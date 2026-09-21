`timescale 1ns/1ps
// Purpose: exercise the shared input stage and actual capture diagnostics with
// independently controlled configuration and DDR readiness; assert pixel contents.
module tb_capture_status;
 reg clk=0,rst_n=0,v=1,h=0,cfg=0,ddr=0;
 always #5 clk=~clk;
 wire sv,sh,wr;wire [7:0] sd,status;wire [15:0] pixel;
 integer writes=0,row;
 mini_dvp_input input_stage(clk,rst_n,v,h,8'ha5,sv,sh,sd);
 camera_data #(.FRAME_WIDTH(4),.FRAME_HEIGHT(2),.WARMUP_FRAMES(1)) dut(
 .clk(clk),.rst_n(rst_n),.vsync(sv),.href(sh),.din(sd),.cfg_done(cfg),.ddr_init(ddr),
 .pixel_data(pixel),.wf_wr_en(wr),.sop(),.eop(),.vs(),.hs(),.capture_status(status));
 task tick(input bit nv,input bit nh);
 begin @(negedge clk);v=nv;h=nh;@(posedge clk);#1;
 if(wr)begin writes=writes+1;if(pixel!==16'ha5a5)$fatal(1,"STATUS_FAIL pixel alignment");end
 end endtask
 task frame;
 begin repeat(5)tick(1,0);tick(0,0);
 for(row=0;row<2;row=row+1)begin repeat(8)tick(0,1);repeat(2)tick(0,0);end
 repeat(5)tick(1,0);end endtask
 initial begin
 repeat(5)tick(1,0);rst_n=1;repeat(5)tick(1,0);
 if(status!==8'h01)$fatal(1,"STATUS_FAIL reset/config gates");
 cfg=1;frame();
 if(writes!=0 || status!==8'h3b)$fatal(1,"STATUS_FAIL DDR must block despite warmed");
 ddr=1;frame();
 if(writes!=8 || status!==8'h7f)$fatal(1,"STATUS_FAIL frame admission");
 // An odd short row sets the sticky fault bit without joining subsequent bytes.
 tick(0,0);tick(0,1);repeat(4)tick(0,0);
 if(status!==8'hff)$fatal(1,"STATUS_FAIL short-line flag");
 rst_n=0;tick(1,0);if(status!==0)$fatal(1,"STATUS_FAIL reset clearing");
 $display("CAPTURE_STATUS_PASS accepted_pixels=%0d",writes);$finish;
 end
 initial begin #100000;$fatal(1,"STATUS_TIMEOUT");end
endmodule
