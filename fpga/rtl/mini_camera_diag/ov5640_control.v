// 用途：首次采集前核验 OV5640 身份/时序，选择原自动模式或固定测评参数组。
// 固定组逐写逐读，全部成功才发布 version=1；失败锁住采集直到复位。
// 运行期只提供查询，不允许在现有 DDR/帧池尚无停机握手时修改参数。
module ov5640_control #(
    parameter FIXED_MODE=0,
    parameter [19:0] EXPOSURE=0,
    parameter [9:0] GAIN=10'h010,
    parameter [11:0] WB_R=12'h400, WB_G=12'h400, WB_B=12'h400,
    parameter [15:0] EXPECT_HTS=0, EXPECT_VTS=0,
    parameter VTS_MARGIN=4
)(
    input wire clk, rst_n, table_done,
    output reg tx_start, tx_read,
    output reg [23:0] tx_data,
    input wire tx_done, input wire [1:0] tx_error,
    input wire [7:0] tx_value,
    input wire query_start, input wire [15:0] query_addr,
    output wire query_ready, output reg query_done, query_rejected,
    output reg [7:0] query_value, output reg [2:0] query_status,
    output reg capture_ready, output reg [31:0] config_version,
    output reg [2:0] fault, output reg [15:0] fault_addr,
    output reg snapshot_valid, output reg [15:0] snapshot_addr,
    output reg [7:0] snapshot_value, output reg [31:0] snapshot_cycle
);
    localparam WAIT_TABLE=0, SNAP_SEND=1, SNAP_WAIT=2, CHECK=3,
               WRITE_SEND=4, WRITE_WAIT=5, VERIFY_SEND=6, VERIFY_WAIT=7,
               IDLE=8, QUERY_WAIT=9;
    reg [3:0] state;
    reg [5:0] index;
    reg [4:0] write_index;
    reg [7:0] values [0:35];
    reg [31:0] cycles;
    reg final_snapshot;
    integer reset_index;
    reg [15:0] address_latched;
    wire [15:0] hts={values[8],values[9]}, vts={values[10],values[11]};
    assign query_ready=(state==IDLE);

    // 寄存器快照逐项带控制时钟时间戳；不是同帧原子快照或已测行时间。
    function [15:0] snapshot_register;
        input [5:0] n;
        begin case(n)
        0:snapshot_register=16'h300a; 1:snapshot_register=16'h300b;
        2:snapshot_register=16'h3034; 3:snapshot_register=16'h3035;
        4:snapshot_register=16'h3036; 5:snapshot_register=16'h3037;
        6:snapshot_register=16'h3039; 7:snapshot_register=16'h3108;
        8:snapshot_register=16'h380c; 9:snapshot_register=16'h380d;
        10:snapshot_register=16'h380e; 11:snapshot_register=16'h380f;
        12:snapshot_register=16'h3500; 13:snapshot_register=16'h3501;
        14:snapshot_register=16'h3502; 15:snapshot_register=16'h3503;
        16:snapshot_register=16'h350a; 17:snapshot_register=16'h350b;
        18:snapshot_register=16'h350c; 19:snapshot_register=16'h350d;
        20:snapshot_register=16'h3a00; 21:snapshot_register=16'h3406;
        22:snapshot_register=16'h3400; 23:snapshot_register=16'h3401;
        24:snapshot_register=16'h3402; 25:snapshot_register=16'h3403;
        26:snapshot_register=16'h3404; 27:snapshot_register=16'h3405;
        28:snapshot_register=16'h3808; 29:snapshot_register=16'h3809;
        30:snapshot_register=16'h380a; 31:snapshot_register=16'h380b;
        32:snapshot_register=16'h4300; 33:snapshot_register=16'h501f;
        34:snapshot_register=16'h3c00; 35:snapshot_register=16'h3c01;
        default:snapshot_register=0;
        endcase end
    endfunction

    // 显式固定曝光/增益/白平衡；保留值作为函数输入，保证组合逻辑随快照更新。
    // 保留高位 debug 与其他功能位，不改 HTS/VTS。
    // 关闭夜间并清额外曝光行，AWB 冻结后再写入用户提供的 RGB 增益。
    function [23:0] fixed_register;
        input [4:0] n;
        input [7:0] old3503, old3a00, old3500, old350a, old3406, old3400, old3402, old3404;
        begin case(n)
        0:fixed_register={16'h3503,old3503 | 8'h03};
        1:fixed_register={16'h3a00,old3a00 & 8'hfb};
        2:fixed_register=24'h350c00;
        3:fixed_register=24'h350d00;
        4:fixed_register={16'h3500,old3500[7:4],EXPOSURE[19:16]};
        5:fixed_register={16'h3501,EXPOSURE[15:8]};
        6:fixed_register={16'h3502,EXPOSURE[7:0]};
        7:fixed_register={16'h350a,old350a[7:2],GAIN[9:8]};
        8:fixed_register={16'h350b,GAIN[7:0]};
        9:fixed_register={16'h3406,old3406 | 8'h01};
        10:fixed_register={16'h3400,old3400[7:4],WB_R[11:8]};
        11:fixed_register={16'h3401,WB_R[7:0]};
        12:fixed_register={16'h3402,old3402[7:4],WB_G[11:8]};
        13:fixed_register={16'h3403,WB_G[7:0]};
        14:fixed_register={16'h3404,old3404[7:4],WB_B[11:8]};
        15:fixed_register={16'h3405,WB_B[7:0]};
        default:fixed_register=0;
        endcase end
    endfunction
    wire [23:0] selected_write=fixed_register(write_index,values[15],values[20],values[12],values[16],values[21],values[22],values[24],values[26]);
    // 最终快照再次核验整组；一次选择对应写项，避免复制十六套组合选择网络。
    reg profile_address;
    reg [4:0] verification_index;
    always @* begin
        profile_address=1; verification_index=0;
        case(index)
        15:verification_index=0; 20:verification_index=1;
        18:verification_index=2; 19:verification_index=3;
        12:verification_index=4; 13:verification_index=5;
        14:verification_index=6; 16:verification_index=7;
        17:verification_index=8; 21:verification_index=9;
        22:verification_index=10; 23:verification_index=11;
        24:verification_index=12; 25:verification_index=13;
        26:verification_index=14; 27:verification_index=15;
        default:profile_address=0;
        endcase
    end
    wire [23:0] expected_entry=fixed_register(verification_index,values[15],values[20],values[12],values[16],values[21],values[22],values[24],values[26]);
    wire final_mismatch=profile_address && tx_value!=expected_entry[7:0];

    // 错误码：1 NACK，2 总线超时/占用，3 回读不一致，4 ID，5 参数/模式。
    // 查询忙时明确 rejected；不覆盖已接受事务，也不形成无界队列。
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            // 用途：显式清零快照寄存器，避免混合异步复位/保持造成反馈复用告警。
            for(reset_index=0;reset_index<36;reset_index=reset_index+1) values[reset_index]<=0;
            state<=WAIT_TABLE; index<=0; write_index<=0; final_snapshot<=0;
            tx_start<=0; tx_read<=0; tx_data<=0; capture_ready<=0;
            config_version<=0; fault<=0; fault_addr<=0; cycles<=0;
            query_done<=0; query_rejected<=0; query_status<=0; query_value<=0;
            address_latched<=0; snapshot_valid<=0; snapshot_addr<=0;
            snapshot_value<=0; snapshot_cycle<=0;
        end else begin
            cycles<=cycles+1'b1;
            tx_start<=0; query_done<=0; snapshot_valid<=0;
            query_rejected<=query_start && !query_ready;
            case(state)
            WAIT_TABLE: if(table_done) begin index<=0; state<=SNAP_SEND; end
            SNAP_SEND: begin
                tx_data<={snapshot_register(index),8'b0}; tx_read<=1;
                tx_start<=1; state<=SNAP_WAIT;
            end
            SNAP_WAIT: if(tx_done) begin
                if(tx_error!=0 || (final_snapshot && final_mismatch)) begin
                    fault<=tx_error!=0 ? {1'b0,tx_error} : 3;
                    fault_addr<=snapshot_register(index); state<=IDLE;
                end else begin
                    values[index]<=tx_value; snapshot_valid<=1;
                    snapshot_addr<=snapshot_register(index); snapshot_value<=tx_value;
                    snapshot_cycle<=cycles;
                    if(index==35) state<=CHECK;
                    else begin index<=index+1'b1; state<=SNAP_SEND; end
                end
            end
            CHECK: begin
                if({values[0],values[1]}!=16'h5640) begin
                    fault<=4; fault_addr<=16'h300a; state<=IDLE;
                end else if(FIXED_MODE && (hts!=EXPECT_HTS || vts!=EXPECT_VTS ||
                    EXPECT_HTS==0 || VTS_MARGIN<1 || vts<=VTS_MARGIN || EXPOSURE==0 ||
                    EXPOSURE>((vts-VTS_MARGIN)*16) || GAIN<16 ||
                    WB_R==0 || WB_G==0 || WB_B==0 ||
                    {values[28],values[29]}!=16'd1280 ||
                    {values[30],values[31]}!=16'd720 ||
                    values[32]!=8'h61 || values[33]!=8'h01)) begin
                    fault<=5; fault_addr<=16'h380e; state<=IDLE;
                end else if(FIXED_MODE && !final_snapshot) begin
                    write_index<=0; state<=WRITE_SEND;
                end else begin
                    capture_ready<=1; config_version<=FIXED_MODE ? 1 : 0; state<=IDLE;
                end
            end
            WRITE_SEND: begin
                tx_data<=selected_write; tx_read<=0; tx_start<=1; state<=WRITE_WAIT;
            end
            WRITE_WAIT: if(tx_done) begin
                if(tx_error!=0) begin
                    fault<={1'b0,tx_error}; fault_addr<=selected_write[23:8]; state<=IDLE;
                end else state<=VERIFY_SEND;
            end
            VERIFY_SEND: begin
                tx_data<={selected_write[23:8],8'b0}; tx_read<=1;
                tx_start<=1; state<=VERIFY_WAIT;
            end
            VERIFY_WAIT: if(tx_done) begin
                if(tx_error!=0 || tx_value!=selected_write[7:0]) begin
                    fault<=tx_error!=0 ? {1'b0,tx_error} : 3;
                    fault_addr<=selected_write[23:8]; state<=IDLE;
                end else if(write_index==15) begin
                    final_snapshot<=1; index<=0; state<=SNAP_SEND;
                end else begin write_index<=write_index+1'b1; state<=WRITE_SEND; end
            end
            IDLE: if(query_start) begin
                address_latched<=query_addr; tx_data<={query_addr,8'b0};
                tx_read<=1; tx_start<=1; state<=QUERY_WAIT;
            end
            QUERY_WAIT: if(tx_done) begin
                query_value<=tx_value; query_status<={1'b0,tx_error}; query_done<=1;
                snapshot_valid<=tx_error==0; snapshot_addr<=address_latched;
                snapshot_value<=tx_value; snapshot_cycle<=cycles; state<=IDLE;
            end
            default: begin capture_ready<=0; fault<=5; state<=IDLE; end
            endcase
        end
    end
endmodule
