`timescale 1ns/1ps
// Purpose: independent UART-pin driver/decoder and public-port scoreboard.
// No force, internal state assignment, byte-bus injection, or DUT CRC helper is
// used. FULL=0 keeps production-clock smoke bounded; FULL=1 covers abuse cases.
module tb_geometry_uart;
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
    // Purpose: explicit types before port connections prevent implicit wires.
    wire [31:0] session_id,version;wire gc_valid;wire [7:0] gc_cmd,gc_code;
    wire [255:0] gc_payload;wire [95:0] gc_reply;wire [447:0] active_words;

    // Clock changes are parameter-driven; serial bits retain true 115200 timing.
    always #(CLK_NS/2.0) clk=~clk;
    // A known 96-bit diagnostic snapshot exercises the optional read-only command.
    mcu_protocol #(.CLK_HZ(CLK_HZ),.BAUD(BAUD),.RX_TIMEOUT_MS(RX_TIMEOUT_MS),.BOARD_DIAGNOSTICS(1),.VIDEO_DIAGNOSTICS(1),.CHAIN_DIAGNOSTICS(1),.GEOMETRY_CONTROL(1)) dut (
        .clk(clk),.rst_n(rst_n),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .link_epoch(link_epoch),.link_epoch_valid(link_epoch_valid),
        .board_time_us(board_time_us),.status_flags(status_flags),.session_active(session_active),
        .current_session_id(session_id),.geometry_command_valid(gc_valid),
        .geometry_command(gc_cmd),.geometry_payload(gc_payload),.geometry_code(gc_code),.geometry_reply(gc_reply),
        .board_diagnostics(96'h0100002c0420001c001cc916),
        .video_diagnostics(96'h01070100003d000041000042),
        .chain_diagnostics({96'h8899aabbccddeeff12345678,
                            96'h112233445566778899aabbcc,96'h018000000780078004380123}),
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
                $display("GEOMETRY_UART_FAIL clk=%0d check=%s time=%0t",CLK_HZ,label_text,$time);
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
    initial begin #1500000000; $fatal(1,"GEOMETRY_UART_FAIL watchdog"); end


    // Purpose: actual configuration and hardware-built double-bank radial LUT
    // are tested through physical UART bits, not by poking parser internals.
    reg frame_start=0;reg [63:0] source_id=42;
    wire [1:0] active_model,build_model;wire active_bank,active_enhance;
    wire build_start,build_bank,build_busy,build_failed,pending,lut_busy,lut_done,lut_failed;
    wire signed [31:0] k1,k2,k3,k4;wire [63:0] applied_id;
    reg [31:0] parameters[0:13];
    geometry_config_bank config_bank(.clk(clk),.rst_n(rst_n),.context_valid(session_active),
      .epoch(link_epoch),.session_id(session_id),.cmd_valid(gc_valid),.cmd(gc_cmd),.payload(gc_payload),
      .code(gc_code),.reply(gc_reply),.frame_start(frame_start),.source_frame_id(source_id),
      .active_words(active_words),.active_model(active_model),.active_enhance(active_enhance),
      .active_bank(active_bank),.active_version(version),.applied_frame_id(applied_id),
      .build_busy(build_busy),.build_failed(build_failed),.pending(pending),
      .build_start(build_start),.build_bank(build_bank),.build_model(build_model),
      .k1(k1),.k2(k2),.k3(k3),.k4(k4),.build_done(lut_done),.lut_failed(lut_failed));
    geometry_lens_lut lens(.clk(clk),.rst_n(rst_n),.start(build_start),.build_bank(build_bank),
      .model(build_model),.k1(k1),.k2(k2),.k3(k3),.k4(k4),.busy(lut_busy),.done(lut_done),
      .failed(lut_failed),.read_bank(active_bank),.read_index(11'd0),.scale0(),.scale1());

    // Purpose: BEGIN carries the model/geometry; WORD/READ deliberately use
    // different meanings for their two 32-bit fields, matching the wire spec.
    function automatic [255:0] begin_payload(input [31:0] ver);
      begin begin_payload=session_payload(EPOCH_A,1);
        begin_payload[127:96]=ver;begin_payload[135:128]=2;
        begin_payload[143:136]=1;begin_payload[159:144]=1920;begin_payload[175:160]=1080;end
    endfunction
    function automatic [255:0] word_payload(input [31:0] ver,idx,value);
      begin word_payload=session_payload(EPOCH_A,1);word_payload[127:96]=ver;
        word_payload[159:128]=idx;word_payload[191:160]=value;end
    endfunction
    task activate;
      begin @(negedge clk);frame_start=1;@(negedge clk);frame_start=0;end
    endtask

    initial begin : tests
      $readmemh("parameters.hex",parameters);
      repeat(20)@(posedge clk);@(negedge clk);link_epoch=EPOCH_A;link_epoch_valid=1;rst_n=1;
      #(BIT_NS*2);
      request(1,1,0,0,1,0);expect_reply(1,1,0);
      check(last_response[199],"geometry capability bit7");
      request(2,2,12,session_payload(EPOCH_A,1),1,0);expect_reply(2,2,0);
      // CRC/length/session errors must not create a shadow set or event.
      request('h30,3,24,begin_payload(1),1,1);expect_reply(3,'h30,2);
      request('h30,4,23,begin_payload(1),1,0);expect_reply(4,'h30,3);
      p=begin_payload(1);p[95:64]=2;
      request('h30,5,24,p,1,0);expect_reply(5,'h30,8);
      request('h30,6,24,begin_payload(1),1,0);expect_reply(6,'h30,0);
      request('h30,7,24,begin_payload(1),1,0);expect_reply(7,'h30,1);
      p=session_payload(EPOCH_A,1);p[127:96]=1;
      request('h32,8,16,p,1,0);expect_reply(8,'h32,11);
      for(i=0;i<14;i=i+1)begin
        request('h31,10+i,24,word_payload(1,i,parameters[i]),1,0);expect_reply(10+i,'h31,0);
      end
      request('h31,30,24,word_payload(1,0,parameters[0]),1,0);expect_reply(30,'h31,1);
      p=session_payload(EPOCH_A,1);p[127:96]=1;
      request('h32,31,16,p,1,0);expect_reply(31,'h32,0);
      check(version==0,"COMMIT ACK not active");
      request('h32,32,16,p,1,0);expect_reply(32,'h32,1);
      wait(pending);check(!build_failed,"hardware table validated");
      check(version==0,"pending waits for frame");
      activate();check(version==1 && applied_id==42 && active_model==2 && active_enhance,"frame atomic activation");
      for(i=0;i<14;i=i+1)begin
        p=session_payload(EPOCH_A,1);p[127:96]=i;p[159:128]=1;
        request('h34,40+i,20,p,1,0);expect_reply(40+i,'h34,0);
        check(last_response[191:160]==i && last_response[223:192]==parameters[i] &&
              last_response[255:224]==1,"readback exact K/D words/version");
      end
      request('h33,60,12,session_payload(EPOCH_A,1),1,0);expect_reply(60,'h33,0);
      check(last_response[191:160]==1 && last_response[255:192]==42,"STATUS applied identity");
      check(events==0,"geometry never commits MCU observation");
      // A nonphysical focal length is rejected before replacing last good set.
      request('h30,61,24,begin_payload(2),1,0);expect_reply(61,'h30,0);
      for(i=0;i<14;i=i+1)begin
        request('h31,62+i,24,word_payload(2,i,i==10?0:parameters[i]),1,0);expect_reply(62+i,'h31,0);
      end
      p=session_payload(EPOCH_A,1);p[127:96]=2;
      request('h32,80,16,p,1,0);expect_reply(80,'h32,11);
      activate();check(version==1,"bad fields preserve old active set");
      // A negative/nonmonotonic lens is accepted only as a build attempt;
      // its failed table never reaches the active bank.
      request('h31,81,24,word_payload(2,10,parameters[10]),1,0);expect_reply(81,'h31,0);
      request('h31,82,24,word_payload(2,6,32'hfc000000),1,0);expect_reply(82,'h31,0);
      request('h31,83,24,word_payload(2,7,0),1,0);expect_reply(83,'h31,0);
      request('h31,84,24,word_payload(2,9,0),1,0);expect_reply(84,'h31,0);
      request('h32,85,16,p,1,0);expect_reply(85,'h32,0);
      wait(!build_busy);check(build_failed && !pending,"invalid radial LUT rejected");
      activate();check(version==1,"failed LUT preserves previous table");
      // Session changes invalidate staged geometry without erasing active K/D.
      request(2,90,12,session_payload(EPOCH_A,2),1,0);expect_reply(90,2,0);
      request('h32,91,16,p,1,0);expect_reply(91,'h32,8);
      check(version==1 && !pending,"session isolation with last-good geometry");
      $display("GEOMETRY_UART_PASS checks=%0d responses=%0d",checks,responses);$finish;
    end
endmodule

