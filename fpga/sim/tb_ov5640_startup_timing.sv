`timescale 1ns/1ps
// Purpose: run the production 27-MHz parameters, independently measure RESETB,
// first SCCB access and software-reset gap at sensor pins. No accelerated delays.
module tb_ov5640_startup_timing;
    reg clk=0,rst_n=0;
    always #18.518518 clk=~clk;
    tri1 scl,sda;
    wire sensor_reset,ready,failed;wire [3:0] error,index;
    wire [7:0] last_read,run_reg;
    integer writes,reads,starts,checks=0;
    realtime reset_start,reset_release,soft_reset_time;
    reg first_access=1,soft_reset_seen=0;
    ov5640_startup dut(.clk(clk),.rst_n(rst_n),.scl(scl),.sda(sda),
        .reset_n(sensor_reset),.ready(ready),.failed(failed),
        .error_code(error),.verify_index(index),.last_read(last_read));
    ov5640_register_model model(sensor_reset,scl,sda,0,writes,reads,starts,run_reg);
    always @(posedge sensor_reset) if(rst_n) begin
        reset_release=$realtime;checks=checks+1;
        if(reset_release-reset_start<9999000) $fatal(1,"TIMING_FAIL RESETB hold");
    end
    always @(negedge sda) if(sensor_reset && scl===1'b1 && first_access) begin
        first_access=0;checks=checks+1;
        if($realtime-reset_release<39999000) $fatal(1,"TIMING_FAIL boot wait");
    end
    always @(run_reg) begin
        if(run_reg==8'h82) begin soft_reset_time=$realtime;soft_reset_seen=1;end
        if(run_reg==8'h42 && soft_reset_seen) begin
            checks=checks+1;
            if($realtime-soft_reset_time<4999000) $fatal(1,"TIMING_FAIL software reset gap");
        end
    end
    initial begin
        repeat(10)@(negedge clk);reset_start=$realtime;rst_n=1;
        wait(ready || failed);#1;
        if(!ready || failed || writes!=247 || reads!=16 || checks!=3)
            $fatal(1,"TIMING_FAIL startup incomplete");
        $display("OV5640_STARTUP_TIMING_PASS checks=%0d elapsed_ms=%f writes=%0d reads=%0d",
            checks,($realtime-reset_start)/1000000,writes,reads);$finish;
    end
    initial begin #1000000000;$fatal(1,"TIMING_TIMEOUT");end
endmodule
