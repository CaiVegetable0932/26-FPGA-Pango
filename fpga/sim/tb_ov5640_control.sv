`timescale 1ns/1ps
// 用途：事务级寄存器模拟器验证固定组顺序/保留位/身份/时序/故障门控与查询。
// 通过不代表传感器原子提交、真实行时间或消条纹已经验证。
module tb_ov5640_control;
    reg clk=0,rst_n=0,table_done=0;
    always #5 clk=~clk;
    wire tx_start,tx_read; wire [23:0] tx_data;
    reg tx_done=0; reg [1:0] tx_error=0;reg [7:0] tx_value=0;
    reg query_start=0;reg [15:0] query_addr=0;
    wire ready,qready,qdone,rejected,svalid;
    wire [31:0] version,scycle;wire [2:0] fault,qstatus;
    wire [15:0] faddr,saddr;wire [7:0] qvalue,svalue;
    reg [7:0] memory[0:65535];
    reg [15:0] inject_addr=0;reg [1:0] inject_error=0;reg mismatch=0,late_mismatch=0;
    integer delay_count=0,writes=0,checks=0,snapshots=0;
    reg [23:0] pending;reg pending_read;
    ov5640_control #(.FIXED_MODE(1),.EXPOSURE(20'h01001),.GAIN(10'h020),
        .WB_R(12'h456),.WB_G(12'h400),.WB_B(12'h567),
        .EXPECT_HTS(16'h09c0),.EXPECT_VTS(16'h04c8)) dut(
        .clk(clk),.rst_n(rst_n),.table_done(table_done),
        .tx_start(tx_start),.tx_read(tx_read),.tx_data(tx_data),
        .tx_done(tx_done),.tx_error(tx_error),.tx_value(tx_value),
        .query_start(query_start),.query_addr(query_addr),.query_ready(qready),
        .query_done(qdone),.query_rejected(rejected),.query_value(qvalue),.query_status(qstatus),
        .capture_ready(ready),.config_version(version),.fault(fault),.fault_addr(faddr),
        .snapshot_valid(svalid),.snapshot_addr(saddr),.snapshot_value(svalue),.snapshot_cycle(scycle));
    // 延迟应答模型：不读取 DUT 状态，仅根据公开事务请求读写 memory。
    always @(posedge clk)begin
        tx_done<=0;
        if(!rst_n)begin delay_count<=0;tx_error<=0;end
        else if(tx_start)begin pending<=tx_data;pending_read<=tx_read;delay_count<=3;end
        else if(delay_count>0)begin
            delay_count<=delay_count-1;
            if(delay_count==1)begin
                tx_done<=1;tx_error<=pending[23:8]==inject_addr ? inject_error : 0;
                tx_value<=memory[pending[23:8]] ^ ((mismatch && pending[23:8]==16'h3501) ? 8'h01 : 0);
                if(!pending_read)begin
                    if(pending[23:8]==16'h300a || pending[23:8]==16'h300b)$fatal(1,"WRITE_TO_ID");
                    memory[pending[23:8]]=pending[7:0];writes=writes+1;
                    // 最后一项写完才破坏先前已回读的曝光字节，检验最终整组快照。
                    if(late_mismatch && writes==16)memory[16'h3501]=memory[16'h3501]^8'h01;
                end
            end
        end
        if(svalid)snapshots=snapshots+1;
    end
    task check(input condition,input [511:0] label);
        begin checks=checks+1;if(condition!==1'b1)$fatal(1,"OV5640_CONTROL_FAIL %0s",label);end
    endtask
    task setup;
        begin rst_n=0;table_done=0;query_start=0;inject_addr=0;inject_error=0;mismatch=0;late_mismatch=0;
        repeat(5)@(negedge clk);
        for(integer i=0;i<65536;i=i+1)memory[i]=0;
        memory[16'h300a]=8'h56;memory[16'h300b]=8'h40;
        memory[16'h380c]=8'h09;memory[16'h380d]=8'hc0;
        memory[16'h380e]=8'h04;memory[16'h380f]=8'hc8;
        memory[16'h3808]=8'h05;memory[16'h3809]=0;
        memory[16'h380a]=8'h02;memory[16'h380b]=8'hd0;
        memory[16'h4300]=8'h61;memory[16'h501f]=1;
        memory[16'h3503]=8'ha0;memory[16'h3a00]=8'hfc;
        memory[16'h3500]=8'hb0;memory[16'h350a]=8'hc0;
        memory[16'h350c]=1;memory[16'h350d]=2;
        memory[16'h3406]=8'h80;memory[16'h3400]=8'ha0;
        memory[16'h3402]=8'hb0;memory[16'h3404]=8'hc0;
        writes=0;snapshots=0;rst_n=1;end
    endtask
    task boot;
        begin table_done=1;wait(qready);#1;end
    endtask
    task query(input [15:0] address);
        begin @(negedge clk);query_start=1;query_addr=address;@(negedge clk);query_start=0;end
    endtask
    initial begin
        setup;repeat(20)@(negedge clk);check(!ready && writes==0,"wait for initialization ownership");
        table_done=1;query(16'h300b);#1;check(rejected,"busy boot rejects query");wait(qready);#1;
        check(ready && version==1 && fault==0 && writes==16 && snapshots==72,"verified fixed group publishes once");
        check(memory[16'h3503]==8'ha3 && memory[16'h3a00]==8'hf8,"read-modify-write preserves unrelated bits");
        check(memory[16'h3500]==8'hb0 && memory[16'h3501]==8'h10 && memory[16'h3502]==1,"fractional exposure encoding");
        check(memory[16'h350a]==8'hc0 && memory[16'h350b]==8'h20,"fixed gain preserves high debug bits");
        check(memory[16'h350c]==0 && memory[16'h350d]==0,"remove AEC extra lines");
        check(memory[16'h3406]==8'h81 && memory[16'h3400]==8'ha4 && memory[16'h3401]==8'h56,
              "explicit WB freezes and preserves unrelated bits");
        query(16'h3502);query(16'h300a);#1;check(rejected,"busy query rejected");
        wait(qdone);#1;check(qvalue==1 && qstatus==0 && ready && version==1,"query latches address and leaves version intact");
        repeat(4)@(negedge clk);inject_addr=16'h300a;inject_error=2;query(16'h300a);
        wait(qdone);#1;check(qstatus==2 && ready && version==1,"runtime query timeout reported separately");
        setup;memory[16'h300b]=8'h41;boot;check(!ready && fault==4 && writes==0 && version==0,"wrong ID stops before writes");
        setup;memory[16'h380d]=8'hc1;boot;check(!ready && fault==5 && writes==0,"timing mismatch rejects profile");
        setup;memory[16'h380e]=0;memory[16'h380f]=1;boot;check(!ready && fault==5 && writes==0,"VTS margin rejects too-small frame");
        setup;inject_addr=16'h300a;inject_error=1;boot;check(!ready && fault==1 && faddr==16'h300a,"snapshot NACK blocks capture");
        setup;inject_addr=16'h350b;inject_error=2;boot;check(!ready && fault==2 && version==0,"write-stage timeout publishes no version");
        setup;mismatch=1;boot;check(!ready && fault==3 && faddr==16'h3501 && version==0,"readback mismatch locks capture");
        setup;late_mismatch=1;boot;
        check(!ready && fault==3 && writes==16 && version==0,"final snapshot catches late register drift");
        repeat(50)@(negedge clk);check(!ready && version==0,"failure remains closed until reset");
        $display("OV5640_CONTROL_PASS checks=%0d",checks);$finish;
    end
    initial begin #1000000;$fatal(1,"OV5640_CONTROL_TIMEOUT");end
endmodule
