`timescale 1ns/1ps
`default_nettype none

// Purpose: native functional equivalence of one BUFG and two same-source
// BUFGs. Ideal eth_raw represents one PLL output, not a simulated PLL or
// routed clock tree. Both packet producers register on their fabric clock.
module tb_rgmii_dedicated_clock;
    reg eth_raw=0, reset_n=0, grs_n=0;
    wire old_clk, eth_clk, eth_tx_clk;
    reg [7:0] stimulus=0, old_gmii=0, new_gmii=0;
    reg stimulus_en=0, stimulus_er=0, old_en=0, new_en=0, old_er=0, new_er=0;
    integer stimulus_kind=-1, producer_kind=-1;
    wire old_txc,new_txc,old_ctl,new_ctl;
    wire [3:0] old_data,new_data;
    integer checks=0,errors=0,vectors=0,random_vectors=0,resets=0;
    integer phase_edges=0,txc_rises=0,txc_falls=0,reset_txc_edges=0;
    integer coverage[0:1][0:3][0:255];
    integer pending_kind=-1,active_kind=-1,trace;
    reg [7:0] pending_data=0,active_data=0;
    reg [3:0] observed_low=0;
    reg pending_en=0,pending_er=0,active_en=0,active_er=0,rising_ctl=0;
    reg have_rise=0,have_fall=0,finished=0;
    realtime previous_rise=0,previous_fall=0;
    realtime raw_edge_time=0,old_edge_time=0,fabric_edge_time=0,tx_edge_time=0;
    realtime phase_delta_ns=0;
    reg [31:0] random_state=32'hc10c1251;
    integer epoch,rotation,value,control,phase,index;

    // Installed primitives only: their GRS hierarchy needs GRS_INST exactly.
    always #4 eth_raw=~eth_raw;
    GTP_GRS GRS_INST(.GRS_N(grs_n));
    GTP_CLKBUFG u_old_clock(.CLKIN(eth_raw),.CLKOUT(old_clk));
    GTP_CLKBUFG u_eth_clock(.CLKIN(eth_raw),.CLKOUT(eth_clk));
    GTP_CLKBUFG u_eth_tx_clock(.CLKIN(eth_raw),.CLKOUT(eth_tx_clk));
    pango_rgmii_tx #(.PHY_TXID(1),.SEPARATE_TXC_RESET(1)) old_branch(
        .clk125(old_clk),.clk125_90(old_clk),.reset_n(reset_n),.txc_reset_n(1'b1),
        .gmii_data(old_gmii),.gmii_en(old_en),.gmii_error(old_er),
        .rgmii_txc(old_txc),.rgmii_ctl(old_ctl),.rgmii_data(old_data));
    pango_rgmii_tx #(.PHY_TXID(1),.SEPARATE_TXC_RESET(1)) dedicated_branch(
        .clk125(eth_tx_clk),.clk125_90(eth_tx_clk),.reset_n(reset_n),.txc_reset_n(1'b1),
        .gmii_data(new_gmii),.gmii_en(new_en),.gmii_error(new_er),
        .rgmii_txc(new_txc),.rgmii_ctl(new_ctl),.rgmii_data(new_data));

    // Independent packet-side registers exercise the same-edge fabric-to-pad
    // transfer, including NBA ordering and asynchronous assertion/release.
    always @(posedge old_clk or negedge reset_n)
        if(!reset_n) begin old_gmii<=0;old_en<=0;old_er<=0;end
        else begin old_gmii<=stimulus;old_en<=stimulus_en;old_er<=stimulus_er;end
    always @(posedge eth_clk or negedge reset_n)
        if(!reset_n) begin new_gmii<=0;new_en<=0;new_er<=0;producer_kind<=-1;end
        else begin new_gmii<=stimulus;new_en<=stimulus_en;new_er<=stimulus_er;producer_kind<=stimulus_kind;end

    // Four-state assertions accumulate failures, rejecting X/Z as success.
    task automatic check(input condition,input string reason);
        begin
            checks=checks+1;
            if(condition!==1'b1) begin
                errors=errors+1;
                if(errors<=20) $display("DEDICATED_CLOCK_CHECK_FAILED t=%0t %s",$time,reason);
            end
        end
    endtask

    // Queue uses source values before the producer NBA, independently of
    // primitive internals. Installed SAME_EDGE adds one pad pipeline cycle.
    always @(posedge eth_clk or negedge reset_n or negedge grs_n) begin
        if(!reset_n || !grs_n) begin
            pending_data=0;active_data=0;pending_en=0;active_en=0;
            pending_er=0;active_er=0;pending_kind=-1;active_kind=-1;
        end else begin
            active_data=pending_data;active_en=pending_en;active_er=pending_er;active_kind=pending_kind;
            pending_data=new_gmii;pending_en=new_en;pending_er=new_er;pending_kind=producer_kind;
        end
    end

    // Timestamp each actual buffer output transition; these independent
    // observations distinguish measured functional phase from an assumption.
    always @(old_clk) old_edge_time=$realtime;
    always @(eth_clk) fabric_edge_time=$realtime;
    always @(eth_tx_clk) tx_edge_time=$realtime;

    // Reset also clears the observed low half: releasing RS in the low
    // quadrant may precede a falling edge before the next capture edge. That
    // half-word belongs to the cleared pipeline, not the previous FF byte.
    always @(negedge reset_n or negedge grs_n) begin
        observed_low=0;rising_ctl=0;
    end

    // Each raw half-edge checks all branch phases after delta settling and
    // records every output half-byte, including startup and local resets.
    always @(eth_raw) begin
        raw_edge_time=$realtime;
        #0.05;
        check({old_clk,eth_clk,eth_tx_clk}==={3{eth_raw}},"all same-source BUFG clock phases");
        check(old_edge_time==raw_edge_time && fabric_edge_time==raw_edge_time && tx_edge_time==raw_edge_time,"measured BUFG transition times coincide");
        if(tx_edge_time-fabric_edge_time>phase_delta_ns) phase_delta_ns=tx_edge_time-fabric_edge_time;
        if(fabric_edge_time-tx_edge_time>phase_delta_ns) phase_delta_ns=fabric_edge_time-tx_edge_time;
        phase_edges=phase_edges+1;
        check({old_gmii,old_en,old_er}==={new_gmii,new_en,new_er},"fabric producer equality");
        check({old_data,old_ctl,old_txc}==={new_data,new_ctl,new_txc},"old/new every-half-edge equality");
        if(grs_n && have_rise) check(new_txc===eth_raw,"unshifted free-running TXC level");
        if(reset_n && grs_n) begin
            if(eth_raw) begin
                check(new_data===active_data[3:0] && new_ctl===active_en,"low nibble / TX_EN");
                observed_low=new_data;rising_ctl=new_ctl;
            end else begin
                check(new_data===active_data[7:4] && new_ctl===(active_en^active_er),"high nibble / TX_EN XOR TX_ER");
                check({new_data,observed_low}===active_data && (rising_ctl^new_ctl)===active_er,"reconstructed byte and error");
                if(active_kind>=0) begin
                    vectors=vectors+1;
                    if(active_kind<2) coverage[active_kind][{active_er,active_en}][active_data]++;
                    else random_vectors++;
                end
            end
        end else check({old_data,old_ctl,new_data,new_ctl}===10'b0,"data/control held in reset");
        $fdisplay(trace,"%0.3f,%b,%b,%b,%b,%b,%h,%b,%b,%h,%b,%b,%h,%b,%b,%0d,%0.0f,%0.0f,%0.0f",
            $realtime,eth_raw,old_clk,eth_clk,eth_tx_clk,reset_n,
            old_data,old_ctl,old_txc,new_data,new_ctl,new_txc,active_data,active_en,active_er,active_kind,
            1000*(old_edge_time-raw_edge_time),1000*(fabric_edge_time-raw_edge_time),1000*(tx_edge_time-raw_edge_time));
    end

    // Pin-edge monitors reject missing/extra pulses and verify 8 ns period,
    // 4 ns duty halves, and exact old/new coincidence through every local RS.
    always @(posedge new_txc) if(grs_n) begin
        check(eth_raw===1'b1,"TXC rise phase");
        if(have_rise) check($realtime-previous_rise==8.0,"TXC period through reset");
        if(have_fall) check($realtime-previous_fall==4.0,"TXC low pulse width");
        previous_rise=$realtime;have_rise=1;txc_rises++;
        if(!reset_n) reset_txc_edges++;
        #0.001;check(old_txc===new_txc,"old/new TXC rise coincident to 1 ps");
    end
    always @(negedge new_txc) if(grs_n && have_rise) begin
        check(eth_raw===1'b0 && $realtime-previous_rise==4.0,"TXC falling phase / high width");
        previous_fall=$realtime;have_fall=1;txc_falls++;
        if(!reset_n) reset_txc_edges++;
        #0.001;check(old_txc===new_txc,"old/new TXC fall coincident to 1 ps");
    end

    // Stable setup precedes producer capture; after-capture bait must not
    // affect either registered packet source or its two emitted DDR halves.
    task automatic send(input [7:0] data_value,input en_value,input er_value,input integer kind);
        begin
            @(negedge eth_raw);#0.2;
            stimulus=data_value;stimulus_en=en_value;stimulus_er=er_value;stimulus_kind=kind;
            @(posedge eth_raw);#0.5;
            stimulus=~data_value;stimulus_en=~en_value;stimulus_er=~er_value;
        end
    endtask
    task automatic drain;
        begin
            @(negedge eth_raw);#0.2;
            stimulus=0;stimulus_en=0;stimulus_er=0;stimulus_kind=-1;
            repeat(4) @(negedge eth_raw);#0.2;
        end
    endtask

    // Two exact exhaustive sweeps bracket four asynchronous resets; a fixed
    // xorshift seed adds 1024 reproducible random bytes and EN/ER pairs.
    initial begin
        trace=$fopen("edge_trace.csv","w");
        if(!trace) $fatal(1,"DEDICATED_CLOCK_TRACE_OPEN_FAILED");
        $fdisplay(trace,"time_ns,raw,old_clk,fabric_clk,tx_clk,reset_n,old_data,old_ctl,old_txc,new_data,new_ctl,new_txc,expected_byte,expected_en,expected_er,kind,old_phase_ps,fabric_phase_ps,tx_phase_ps");
        for(epoch=0;epoch<2;epoch++) for(control=0;control<4;control++)
            for(value=0;value<256;value++) coverage[epoch][control][value]=0;
        #13;grs_n=1;repeat(5) @(negedge eth_raw);#0.7;reset_n=1;
        for(epoch=0;epoch<2;epoch++) begin
            for(rotation=0;rotation<4;rotation++) for(value=0;value<256;value++) begin
                control=(value+rotation)%4;
                send(value[7:0],control[0],control[1],epoch);
            end
            drain();
            if(epoch==0) for(phase=0;phase<4;phase++) begin
                repeat(4) send(8'hff,1'b1,1'b0,-1);
                @(posedge eth_raw);#(0.7+phase*2.0);
                check({old_data,old_ctl,new_data,new_ctl}===10'b1111111111,"nonzero pins make asynchronous clearing observable");
                reset_n=0;resets++;#0.05;
                check({old_data,old_ctl,new_data,new_ctl}===10'b0,"asynchronous reset assertion");
                check(old_txc===eth_raw && new_txc===eth_raw,"reset assertion preserves TXC");
                #32.25;reset_n=1;
                repeat(4) send(8'h3c,1'b1,1'b1,-1);
                drain();
            end
        end
        for(index=0;index<1024;index++) begin
            random_state=random_state^(random_state<<13);
            random_state=random_state^(random_state>>17);
            random_state=random_state^(random_state<<5);
            send(random_state[7:0],random_state[8],random_state[9],2);
        end
        drain();
        for(epoch=0;epoch<2;epoch++) for(control=0;control<4;control++)
            for(value=0;value<256;value++) check(coverage[epoch][control][value]==1,"exact byte/control coverage before/after reset");
        check(vectors==3072 && random_vectors==1024,"complete exact vector counts");
        check(resets==4 && reset_txc_edges>=32,"all reset phases and free-running edges covered");
        check(txc_rises>3072 && txc_falls>3072,"continuous TXC edge coverage");
        $display("DEDICATED_CLOCK_RESULT checks=%0d errors=%0d vectors=%0d random_vectors=%0d resets=%0d phase_edges=%0d txc_rises=%0d txc_falls=%0d reset_txc_edges=%0d phase_delta_ps=%0d",checks,errors,vectors,random_vectors,resets,phase_edges,txc_rises,txc_falls,reset_txc_edges,$rtoi(phase_delta_ns*1000));
        $fclose(trace);finished=1;
        if(errors) $fatal(1,"DEDICATED_CLOCK_FAILED");
        $display("DEDICATED_CLOCK_PASS");$finish;
    end

    // Simulation bound detects a stopped clock or incomplete driver sequence.
    initial begin #100000;if(!finished) $fatal(1,"DEDICATED_CLOCK_TIMEOUT");end
endmodule
`default_nettype wire
