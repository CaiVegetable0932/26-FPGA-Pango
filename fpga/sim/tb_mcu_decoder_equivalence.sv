`timescale 1ns/1ps
// Purpose: compare the complete combinational protocol response/admission
// contract before and after the isolated queue/control-path rewrite. Parser
// and session snapshots are forced equally; physical UART behavior is tested
// separately by the unmodified pin-level suites. This is not a formal proof.
module tb_mcu_decoder_equivalence;
    parameter integer GEOM=1;
    parameter integer FEATURES=7;
    reg [7:0] command,error_code,geometry_code;
    reg [15:0] length;
    reg [255:0] payload;
    reg [31:0] session_id,event_seq,good_count,error_count,drop_count,status;
    reg [1:0] epoch_equal,measurement;
    reg [7:0] duplicate_chunks;
    reg [95:0] diagnostic;
    integer i,j,checks=0;
    mcu_protocol #(.GEOMETRY_CONTROL(GEOM),.BOARD_DIAGNOSTICS(FEATURES&1),
        .VIDEO_DIAGNOSTICS((FEATURES>>1)&1),.CHAIN_DIAGNOSTICS((FEATURES>>2)&1)) candidate (
        .clk(1'b0),.rst_n(1'b1),.uart_rx(1'b1),
        .link_epoch(64'h0123456789abcdef),.link_epoch_valid(1'b1),
        .board_time_us(64'd0),.status_flags(status),.board_diagnostics(diagnostic),
        .video_diagnostics(diagnostic),.chain_diagnostics({3{diagnostic}}),
        .geometry_code(geometry_code),.geometry_reply(diagnostic));
    mcu_protocol_golden #(.GEOMETRY_CONTROL(GEOM),.BOARD_DIAGNOSTICS(FEATURES&1),
        .VIDEO_DIAGNOSTICS((FEATURES>>1)&1),.CHAIN_DIAGNOSTICS((FEATURES>>2)&1)) golden (
        .clk(1'b0),.rst_n(1'b1),.uart_rx(1'b1),
        .link_epoch(64'h0123456789abcdef),.link_epoch_valid(1'b1),
        .board_time_us(64'd0),.status_flags(status),.board_diagnostics(diagnostic),
        .video_diagnostics(diagnostic),.chain_diagnostics({3{diagnostic}}),
        .geometry_code(geometry_code),.geometry_reply(diagnostic));
    initial begin
        // Stable/identical transport and session snapshots isolate the decoder
        // from parser timing; queue reservation and actual UART have own tests.
        force candidate.request_command=command;force golden.request_command=command;
        force candidate.request_length=length;force golden.request_length=length;
        force candidate.request_payload=payload;force golden.request_payload=payload;
        force candidate.parse_error=error_code;force golden.parse_error=error_code;
        force candidate.frame_done=1;force golden.frame_done=1;
        force candidate.reply_allowed=1;force golden.reply_allowed=1;
        force candidate.pending_reply=0;force golden.pending_reply=0;
        force candidate.queue_count=0;force golden.queue_count=0;
        force candidate.tx_ready=0;force golden.tx_ready=0;
        force candidate.epoch_nonzero=1;force golden.epoch_nonzero=1;
        force candidate.observed_epoch=64'h0123456789abcdef;
        force golden.observed_epoch=64'h0123456789abcdef;
        force candidate.observed_epoch_valid=1;force golden.observed_epoch_valid=1;
        force candidate.request_epoch_equal=epoch_equal;force golden.request_epoch_equal=epoch_equal;
        // The real parser gives these registers both CRC-byte cycles to settle.
        // This combinational miter explicitly models that settled predecode;
        // the actual UART regression checks its sequential integration.
        force candidate.request_session_equal=(payload[95:64]==session_id);
        force candidate.request_session_nonzero=(payload[95:64]!=0);
        force candidate.request_session_less=(payload[95:64]<session_id);
        force candidate.request_length_equal={length==16'd32,length==16'd24,
            length==16'd20,length==16'd16,length==16'd12,length==16'd0};
        force candidate.active_session=session_id;force golden.active_session=session_id;
        force candidate.env_event_seq=event_seq;force golden.env_event_seq=event_seq;
        force candidate.env_measurement_valid=measurement;force golden.env_measurement_valid=measurement;
        force candidate.event_chunk_equal=duplicate_chunks;force golden.event_chunk_equal=duplicate_chunks;
        force candidate.rx_good_count=good_count;force golden.rx_good_count=good_count;
        force candidate.rx_error_count=error_count;force golden.rx_error_count=error_count;
        force candidate.tx_overflow_count=drop_count;force golden.tx_overflow_count=drop_count;
        // All command/geometry-code combinations, with valid and rejected
        // lengths, epochs, sessions, duplicate events and counter wrap values.
        for(i=0;i<131072;i=i+1)begin
            command=i[15:8];geometry_code=i[7:0];
            error_code=(i%7==0)?8'd2:8'd0;
            epoch_equal=(i%11==0)?0:3;
            session_id=(i%17==0)?0:17;
            event_seq=$unsigned($random);measurement=$random;
            duplicate_chunks=(i%3==0)?8'hff:$random;
            for(j=0;j<8;j=j+1)payload[j*32+:32]=$random;
            payload[95:64]=(i%5==0)?32'd18:session_id;
            payload[127:96]=(i%3==0)?event_seq:((i%3==1)?event_seq+1:event_seq-1);
            if(i%2==0)payload[255:226]=0;
            case(command)
                1:length=0;
                8'h10:length=32;
                8'h30,8'h31:length=24;
                8'h32:length=16;
                8'h34:length=20;
                default:length=12;
            endcase
            if(i[16])length=$urandom_range(0,40);
            good_count=(i%3==0)?32'hffffffff:$random;
            error_count=(i%3==1)?32'hffffffff:$random;
            drop_count=$random;status=$random;diagnostic={$random,$random,$random};
            #1;
            if({candidate.response_payload,candidate.response_code,candidate.accept_session,
                candidate.accept_event,candidate.geometry_command_valid} !==
               {golden.response_payload,golden.response_code,golden.accept_session,
                golden.accept_event,golden.geometry_command_valid})
                $fatal(1,"MCU_DECODER_FAIL geom=%0d case=%0d command=%h code=%h",GEOM,i,command,geometry_code);
            checks=checks+1;
        end
        $display("MCU_DECODER_EQUIVALENCE_PASS geom=%0d features=%0d checks=%0d",GEOM,FEATURES,checks);$finish;
    end
endmodule
