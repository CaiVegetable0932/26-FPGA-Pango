`timescale 1ns/1ps
// Purpose: verify startup pulse width, lock bounce and asynchronous shutdown
// with clocks stopped. This control-only bench makes no PLL/IO electrical claim.
module tb_video_clock_start;
    reg ref_clk=0, pixel_clk=0, ref_enabled=1, pixel_enabled=1;
    reg reset_n=0, locked=0;
    wire ref_reset_n, div_reset_n, ready, pixel_reset_n;
    integer checks=0, cycles, pulses, episode;
    always #5 if(ref_enabled) ref_clk=~ref_clk;
    always #7 if(pixel_enabled) pixel_clk=~pixel_clk;
    video_clock_start dut(ref_clk,pixel_clk,reset_n && locked,
        ref_reset_n,div_reset_n,ready,pixel_reset_n);

    // Comparative diagnostic baseline: the prior counter sampled lock only
    // on reference edges, and pixel reset had no asynchronous assertion. Zero
    // initialization represents PDS GRS, not an extra baseline reset mechanism.
    reg [7:0] baseline_count=0;
    reg [2:0] baseline_pixel_stages=0;
    always @(posedge ref_clk or negedge reset_n)
        if(!reset_n) baseline_count<=0;
        else if(!locked) baseline_count<=0;
        else if(baseline_count!=8'hff) baseline_count<=baseline_count+1'b1;
    always @(posedge pixel_clk)
        if(!(reset_n && locked && baseline_count==8'hff)) baseline_pixel_stages<=0;
        else baseline_pixel_stages<={baseline_pixel_stages[1:0],1'b1};

    // Four-state checks fail closed, including incomplete/unknown reset chains.
    task check(input bit condition, input string label);
        checks++;
        if(!condition) $fatal(1,"VIDEO_START_FAIL %s at %t",label,$time);
    endtask

    // Reference release is exactly three edges. Startup has exactly 65 low
    // pulse cycles, saturates, and releases consumers only on pixel edges.
    task start_episode;
        @(negedge ref_clk); #0.2; locked=1;
        for(cycles=1;cycles<=3;cycles++) begin
            @(posedge ref_clk); #0.05;
            check(ref_reset_n === (cycles==3),"reference release latency");
            check(pixel_reset_n===0,"no early pixel release");
        end
        pulses=0;
        for(cycles=1;cycles<=256;cycles++) begin
            @(posedge ref_clk); #0.05;
            check(div_reset_n === !(cycles>=80 && cycles<=144),"native pulse window");
            if(!div_reset_n) pulses++;
            if(cycles<255) check(ready===0 && pixel_reset_n===0,"startup barrier");
        end
        check(pulses==65 && ready===1,"pulse width and settling");
        repeat(4) @(posedge pixel_clk);
        #0.05; check(pixel_reset_n===1,"pixel release after settling");
        repeat(20) @(posedge ref_clk);
        #0.05; check(div_reset_n===1 && ready===1,"no repeated pulse while locked");
    endtask

    initial begin
        #0.1; reset_n=1; locked=1; #0.1; locked=0;
        #0.1; check(ref_reset_n===0 && pixel_reset_n===0,"initial assertion");
        start_episode();
        // Stop both clocks while consumers are live, then drop lock. Reset
        // must take effect without relying on an edge in either stopped domain.
        @(negedge ref_clk); ref_enabled=0;
        @(negedge pixel_clk); pixel_enabled=0;
        #0.37; locked=0; #0.05;
        check(ref_reset_n===0 && pixel_reset_n===0 && ready===0,"stopped-clock unlock");
        check(baseline_pixel_stages[2]===1,"baseline reproduces stale stopped-clock pixel release");
        $display("VIDEO_STOP_COMPARISON baseline_reset_n=%b candidate_reset_n=%b",
            baseline_pixel_stages[2],pixel_reset_n);
        locked=1; #100;
        check(ref_reset_n===0 && pixel_reset_n===0,"no stopped-clock release");
        locked=0; ref_enabled=1; pixel_enabled=1;
        start_episode();
        // Lock glitches before, inside and after the pulse restart the entire
        // sequence. No previous ready state survives into a new lock episode.
        for(episode=0;episode<3;episode++) begin
            #0.37; locked=0; #0.05;
            check(pixel_reset_n===0 && ready===0,"immediate readiness invalidation");
            locked=1;
            repeat(40+episode*60) @(posedge ref_clk);
            #0.37; locked=0; #0.05;
            check(pixel_reset_n===0 && ready===0,"startup interrupted");
            start_episode();
        end
        #0.37; reset_n=0; #0.05;
        check(ref_reset_n===0 && pixel_reset_n===0,"external reset after active video");
        $display("VIDEO_START_PASS checks=%0d full_starts=5",checks);
        $finish;
    end
    initial begin #100000; $fatal(1,"VIDEO_START_TIMEOUT"); end
endmodule
