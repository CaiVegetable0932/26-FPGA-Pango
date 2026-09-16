// Purpose: request a frame-FIFO restart on camera VSYNC and rotate vendor frame slots.
// NOT a complete frame-pool protocol: read index is not a DDR write-completion token.
module cmos_write_req_gen(
	input              rst,
	input              pclk,
	input              cmos_vsync,
	output reg         write_req,
	output reg[1:0]    write_addr_index,
	output reg[1:0]    read_addr_index,
	input              write_req_ack
);
reg cmos_vsync_d0;
reg cmos_vsync_d1;
// Purpose: synchronize the level acknowledgement from the DDR user clock.
(* syn_preserve = 1 *) reg ack_meta, ack_sync;
always @(posedge pclk or posedge rst)
    if (rst) begin ack_meta <= 0; ack_sync <= 0; end
    else begin ack_meta <= write_req_ack; ack_sync <= ack_meta; end
always@(posedge pclk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		cmos_vsync_d0 <= 1'b0;
		cmos_vsync_d1 <= 1'b0;
	end
	else
	begin
		cmos_vsync_d0 <= cmos_vsync;
		cmos_vsync_d1 <= cmos_vsync_d0;
	end
end
always@(posedge pclk or posedge rst)
begin
	if(rst == 1'b1)
		write_req <= 1'b0;
	else if(cmos_vsync_d0 == 1'b1 && cmos_vsync_d1 == 1'b0)
		write_req <= 1'b1;
	else if(ack_sync == 1'b1)
		write_req <= 1'b0;
end
always@(posedge pclk or posedge rst)
begin
	if(rst == 1'b1)
		write_addr_index <= 2'b0;
	else if(cmos_vsync_d0 == 1'b1 && cmos_vsync_d1 == 1'b0)
		write_addr_index <= write_addr_index + 2'd1;
end

always@(posedge pclk or posedge rst)
begin
	if(rst == 1'b1)
		read_addr_index <= 2'b0;
	else if(cmos_vsync_d0 == 1'b1 && cmos_vsync_d1 == 1'b0)
		read_addr_index <= write_addr_index;
end
endmodule 
