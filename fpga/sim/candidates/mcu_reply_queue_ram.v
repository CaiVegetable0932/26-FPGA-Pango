// Purpose: independently tested, NOT YET INTEGRATED reply-queue candidate.
// Keep the existing eight-slot, first-word-visible interface while replacing
// the wide register bank with synchronous block RAM. The head and lookahead
// duplicate stored slots; they do not add logical capacity or response delay.
module mcu_reply_queue_ram (
    input wire clk, input wire rst_n, input wire flush,
    input wire write, input wire [279:0] write_data, input wire pop,
    output reg [3:0] count, output reg [279:0] front
);
    reg [279:0] memory [0:7] /* synthesis syn_ramstyle="block_ram" */;
    reg [2:0] write_ptr, read_ptr;
    reg [279:0] ram_ahead, forwarded;
    reg forward_valid;
    // Purpose: fetch the successor of the head AFTER this edge. Explicit
    // write forwarding defines collision data independent of the RAM mode.
    wire [2:0] ahead_address=read_ptr+(pop ? 3'd2 : 3'd1);
    wire [279:0] next_front=forward_valid ? forwarded : ram_ahead;
    always @(posedge clk) begin
        if (write && rst_n && !flush) memory[write_ptr]<=write_data;
        ram_ahead<=memory[ahead_address];
        forward_valid<=write && rst_n && !flush && write_ptr==ahead_address;
        if (write && rst_n && !flush && write_ptr==ahead_address)
            forwarded<=write_data;
    end
    // Purpose: direct first-word forwarding preserves the original queue's
    // visibility on empty writes and one-word simultaneous pop/push. For a
    // deeper queue the synchronous lookahead was prepared on the prior edge.
    // No RAM/head reset is needed: count prevents stale/uninitialized reads.
    always @(posedge clk) begin
        if (rst_n && !flush) begin
            if (write && (count==0 || (pop && count==1))) front<=write_data;
            else if (pop && count>1) front<=next_front;
        end
    end
    // Purpose: the caller reserves capacity before write, and pops only when
    // count is nonzero. Reset/epoch flush invalidates every queued response.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin count<=0;write_ptr<=0;read_ptr<=0;end
        else if (flush) begin count<=0;write_ptr<=0;read_ptr<=0;end
        else begin
            if(write)write_ptr<=write_ptr+1'b1;
            if(pop)read_ptr<=read_ptr+1'b1;
            case ({write,pop})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default:begin end
            endcase
        end
    end
endmodule
