`timescale 1ns/1ps
// Purpose: cycle-exact queue candidate/reference comparison, including full
// throughput, pointer wrap, all occupancy levels and reset/epoch flushes.
module tb_mcu_reply_queue_ram;
    reg clk=0,rst_n=0,flush=0,write=0,pop=0;
    reg [279:0] write_data=0;
    wire [279:0] front;
    wire [3:0] count;
    reg [279:0] reference [0:7];
    integer rptr=0,wptr=0,used=0,checks=0,n,j;
    integer occupancy[0:8];
    mcu_reply_queue_ram dut(.*);
    always #4 clk=~clk;
    // The oracle retains the original asynchronous ring-buffer behavior;
    // it does not share the candidate's head/lookahead implementation.
    task step(input bit wr,input bit rd,input bit clear_queue);
        begin
            @(negedge clk);
            write=wr;pop=rd;flush=clear_queue;
            for(j=0;j<9;j=j+1)write_data=(write_data<<32)|$unsigned($random);
            if(!clear_queue && ((wr && used==8 && !rd)||(rd && used==0)))
                $fatal(1,"QUEUE_TEST_INVALID_STIMULUS");
            @(posedge clk);
            if(clear_queue)begin used=0;rptr=0;wptr=0;end
            else begin
                if(rd)begin rptr=(rptr+1)%8;used=used-1;end
                if(wr)begin reference[wptr]=write_data;wptr=(wptr+1)%8;used=used+1;end
            end
            #1;
            if(count!==used || (used!=0 && front!==reference[rptr]))
                $fatal(1,"QUEUE_RAM_FAIL check=%0d count=%0d expected=%0d",checks,count,used);
            checks=checks+1;occupancy[used]=occupancy[used]+1;
        end
    endtask
    initial begin
        for(n=0;n<9;n=n+1)occupancy[n]=0;
        repeat(3)@(posedge clk);@(negedge clk);rst_n=1;
        // Exercise the exact empty->single->replace->empty bypass boundaries.
        step(1,0,0);
        repeat(256)step(1,1,0);
        step(0,1,0);
        // Keep every slot occupied while both pointers repeatedly wrap.
        repeat(8)step(1,0,0);
        repeat(1024)step(1,1,0);
        repeat(8)step(0,1,0);
        // An asynchronous reset must discard a full queue without clearing
        // RAM contents; later writes must never expose the abandoned words.
        repeat(8)step(1,0,0);
        @(negedge clk);write=0;pop=0;rst_n=0;
        #1;if(count!==0)$fatal(1,"QUEUE_RAM_RESET_FAIL");
        used=0;rptr=0;wptr=0;
        repeat(2)@(posedge clk);@(negedge clk);rst_n=1;
        for(n=0;n<100000;n=n+1)begin
            if(n%997==0)step(0,0,1);
            else if(used==0)step($urandom_range(0,1),0,0);
            else if(used==8)step(0,$urandom_range(0,1),0);
            else step($urandom_range(0,1),$urandom_range(0,1),0);
        end
        for(n=0;n<9;n=n+1)if(occupancy[n]==0)$fatal(1,"QUEUE_RAM_MISSING_OCCUPANCY");
        $display("QUEUE_RAM_EQUIVALENCE_PASS checks=%0d",checks);$finish;
    end
    initial begin #2000000;$fatal(1,"QUEUE_RAM_TIMEOUT");end
endmodule
