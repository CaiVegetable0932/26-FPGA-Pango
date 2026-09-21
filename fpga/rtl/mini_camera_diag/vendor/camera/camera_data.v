// Purpose: sample one source-synchronous DVP bundle and pair high/low RGB565 bytes.
// Admit frames only at VSYNC fall after verified startup; a short/long row aborts
// remaining pixels until the next frame. DDR owns complete-frame publication.
module camera_data #(
    parameter FRAME_WIDTH=1280, FRAME_HEIGHT=720, WARMUP_FRAMES=10
)(
    input wire clk,rst_n,vsync,href,input wire [7:0] din,
    input wire cfg_done,ddr_init,
    output reg [15:0] pixel_data,output wire wf_wr_en,
    output reg sop,eop,vs,hs,output wire [7:0] capture_status
);
    // Purpose: synchronize readiness levels only. DVP pins must remain aligned
    // to their common PCLK; independently synchronizing data/control loses bytes.
    (* syn_preserve=1 *) reg cfg_meta,cfg_sync,ddr_meta,ddr_sync;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) begin cfg_meta<=0;cfg_sync<=0;ddr_meta<=0;ddr_sync<=0;end
        else begin cfg_meta<=cfg_done;cfg_sync<=cfg_meta;ddr_meta<=ddr_init;ddr_sync<=ddr_meta;end
    reg vsync_prev,href_prev,active,frame_admit,pixel_valid;
    reg [15:0] byte_count,row_count;
    reg [31:0] eop_cnt;
    reg [7:0] high_byte;
    wire frame_start=vsync_prev && !vsync;
    wire warmed=eop_cnt>=WARMUP_FRAMES;
    assign wf_wr_en=pixel_valid && cfg_sync && ddr_sync;
    // Purpose: expose actual PCLK-domain gates and sticky events, not inferred
    // sys_clk readiness. Each output is independently synchronized for LED display.
    reg frame_seen,admit_seen,bad_line_seen;
    assign capture_status={bad_line_seen,admit_seen,frame_seen,warmed,
                           (eop_cnt!=0),ddr_sync,cfg_sync,rst_n};
    always @(posedge clk or negedge rst_n)
        if(!rst_n) begin frame_seen<=0;admit_seen<=0;bad_line_seen<=0;end
        else if(cfg_sync) begin
            if(frame_start) begin frame_seen<=1;if(warmed && ddr_sync)admit_seen<=1;end
            if(active && ((href_prev && (!href || (vsync && !vsync_prev)) &&
                           byte_count!=FRAME_WIDTH*2) ||
                          (!vsync && href && !frame_start && byte_count>=FRAME_WIDTH*2)))
                bad_line_seen<=1;
        end

    // Purpose: explicit per-line byte phase and per-frame admission. Warmup counts
    // only exact-length final rows, never VSYNC activity or isolated good lines.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            vsync_prev<=1;href_prev<=0;active<=0;frame_admit<=0;
            byte_count<=0;row_count<=0;eop_cnt<=0;high_byte<=0;
            pixel_data<=0;pixel_valid<=0;sop<=0;eop<=0;vs<=0;hs<=0;
        end else begin
            vsync_prev<=vsync;href_prev<=href;
            pixel_valid<=0;sop<=0;eop<=0;
            // Preserve blanking for the DDR request generator before admitted data starts.
            vs<=vsync && cfg_sync && ddr_sync && warmed;
            hs<=href && cfg_sync && ddr_sync && warmed;
            if(!cfg_sync) begin
                active<=0;frame_admit<=0;byte_count<=0;row_count<=0;eop_cnt<=0;
            end else begin
                // Purpose: VSYNC also closes the active row even when HREF falls later
                // during blanking. Count no blanking byte; match the raw-frame observer.
                // active clears below/on final row, so a later HREF fall cannot count twice.
                if(href_prev && (!href || (vsync && !vsync_prev)) && active) begin
                    if(byte_count==FRAME_WIDTH*2) begin
                        if(row_count==FRAME_HEIGHT-1) begin
                            active<=0;
                            if(!warmed) eop_cnt<=eop_cnt+1;
                        end else row_count<=row_count+1;
                    end else begin active<=0;frame_admit<=0; end
                end
                if(vsync) begin active<=0;frame_admit<=0;byte_count<=0;row_count<=0; end
                else if(frame_start) begin
                    active<=1;frame_admit<=warmed && ddr_sync;row_count<=0;
                    // VSYNC fall may coincide with the very first valid byte.
                    byte_count<=href ? 1 : 0;
                    if(href) high_byte<=din;
                end else if(!href) byte_count<=0;
                else if(active) begin
                    if(byte_count>=FRAME_WIDTH*2) begin
                        active<=0;frame_admit<=0; // no wrapping an overlong row into a new row
                    end else begin
                        byte_count<=byte_count+1;
                        if(!byte_count[0]) high_byte<=din;
                        else begin
                            pixel_data<={high_byte,din};pixel_valid<=frame_admit;
                            sop<=row_count==0 && byte_count==1;
                            eop<=row_count==FRAME_HEIGHT-1 && byte_count==FRAME_WIDTH*2-1;
                        end
                    end
                end
            end
        end
    end
endmodule
