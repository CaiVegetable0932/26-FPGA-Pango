`timescale 1ns/1ps
// Purpose: independent UART-pin driver/decoder and public-port scoreboard.
// No force, internal state assignment, byte-bus injection, or DUT CRC helper is
// used. FULL=0 keeps production-clock smoke bounded; FULL=1 covers abuse cases.
module tb_mcu_protocol;
    parameter integer CLK_HZ=1843200;
    parameter integer BAUD=115200;
    parameter integer RX_TIMEOUT_MS=2;
    parameter integer FULL=1;
    localparam real CLK_NS=1.0e9/CLK_HZ;
    localparam real BIT_NS=1.0e9/BAUD;
    localparam [63:0] EPOCH_A=64'h123456789abcdef1, EPOCH_B=64'h123456789abcdef2;
    reg clk=0, rst_n=0, uart_rx=1;
    reg [63:0] link_epoch=0, board_time_us=64'h100000000;
    reg link_epoch_valid=0;
    reg [31:0] status_flags=32'hcafe1234;
    wire uart_tx, session_active, env_valid;
    wire [31:0] env_session_id,env_event_seq,env_mcu_time_us,env_lux_milli;
    wire signed [31:0] env_angle_mdeg;
    wire [63:0] env_board_time_us;
    wire [1:0] env_measurement_valid;
    wire [31:0] rx_good_count,rx_error_count,tx_overflow_count;
    integer checks=0, events=0, responses=0, expected_response=0;
    reg previous_env_valid=0;
    reg [15:0] received_seq[0:255];
    reg [7:0] received_command[0:255];
    reg [255:0] received_payload[0:255];
    reg [255:0] last_response, p, saved_event;
    integer baseline_events,baseline_responses,baseline_errors,baseline_good,baseline_drops,i;
    real stimulus_bit_ns=BIT_NS;

    // Clock changes are parameter-driven; serial bits retain true 115200 timing.
    always #(CLK_NS/2.0) clk=~clk;
    mcu_protocol #(.CLK_HZ(CLK_HZ),.BAUD(BAUD),.RX_TIMEOUT_MS(RX_TIMEOUT_MS)) dut (
        .clk(clk),.rst_n(rst_n),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .link_epoch(link_epoch),.link_epoch_valid(link_epoch_valid),
        .board_time_us(board_time_us),.status_flags(status_flags),.session_active(session_active),
        .env_valid(env_valid),.env_session_id(env_session_id),.env_event_seq(env_event_seq),
        .env_mcu_time_us(env_mcu_time_us),.env_board_time_us(env_board_time_us),
        .env_lux_milli(env_lux_milli),.env_angle_mdeg(env_angle_mdeg),
        .env_measurement_valid(env_measurement_valid),.rx_good_count(rx_good_count),
        .rx_error_count(rx_error_count),.tx_overflow_count(tx_overflow_count));

    // Every failed assertion exits the batch run; the script also requires PASS.
    task check(input bit condition,input string label_text);
        begin
            checks=checks+1;
            if (!condition) begin
                $display("MCU_PROTOCOL_FAIL clk=%0d check=%s time=%0t",CLK_HZ,label_text,$time);
                $fatal(1,"MCU protocol assertion");
            end
        end
    endtask

    // Independent bit-at-a-time reference, anchored by the standard check word.
    function automatic [15:0] reference_crc(input [15:0] prior,input [7:0] octet);
        reg [15:0] result;
        reg feedback;
        integer bit_number;
        begin
            result=prior;
            for(bit_number=7;bit_number>=0;bit_number=bit_number-1) begin
                feedback=result[15]^octet[bit_number]; result={result[14:0],1'b0};
                if(feedback) result=result^16'h1021;
            end
            reference_crc=result;
        end
    endfunction

    // Build the wire payload independently from RTL field extraction.
    function automatic [255:0] session_payload(input [63:0] epoch,input [31:0] session_id);
        begin session_payload=0; session_payload[63:0]=epoch; session_payload[95:64]=session_id; end
    endfunction
    function automatic [255:0] event_payload(input [63:0] epoch,input [31:0] session_id,
        input [31:0] event_id,input [31:0] mcu_time,input [31:0] lux,
        input signed [31:0] angle,input [7:0] flags);
        begin
            event_payload=0; event_payload[63:0]=epoch; event_payload[95:64]=session_id;
            event_payload[127:96]=event_id; event_payload[159:128]=mcu_time;
            event_payload[191:160]=lux; event_payload[223:192]=angle; event_payload[231:224]=flags;
        end
    endfunction

    // Physical 8N1 stimulus, asynchronous to clk. Skew tests change only bit time.
    task uart_byte(input [7:0] value);
        integer b;
        begin
            uart_rx=0; #(stimulus_bit_ns);
            for(b=0;b<8;b=b+1) begin uart_rx=value[b]; #(stimulus_bit_ns); end
            uart_rx=1; #(stimulus_bit_ns);
        end
    endtask
    task header(input [7:0] command,input [15:0] sequence_id,input [15:0] length);
        begin
            uart_byte(8'h55); uart_byte(8'haa); uart_byte(1); uart_byte(command);
            uart_byte(sequence_id[7:0]); uart_byte(sequence_id[15:8]);
            uart_byte(length[7:0]); uart_byte(length[15:8]);
        end
    endtask
    task request(input [7:0] command,input [15:0] sequence_id,input integer length,
        input [255:0] contents,input [7:0] version,input bit corrupt_crc);
        integer n;
        reg [7:0] value;
        reg [15:0] crc;
        begin
            uart_byte(8'h55); uart_byte(8'haa); crc=16'hffff;
            for(n=0;n<6+length;n=n+1) begin
                case(n)
                    0:value=version; 1:value=command; 2:value=sequence_id[7:0];
                    3:value=sequence_id[15:8]; 4:value=length%256; 5:value=length/256;
                    default: value=(n<38)?contents[(n-6)*8 +: 8]:8'ha5;
                endcase
                crc=reference_crc(crc,value); uart_byte(value);
            end
            if(corrupt_crc) crc=crc^16'h0001;
            uart_byte(crc[7:0]); uart_byte(crc[15:8]);
        end
    endtask

    // Decode actual TX pin centers, verify framing and CRC before recording a
    // reply. Bit timing is ideal host baud, not copied from DUT divider internals.
    initial begin : serial_monitor
        integer b,index;
        reg [7:0] value,packet[0:41];
        reg [15:0] crc;
        reg [255:0] decoded_payload;
        index=0; crc=16'hffff; decoded_payload=0;
        forever begin
            @(negedge uart_tx);
            if(rst_n) begin
                #(BIT_NS/2); check(uart_tx===0,"TX start bit");
                for(b=0;b<8;b=b+1) begin #(BIT_NS); value[b]=uart_tx; end
                #(BIT_NS); check(uart_tx===1,"TX stop bit");
                packet[index]=value;
                if(index==0) check(value==8'h55,"response sync55");
                if(index==1) check(value==8'haa,"response syncAA");
                if(index==2) begin check(value==1,"response version"); crc=16'hffff; end
                if(index>=2 && index<=39) crc=reference_crc(crc,value);
                if(index==6) check(value==32,"response payload length low");
                if(index==7) check(value==0,"response payload length high");
                if(index>=8 && index<=39) decoded_payload[(index-8)*8 +: 8]=value;
                if(index==41) begin
                    check({value,packet[40]}==crc,"response CRC16 little endian");
                    check(responses<256,"response scoreboard capacity");
                    received_seq[responses]={packet[5],packet[4]};
                    received_command[responses]=packet[3]; received_payload[responses]=decoded_payload;
                    responses=responses+1; index=0;
                end else index=index+1;
            end
        end
    end

    // Public output monitoring checks pulse width and preserves a global event
    // count across DUT resets, so replay after a reset cannot hide an extra pulse.
    always @(posedge clk) begin
        #0.001;
        if(!rst_n) previous_env_valid=0;
        else begin
            if(env_valid) begin
                check(!previous_env_valid,"env_valid one cycle"); events=events+1;
                check(env_board_time_us===board_time_us,"independent FPGA acceptance time");
            end
            previous_env_valid=env_valid;
        end
    end

    // Bounded reply wait detects missing/error replies; seq and original cmd are
    // checked on every response, including bad frames and back-to-back traffic.
    task expect_reply(input [15:0] sequence_id,input [7:0] command,input [7:0] code);
        realtime deadline;
        begin
            deadline=$realtime+60000000.0;
            while(responses<=expected_response && $realtime<deadline) #(BIT_NS*10);
            check(responses>expected_response,"response deadline");
            check(received_seq[expected_response]===sequence_id,"response sequence");
            last_response=received_payload[expected_response];
            check(last_response[15:8]===command,"response original command");
            check(last_response[7:0]===code,$sformatf("response result seq=%0d expected=%0d got=%0d",
                sequence_id,code,last_response[7:0]));
            check(received_command[expected_response]===((code<2)?8'h80:8'h81),"ACK/NACK command");
            expected_response=expected_response+1;
        end
    endtask

    // The global watchdog is independent of parser and response timing.
    initial begin #1500000000; $fatal(1,"MCU_PROTOCOL_FAIL watchdog"); end

    initial begin : tests
        reg [15:0] golden;
        golden=16'hffff;
        for(i=0;i<9;i=i+1) golden=reference_crc(golden,8'h31+i);
        check(golden==16'h29b1,"CCITT FALSE known check vector");
        repeat(20) @(posedge clk); @(negedge clk); rst_n=1; #(BIT_NS*2);

        // Capability discovery works without a boot epoch; mutation fails closed.
        request(1,1,0,0,1,0); expect_reply(1,1,0);
        check(last_response[175:160]==1024 && last_response[191:176]==32,"separate protocol/endpoint limits");
        check(last_response[255:224]==BAUD && last_response[17:16]==0,"capability baud/not ready");
        request(2,2,12,session_payload(EPOCH_A,1),1,0); expect_reply(2,2,13);
        @(negedge clk); link_epoch=EPOCH_A; link_epoch_valid=1; #(BIT_NS*2);
        request(2,3,12,session_payload(EPOCH_A,1),1,0); expect_reply(3,2,0);
        check(session_active,"session opened");

        // New event, identical retries with same/different transport seq, and a
        // bad CRC show that identity and board timestamp are not transport order.
        saved_event=event_payload(EPOCH_A,1,1,32'hdeadbeef,123456,-12345,3);
        request(8'h10,4,32,saved_event,1,0); expect_reply(4,8'h10,0);
        check(events==1 && env_session_id==1 && env_event_seq==1,"first event exactly once");
        check(env_lux_milli==123456 && env_angle_mdeg==-12345 && env_measurement_valid==3,"signed measurements");
        check(env_mcu_time_us==32'hdeadbeef && env_board_time_us==64'h100000000,"separate time domains");
        board_time_us=64'h200000000;
        request(8'h10,4,32,saved_event,1,0); expect_reply(4,8'h10,1);
        request(8'h10,5,32,saved_event,1,0); expect_reply(5,8'h10,1);
        check(events==1 && env_board_time_us==64'h100000000,"duplicate leaves event/time unchanged");
        p=event_payload(EPOCH_A,1,2,10,500000,90000,1);
        request(8'h10,6,32,p,1,1); expect_reply(6,8'h10,2);
        check(events==1 && env_event_seq==1,"CRC rejects mutation");
        request(8'h10,7,32,p,2,0); expect_reply(7,8'h10,5);
        request(8'h44,8,0,0,1,0); expect_reply(8,8'h44,6);

        // Inter-byte timeout uses the real configured clock; at production125M
        // this is the unshortened default20ms, checked before/after its deadline.
        header(8'h10,9,32); uart_byte(8'h55); baseline_errors=rx_error_count;
        #(RX_TIMEOUT_MS*1000000.0*0.70);
        check(rx_error_count==baseline_errors,"timeout does not fire early");
        #(RX_TIMEOUT_MS*1000000.0*0.40); expect_reply(9,8'h10,4);
        check(events==1,"timeout frame cannot commit");

        // No inter-frame gaps: accept an event, duplicate it, then query status.
        request(8'h10,10,32,p,1,0);
        request(8'h10,11,32,p,1,0);
        request(3,12,12,session_payload(EPOCH_A,1),1,0);
        expect_reply(10,8'h10,0); expect_reply(11,8'h10,1); expect_reply(12,3,0);
        check(events==2 && env_event_seq==2 && env_measurement_valid==1,"back-to-back event/duplicate/status");
        check(last_response[191:160]==status_flags,"status flag snapshot");

        if(FULL) begin
            // Identity conflict, stale/invalid fields, and stale session/epoch.
            p[191:160]=500001;
            request(8'h10,20,32,p,1,0); expect_reply(20,8'h10,10);
            request(8'h10,21,32,saved_event,1,0); expect_reply(21,8'h10,9);
            p=event_payload(EPOCH_A,1,3,11,600,700,8'h80);
            request(8'h10,22,32,p,1,0); expect_reply(22,8'h10,11);
            p=event_payload(EPOCH_A,1,3,11,600,700,0); p[255:248]=1;
            request(8'h10,23,32,p,1,0); expect_reply(23,8'h10,11);
            request(8'h10,24,31,p,1,0); expect_reply(24,8'h10,3);
            request(8'h10,25,32,event_payload(EPOCH_B,1,3,1,2,3,3),1,0); expect_reply(25,8'h10,7);
            request(8'h10,26,32,event_payload(EPOCH_A,2,3,1,2,3,3),1,0); expect_reply(26,8'h10,8);
            request(2,27,12,session_payload(EPOCH_A,1),1,0); expect_reply(27,2,1);
            check(env_event_seq==2 && events==2,"reopen retry retains dedup history");

            // Noise, overlapping preamble and a sub-half-bit glitch recover.
            uart_byte(0); uart_byte(8'hff); uart_byte(8'h33); uart_byte(8'h55); uart_byte(8'h12); uart_byte(8'h55);
            request(1,28,0,0,1,0); expect_reply(28,1,0);
            baseline_errors=rx_error_count; uart_rx=0; #(BIT_NS/8); uart_rx=1; #(BIT_NS*2);
            check(rx_error_count==baseline_errors,"short start glitch ignored");
            stimulus_bit_ns=BIT_NS*1.015; request(1,29,0,0,1,0); stimulus_bit_ns=BIT_NS;
            expect_reply(29,1,0);
            stimulus_bit_ns=BIT_NS*0.985; request(1,30,0,0,1,0); stimulus_bit_ns=BIT_NS;
            expect_reply(30,1,0);

            // Small-buffer lengths are drained by envelope, including 1024;
            // the next request immediately after a33-byte frame must survive.
            request(8'h10,31,33,saved_event,1,0); request(1,32,0,0,1,0);
            expect_reply(31,8'h10,3); expect_reply(32,1,0);
            request(8'h10,33,1024,saved_event,1,0); expect_reply(33,8'h10,3);
            header(8'h10,34,1025);
            request(8'h10,35,32,event_payload(EPOCH_A,1,3,10,20,30,3),1,0);
            #(RX_TIMEOUT_MS*1000000.0+BIT_NS*2); expect_reply(34,8'h10,3);
            check(responses==expected_response && events==2,"oversize quarantines embedded valid event");
            request(1,36,0,0,1,0); expect_reply(36,1,0);
            header(8'h10,37,16'hffff); #(RX_TIMEOUT_MS*1000000.0+BIT_NS*2);
            expect_reply(37,8'h10,3);

            // A bad stop bit followed by a break yields one UART error, then
            // requires an idle gap before a valid request can be accepted.
            header(8'h10,38,32); uart_rx=0; #(BIT_NS*14); uart_rx=1;
            #(RX_TIMEOUT_MS*1000000.0+BIT_NS*2); expect_reply(38,8'h10,12);
            request(1,39,0,0,1,0); expect_reply(39,1,0);
            check(events==2,"all malformed/noise cases leave event untouched");

            // Deliberate response overload is bounded and observable. All
            // accepted replies must be intact; discarded queries have no effect.
            baseline_responses=responses; baseline_drops=tx_overflow_count; baseline_good=rx_good_count;
            for(i=0;i<28;i=i+1) request(1,100+i,0,0,1,0);
            #(BIT_NS*10*42*12);
            check(tx_overflow_count>baseline_drops,"bounded queue overload counted");
            check((responses-baseline_responses)+(tx_overflow_count-baseline_drops)==28,"overload reply/drop accounting");
            check(rx_good_count-baseline_good==28 && events==2,"overload transport accounting");
            for(i=baseline_responses;i<responses;i=i+1) begin
                check(received_seq[i]>=100 && received_seq[i]<128,"overload sequence range");
                check(received_payload[i][7:0]==0,"overload accepted queries OK");
                if(i>baseline_responses) check(received_seq[i]>received_seq[i-1],"FIFO reply order");
            end
            expected_response=responses;
            request(4,140,12,session_payload(EPOCH_A,1),1,0); expect_reply(140,4,0);
            check(last_response[191:160]==rx_good_count && last_response[223:192]==rx_error_count &&
                last_response[255:224]==tx_overflow_count,"counter snapshot includes current query");
        end

        // Reset in the middle of a valid event; a new epoch makes all old
        // requests stale. No physical pin assignments or hardware I/O are used.
        baseline_events=events; header(8'h10,150,32); uart_byte(1); uart_byte(2);
        @(negedge clk); rst_n=0; uart_rx=1; link_epoch_valid=0;
        repeat(20) @(posedge clk); @(negedge clk); link_epoch=EPOCH_B; rst_n=1;
        #(BIT_NS*2); link_epoch_valid=1; #(BIT_NS*2);
        check(!session_active && env_measurement_valid==0 && !env_valid,"reset clears session/validity");
        request(2,151,12,session_payload(EPOCH_A,1),1,0); expect_reply(151,2,7);
        request(8'h10,152,32,saved_event,1,0); expect_reply(152,8'h10,7);
        check(events==baseline_events,"reset rejects partial and old-epoch replay");
        request(2,153,12,session_payload(EPOCH_B,1),1,0); expect_reply(153,2,0);
        p=event_payload(EPOCH_B,1,1,0,0,-1,0);
        request(8'h10,154,32,p,1,0); expect_reply(154,8'h10,0);
        check(events==baseline_events+1 && env_measurement_valid==0 && env_mcu_time_us==0,"new epoch event and invalid measurements");
        request(2,155,12,session_payload(EPOCH_B,2),1,0); expect_reply(155,2,0);
        request(2,156,12,session_payload(EPOCH_B,1),1,0); expect_reply(156,2,8);
        request(8'h10,157,32,p,1,0); expect_reply(157,8'h10,8);
        check(env_event_seq==0 && events==baseline_events+1,"old MCU session cannot reopen or replay");

        // Invalidating epoch without a reset also invalidates measurements.
        @(negedge clk); link_epoch_valid=0; #(BIT_NS*2);
        check(!session_active && env_measurement_valid==0,"epoch-valid withdrawal");
        request(2,158,12,session_payload(EPOCH_B,3),1,0); expect_reply(158,2,13);
        check(responses==expected_response,"no unsolicited or missing responses");
        $display("MCU_PROTOCOL_PASS clk=%0d baud=%0d timeout_ms=%0d full=%0d checks=%0d events=%0d responses=%0d",
            CLK_HZ,BAUD,RX_TIMEOUT_MS,FULL,checks,events,responses);
        $finish;
    end
endmodule
