`timescale 1ns/1ps
// 用途：引脚级读回、读指针/读地址 NACK、拉伸、复位、忙时锁存及写后读测试。
module tb_ov5640_read;
    reg clk=0,rst_n=0,start=0,rd=0,stretch=0;
    always #5 clk=~clk;
    reg [23:0] data=0;
    reg [3:0] nack_byte=0;
    reg nack_read_address=0;
    tri1 scl,sda;
    wire done,error,busy; wire [7:0] value; wire [1:0] status;
    integer starts,stops,writes,reads,master_nacks,checks=0;
    assign scl=stretch ? 1'b0 : 1'bz;
    SCCB #(.SYS_CLK(3200),.SCCB_CLK(100),.STRETCH_TIMEOUT(80)) dut(
        .clk(clk),.rst_n(rst_n),.sccb_start(start),.sccb_read(rd),.data_in(data),
        .SCL(scl),.SDA(sda),.sccb_done(done),.sccb_error(error),.busy(busy),
        .read_data(value),.error_code(status));
    ov5640_sccb_model sensor(rst_n,scl,sda,nack_byte,nack_read_address,
        starts,stops,writes,reads,master_nacks);
    task check(input condition,input [511:0] label);
        begin checks=checks+1;if(condition!==1'b1)$fatal(1,"OV5640_READ_FAIL %0s",label);end
    endtask
    task reset_bus;
        begin rst_n=0;stretch=0;start=0;nack_byte=0;nack_read_address=0;
        repeat(8)@(negedge clk);rst_n=1;repeat(8)@(negedge clk);end
    endtask
    task issue(input read_op,input [23:0] payload);
        begin @(negedge clk);rd=read_op;data=payload;start=1;@(negedge clk);start=0;end
    endtask
    initial begin
        sensor.memory[16'h300a]=8'h56;sensor.memory[16'h300b]=8'h40;
        reset_bus;issue(1,24'h300a00);wait(busy);repeat(20)@(negedge clk);
        issue(0,24'hdeadbe);wait(done);#1;
        check(!error && value==8'h56,"read locks address/direction despite busy input");
        check(starts==2 && stops==1 && reads==1 && master_nacks==1 && writes==0,
              "repeated START, one STOP, master NACK, no accidental write");
        repeat(8)@(negedge clk);issue(1,24'h300b00);wait(done);#1;
        check(value==8'h40 && !error,"chip ID low byte");
        for(integer n=0;n<4;n=n+1)begin
            reset_bus;if(n==3)nack_read_address=1;else nack_byte=n+1;
            issue(1,24'h300a00);wait(done);#1;
            check(error && status==1 && !busy,"NACK from each transmitted read phase");
            check(reads==0 && writes==0,"NACK produces no read data transaction");
        end
        reset_bus;issue(1,24'h300a00);wait(busy);@(negedge scl);stretch=1;
        repeat(20)@(negedge clk);stretch=0;wait(done);#1;
        check(!error && value==8'h56,"bounded stretching succeeds");
        reset_bus;issue(1,24'h300a00);wait(busy);@(negedge scl);stretch=1;
        wait(done);#1;check(error && status==2 && !busy,"read stretching timeout");
        stretch=0;repeat(8)@(negedge clk);check(scl===1'b1 && sda===1'b1,"timeout releases lines");
        reset_bus;issue(1,24'h300a00);wait(busy);repeat(30)@(negedge clk);
        rst_n=0;repeat(8)@(negedge clk);check(!busy && scl===1'b1 && sda===1'b1,"reset abort releases bus");
        reset_bus;issue(0,24'h3501a5);wait(done);#1;check(!error && writes==1,"write still works");
        repeat(8)@(negedge clk);issue(1,24'h350100);wait(done);#1;
        check(!error && value==8'ha5,"write then read same register");
        $display("OV5640_READ_PASS checks=%0d",checks);$finish;
    end
    initial begin #1000000;$fatal(1,"OV5640_READ_TIMEOUT");end
endmodule
