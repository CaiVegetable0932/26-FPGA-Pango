// Purpose: verified OV5640 RGB565/720p startup, independent of PCLK and DDR.
// Source: local OV5640 DVP application guide p14/p27 and MINI vendor 244-write table.
// Keep the sensor in software standby during table writes; stream only after configuration.
module ov5640_startup #(
    parameter SYS_CLK=27000000, SCCB_CLK=100000,
    parameter RESET_CYCLES=270000, BOOT_CYCLES=1080000,
    parameter WRITE_WAIT=27000, SOFT_RESET_WAIT=135000,
    parameter SETTLE_CYCLES=1350000, MAX_RETRIES=2
)(
    input wire clk, rst_n, inout wire scl, sda,
    output wire reset_n, output wire ready,
    output wire failed, output reg [3:0] error_code,
    output reg [3:0] verify_index, output reg [7:0] last_read
);
    localparam HOLD=0, BOOT=1, ID_HIGH=2, ID_LOW=3, PAD_CLOCK=4,
               CONFIG=5, POLARITY=6, STREAM=7, SETTLE=8, VERIFY=9, READY=10, FAIL=11;
    reg [3:0] state;
    reg [31:0] delay_count;
    reg [7:0] retries;
    reg request_pending, command_start;
    reg command_read;
    reg [23:0] command_data;
    wire tx_done, tx_error, tx_busy;
    wire [7:0] tx_read;
    wire table_start, table_done;
    wire [23:0] table_data;
    reg [23:0] expected;
    reg [7:0] verify_mask;
    assign reset_n = rst_n && state!=HOLD && state!=FAIL;
    assign ready = state==READY;
    assign failed = state==FAIL && retries>=MAX_RETRIES;

    // Purpose: reuse vendor tuning, keep configuration in standby and select PLL.
    // Hardware telemetry showed variable short DVP rows (zero complete frames).
    // Halve ALL sensor clocks via 3035[7:4]=2 to test source-synchronous margin;
    // preserve RGB565/1280x720, PCLK polarity and byte/row validation unchanged.
    // OV5640 datasheet table 6-2: this system divider slows all clocks, unlike
    // changing only the DVP divider (which can upset FIFO producer/consumer rates).
    // This conservative capture candidate does NOT claim the original frame rate.
    wire [23:0] standby_data = table_data==24'h300802 ? 24'h300842 :
                              table_data==24'h310302 ? 24'h310303 :
                              table_data==24'h303511 ? 24'h303521 : table_data;
    data_init #(.CNT_WAIT_MAX(WRITE_WAIT),.RESET_WAIT_MAX(SOFT_RESET_WAIT)) table_writer(
        .sys_clk(clk),.sys_rst_n(rst_n && state==CONFIG),
        .cfg_end(tx_done && !tx_error && state==CONFIG),
        .cfg_start(table_start),.cfg_data(table_data),.cfg_done(table_done));
    ov5640_sccb #(.SYS_CLK(SYS_CLK),.SCCB_CLK(SCCB_CLK),
                  .STRETCH_TIMEOUT(SYS_CLK/100)) bus_master(
        .clk(clk),.rst_n(rst_n && state!=HOLD && state!=FAIL),
        .sccb_start(state==CONFIG ? table_start : command_start),
        .data_in(state==CONFIG ? standby_data : command_data),
        .read_enable(state==CONFIG ? 1'b0 : command_read),.read_data(tx_read),
        .SCL(scl),.SDA(sda),.sccb_done(tx_done),.sccb_error(tx_error),.busy(tx_busy));

    // Purpose: verify stable, relevant fields only; exposure/gain and other automatic
    // registers are deliberately excluded. 3008 checks reset/standby bits, not reserved bits.
    always @* begin
        verify_mask=8'hff;
        case(verify_index)
            0: begin expected=24'h300800; verify_mask=8'hc0; end
            1: expected=24'h380805;
            2: expected=24'h380900;
            3: expected=24'h380a02;
            4: expected=24'h380bd0;
            5: expected=24'h430061;
            6: expected=24'h501f01;
            7: begin expected=24'h474020; verify_mask=8'h23; end
            8: expected=24'h3017ff;
            9: expected=24'h3018ff;
            // Confirm the conservative source-clock profile before admitting DVP.
            10: expected=24'h303521;
            11: expected=24'h30363c;
            12: begin expected=24'h300e00; verify_mask=8'h04; end
            default: expected=24'h503d00;
        endcase
    end

    // Purpose: one accepted transaction per step, bounded hardware-reset retries and
    // fail-closed capture. A low/absent PCLK cannot prevent identification or diagnostics.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=HOLD; delay_count<=0; retries<=0; request_pending<=0;
            command_start<=0; command_read<=0; command_data<=0;
            error_code<=0; verify_index<=0; last_read<=0;
        end else begin
            command_start<=0;
            case(state)
                HOLD: begin
                    request_pending<=0;
                    if(delay_count==RESET_CYCLES-1) begin delay_count<=0; state<=BOOT; end
                    else delay_count<=delay_count+1;
                end
                BOOT: if(delay_count==BOOT_CYCLES-1) begin delay_count<=0; state<=ID_HIGH; end
                      else delay_count<=delay_count+1;
                CONFIG: begin
                    if(tx_done && tx_error) begin error_code<=3; state<=FAIL; end
                    else if(table_done) begin request_pending<=0; state<=POLARITY; end
                end
                SETTLE: if(delay_count==SETTLE_CYCLES-1) begin
                    delay_count<=0; verify_index<=0; state<=VERIFY;
                end else delay_count<=delay_count+1;
                READY: begin end
                FAIL: begin
                    request_pending<=0; delay_count<=0;
                    if(retries<MAX_RETRIES) begin retries<=retries+1; state<=HOLD; end
                end
                default: begin
                    if(!request_pending && !tx_busy) begin
                        command_start<=1; request_pending<=1;
                        command_read<=state==ID_HIGH || state==ID_LOW || state==VERIFY;
                        case(state)
                            ID_HIGH: command_data<=24'h300a00;
                            ID_LOW: command_data<=24'h300b00;
                            PAD_CLOCK: command_data<=24'h310311;
                            POLARITY: command_data<=24'h474020;
                            STREAM: command_data<=24'h300802;
                            default: command_data<={expected[23:8],8'b0};
                        endcase
                    end else if(request_pending && tx_done) begin
                        request_pending<=0; last_read<=tx_read;
                        if(tx_error) begin error_code<=1; state<=FAIL; end
                        else if((state==ID_HIGH && tx_read!=8'h56) ||
                                (state==ID_LOW && tx_read!=8'h40)) begin error_code<=2; state<=FAIL; end
                        else case(state)
                            ID_HIGH: state<=ID_LOW;
                            ID_LOW: state<=PAD_CLOCK;
                            PAD_CLOCK: state<=CONFIG;
                            POLARITY: state<=STREAM;
                            STREAM: begin state<=SETTLE; delay_count<=0; end
                            VERIFY: begin
                                if((tx_read & verify_mask)!=(expected[7:0] & verify_mask)) begin
                                    error_code<=4; state<=FAIL;
                                end else if(verify_index==13) begin state<=READY; error_code<=0; end
                                else verify_index<=verify_index+1;
                            end
                            default: begin error_code<=5; state<=FAIL; end
                        endcase
                    end
                end
            endcase
        end
    end
endmodule
