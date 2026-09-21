`timescale 1ns/1ps
// Purpose: pin-level sensor register model; decode SCL/SDA rather than observing
// DUT FSM state. Supports a 16-bit pointer write, separate read, ACK and NA checking.
module ov5640_register_model(input wire reset_n,scl,inout wire sda,
    input integer fault, output integer writes,reads,starts,
    output reg [7:0] run_register);
    reg drive_low=0, active=0, sending=0, read_address=0;
    reg [7:0] shift=0, memory[0:65535], send_data;
    reg [15:0] pointer=0;
    integer bits=0, byte_number=0, i;
    assign sda=drive_low ? 1'b0 : 1'bz;
    initial begin
        writes=0;reads=0;starts=0;run_register=8'h42;
        for(i=0;i<65536;i=i+1) memory[i]=0;
    end
    always @(negedge reset_n) begin
        drive_low=0;active=0;sending=0;bits=0;byte_number=0;read_address=0;
        memory[16'h3008]=8'h42;run_register=8'h42;
    end
    always @(negedge sda) if(reset_n && scl===1'b1) begin
        active=1;sending=0;read_address=0;bits=0;byte_number=0;shift=0;starts=starts+1;
    end
    always @(posedge sda) if(reset_n && scl===1'b1 && active) active=0;
    always @(posedge scl) if(reset_n && active) begin
        if(sending) begin
            if(bits==8) begin
                if(sda!==1'b1) $fatal(1,"MODEL_FAIL master did not terminate read with NA");
                reads=reads+1;active=0;
            end else bits=bits+1;
        end else if(bits<8) begin
            shift={shift[6:0],sda};bits=bits+1;
            if(bits==8) begin
                case(byte_number)
                    0: begin
                        if(shift!=8'h78 && shift!=8'h79) $fatal(1,"MODEL_FAIL device address");
                        read_address=shift[0];
                    end
                    1: pointer[15:8]=shift;
                    2: pointer[7:0]=shift;
                    3: begin
                        if(pointer==16'h300a || pointer==16'h300b) $fatal(1,"MODEL_FAIL wrote ID");
                        // Configuration must remain in standby until the final stream-on.
                        if(pointer==16'h3008) begin run_register=shift; end
                        else if(pointer!=16'h3103 && !run_register[6])
                            $fatal(1,"MODEL_FAIL configured while streaming");
                        memory[pointer]=shift;writes=writes+1;
                    end
                    default: $fatal(1,"MODEL_FAIL excess write bytes");
                endcase
            end
        end else begin bits=0;byte_number=byte_number+1; end
    end
    // Purpose: ACK and read bits change only while clock is low; no drive-high shortcut.
    always @(negedge scl) begin
        if(!reset_n || !active) drive_low=0;
        else if(sending) drive_low=bits<8 ? !send_data[7-bits] : 0;
        else if(bits==8) drive_low=fault!=2 && !(fault==5 && read_address);
        // A slave that NACKed its read address must not subsequently drive read data.
        else if(read_address && byte_number==1 && fault!=5 && fault!=2) begin
            sending=1;
            if(pointer==16'h300a) send_data=fault==1 ? 8'h00 : 8'h56;
            else if(pointer==16'h300b) send_data=8'h40;
            else if(pointer==16'h3808 && fault==3) send_data=8'h04;
            // Purpose: emulate a sensor that did not accept the source-clock divider.
            else if(pointer==16'h3035 && fault==6) send_data=8'h11;
            else send_data=memory[pointer];
            drive_low=!send_data[7];
        end else drive_low=0;
    end
endmodule

// Purpose: stress the new bidirectional controller independently of startup policy,
// including input latching, all-zero/all-one read data, read-address NACK and stretch timeout.
module tb_ov5640_sccb_read;
    reg clk=0,rst_n=0,start=0,read_enable=0,stretch=0;
    reg [23:0] data_in=0;
    always #5 clk=~clk;
    tri1 scl,sda;
    assign scl=stretch ? 1'b0 : 1'bz;
    wire done,error,busy;wire [7:0] read_data,run_reg;
    integer fault=0,writes,reads,starts,checks=0;
    ov5640_sccb #(.SYS_CLK(3200),.SCCB_CLK(100),.STRETCH_TIMEOUT(80)) dut(
        .clk(clk),.rst_n(rst_n),.sccb_start(start),.data_in(data_in),
        .read_enable(read_enable),.read_data(read_data),.SCL(scl),.SDA(sda),
        .sccb_done(done),.sccb_error(error),.busy(busy));
    ov5640_register_model model(rst_n,scl,sda,fault,writes,reads,starts,run_reg);
    task check(input bit c,input string label);
        begin checks=checks+1;if(!c)$fatal(1,"READ_FAIL %s",label);end
    endtask
    task issue(input bit r,input [23:0] d);
        begin repeat(8)@(negedge clk);read_enable=r;data_in=d;start=1;
              @(negedge clk);start=0;end
    endtask
    task pair(input [7:0] value);
        begin
            $display("READ_CASE value=%h time=%t",value,$time);
            issue(0,{16'h1234,value});wait(done);#1;check(!error,"write ACK");
            issue(1,24'h123400);
            // Deliberately change live inputs while busy; the accepted transaction is immutable.
            repeat(20)@(negedge clk);read_enable=0;data_in=24'hdeadbe;start=1;
            @(negedge clk);start=0;
            wait(done);#1;check(!error && read_data===value,"read data and latched request");
        end
    endtask
    initial begin
        repeat(8)@(negedge clk);rst_n=1;
        pair(8'h00);pair(8'hff);pair(8'haa);pair(8'h55);
        check(writes==4 && reads==4 && starts==12,"exact write/address/read cycle counts");
        $display("READ_CASE read-address-NACK time=%t",$time);
        fault=5;issue(1,24'h300a00);wait(done);#1;
        check(error && !busy,"read device-address NACK");fault=0;
        $display("READ_CASE stretch time=%t scl=%b sda=%b",$time,scl,sda);
        issue(1,24'h300a00);wait(busy);@(negedge scl);stretch=1;
        wait(done);#1;check(error && !busy && sda===1'b1,"stretch timeout releases SDA");
        stretch=0;repeat(8)@(negedge clk);check(scl===1'b1,"timeout releases SCL");
        $display("OV5640_SCCB_READ_PASS checks=%0d",checks);$finish;
    end
    initial begin #1000000;$fatal(1,"READ_TIMEOUT");end
endmodule

// Purpose: exercise the actual startup/table/SCCB chain, including three bounded
// attempts and fail-closed behavior. Reduced timing parameters accelerate logic tests.
module tb_ov5640_verified_startup;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    tri1 scl,sda;
    integer fault=0,writes,reads,starts,checks=0;
    wire sensor_reset,ready,failed; wire [3:0] error,index;wire [7:0] last_read,run_reg;
    ov5640_startup #(.SYS_CLK(32000),.SCCB_CLK(1000),.RESET_CYCLES(20),
        .BOOT_CYCLES(40),.WRITE_WAIT(16),.SOFT_RESET_WAIT(80),.SETTLE_CYCLES(50)) dut(
        .clk(clk),.rst_n(rst_n),.scl(scl),.sda(sda),.reset_n(sensor_reset),
        .ready(ready),.failed(failed),.error_code(error),.verify_index(index),.last_read(last_read));
    ov5640_register_model model(sensor_reset,scl,sda,fault,writes,reads,starts,run_reg);
    task check(input bit condition,input string label);
        begin checks=checks+1;if(!condition)$fatal(1,"STARTUP_FAIL %s",label);end
    endtask
    task reset_case(input integer f);
        begin rst_n=0;fault=f;repeat(10)@(negedge clk);rst_n=1;end
    endtask
    integer previous_writes,previous_starts;
    initial begin
        reset_case(0);wait(ready || failed);#1;
        check(ready && !failed && error==0,"verified startup succeeds");
        check(writes==247 && reads==16,"247 writes and 16 successful readbacks");
        check(run_reg==8'h02 && index==13,"stream enabled and complete readback");
        // Purpose: verify the on-wire clock change, not just the DUT's expected value.
        check(model.memory[16'h3035]==8'h21,"system divider is two, MIPI divider unchanged");
        previous_starts=starts;repeat(1000)@(negedge clk);
        check(starts==previous_starts,"no transactions after ready");
        previous_writes=writes;previous_starts=starts;
        reset_case(1);wait(failed);#1;
        check(!ready && error==2 && writes==previous_writes,"wrong ID blocks all configuration");
        check(starts-previous_starts==6,"wrong ID has exactly three two-cycle reads");
        previous_starts=starts;reset_case(2);wait(failed);#1;
        check(!ready && error==1 && starts-previous_starts==3,"NACK bounded retries");
        reset_case(3);wait(failed);#1;
        check(!ready && error==4 && index==1 && last_read==4,"readback mismatch fails closed");
        previous_starts=starts;repeat(1000)@(negedge clk);
        check(starts==previous_starts && !sensor_reset,"terminal fault holds sensor reset");
        reset_case(6);wait(failed);#1;
        check(!ready && error==4 && index==10 && last_read==8'h11,
              "rejected source-clock divider fails closed");
        reset_case(0);wait(ready || failed);#1;
        check(ready && !failed,"external reset recovers from fault");
        $display("OV5640_VERIFIED_STARTUP_PASS checks=%0d",checks);$finish;
    end
    initial begin #50000000;$fatal(1,"STARTUP_TIMEOUT");end
endmodule
