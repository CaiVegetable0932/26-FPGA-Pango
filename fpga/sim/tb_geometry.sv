`timescale 1ns/1ps
// Purpose: exercise inverse-map edge behavior, signed distortion, RGB
// interpolation and atomic geometry/MCU-event frame commits in one clock.
module tb_geometry;
    reg clk=0, rst_n=0, request_valid=0;
    always #5 clk=~clk;
    reg [11:0] output_x=0, output_y=0;
    reg signed [31:0] a00=0,a01=0,a02=0,a10=0,a11=0,a12=0;
    reg signed [31:0] k1=0,k2=0,p1=0,p2=0,fx=0,fy=0,cx=0,cy=0;
    wire result_valid, source_valid;
    wire [11:0] x0,x1,y0,y1,frac_x,frac_y;
    geometry_inverse_map #(.WIDTH(8),.HEIGHT(6)) map_dut(
        .clk(clk),.rst_n(rst_n),.request_valid(request_valid),
        .output_x(output_x),.output_y(output_y),
        .a00(a00),.a01(a01),.a02(a02),.a10(a10),.a11(a11),.a12(a12),
        .k1(k1),.k2(k2),.p1(p1),.p2(p2),.fx(fx),.fy(fy),.cx(cx),.cy(cy),
        .result_valid(result_valid),.source_valid(source_valid),
        .x0(x0),.x1(x1),.y0(y0),.y1(y1),.frac_x(frac_x),.frac_y(frac_y));
    reg sample_valid=0, sample_source_valid=0;
    reg [11:0] sample_fx=0,sample_fy=0;
    reg [23:0] p00=0,p10=0,p01=0,p11=0;
    wire pixel_valid,pixel_source_valid;
    wire [23:0] pixel;
    geometry_bilinear_rgb blend_dut(.clk(clk),.rst_n(rst_n),
        .sample_valid(sample_valid),.source_valid(sample_source_valid),
        .frac_x(sample_fx),.frac_y(sample_fy),
        .p00(p00),.p10(p10),.p01(p01),.p11(p11),
        .pixel_valid(pixel_valid),.pixel(pixel),.pixel_source_valid(pixel_source_valid));
    reg frame_start=0,config_valid=0,env_valid=0;
    reg [447:0] config_words=0;
    reg [31:0] config_version=0,env_session_id=0,env_event_seq=0;
    reg [1:0] env_measurement_valid=0;
    reg signed [31:0] env_angle_mdeg=0;
    reg [63:0] env_epoch=0,env_board_time_us=0;
    reg mcu_context_valid=0;
    reg [63:0] mcu_epoch=0;
    reg [31:0] mcu_session_id=0;
    wire config_accepted,config_rejected,active_config_valid,active_angle_valid;
    wire [447:0] active_words;
    wire [31:0] active_version,active_angle_session_id,active_angle_event_seq;
    wire signed [31:0] active_angle_mdeg;
    wire [63:0] active_angle_epoch,active_angle_board_time_us;
    geometry_frame_control control_dut(.clk(clk),.rst_n(rst_n),.frame_start(frame_start),
        .config_valid(config_valid),.config_words(config_words),.config_version(config_version),
        .config_accepted(config_accepted),.config_rejected(config_rejected),
        .active_config_valid(active_config_valid),.active_words(active_words),
        .active_version(active_version),.env_valid(env_valid),
        .env_measurement_valid(env_measurement_valid),.env_angle_mdeg(env_angle_mdeg),
        .env_epoch(env_epoch),.env_board_time_us(env_board_time_us),
        .env_session_id(env_session_id),.env_event_seq(env_event_seq),
        .mcu_context_valid(mcu_context_valid),.mcu_epoch(mcu_epoch),
        .mcu_session_id(mcu_session_id),
        .active_angle_valid(active_angle_valid),.active_angle_mdeg(active_angle_mdeg),
        .active_angle_epoch(active_angle_epoch),.active_angle_board_time_us(active_angle_board_time_us),
        .active_angle_session_id(active_angle_session_id),.active_angle_event_seq(active_angle_event_seq));

    // Purpose: all request and control changes occur on falling edges, then
    // assertions inspect registered outputs after the following rising edge.
    task tick;
        begin @(posedge clk);#1; end
    endtask
    initial begin
        repeat(2) tick();
        @(negedge clk);rst_n=1;
        // Exact identity uses fx=fy=256 and reciprocal affine scale 1/256.
        a00=32'sd262144;a11=32'sd262144;
        fx=32'sd16777216;fy=32'sd16777216;
        output_x=7;output_y=5;request_valid=1;
        tick();
        if (!result_valid || !source_valid || x0!=7 || x1!=7 ||
            y0!=5 || y1!=5 || frac_x!=0 || frac_y!=0)
            $fatal(1,"GEOMETRY_IDENTITY_EDGE_FAIL %d %d %d %d %d %d",x0,x1,y0,y1,frac_x,frac_y);
        // A quarter radial term moves x=1 to 1.25, without moving y=0.
        @(negedge clk);a00=32'sd67108864;a11=32'sd67108864;
        fx=32'sd65536;fy=32'sd65536;k1=32'sd16777216;
        output_x=1;output_y=0;
        tick();
        if (!source_valid || x0!=1 || x1!=2 || frac_x!=1024 || y0!=0)
            $fatal(1,"GEOMETRY_RADIAL_FAIL %d %d %d",x0,x1,frac_x);
        // Tangential p2 contributes 3*p2*x^2 when x=1,y=0.
        @(negedge clk);k1=0;p2=32'sd16777216;
        tick();
        if (!source_valid || x0!=1 || frac_x!=3072)
            $fatal(1,"GEOMETRY_TANGENTIAL_FAIL %d %d",x0,frac_x);
        // The second radial term and p1 must independently affect mapping.
        @(negedge clk);p2=0;k2=32'sd16777216;
        tick();
        if (!source_valid || x0!=1 || frac_x!=1024)
            $fatal(1,"GEOMETRY_K2_FAIL %d %d",x0,frac_x);
        @(negedge clk);k2=0;p1=32'sd16777216;
        output_x=0;output_y=1;
        tick();
        if (!source_valid || y0!=1 || frac_y!=3072)
            $fatal(1,"GEOMETRY_P1_FAIL %d %d",y0,frac_y);
        // A signed affine off-diagonal maps an output pixel to (2,3).
        @(negedge clk);p1=0;a00=0;a01=32'sd67108864;
        a10=-32'sd67108864;a11=0;a12=32'sd268435456;
        output_x=1;output_y=2;
        tick();
        if (!source_valid || x0!=2 || y0!=3 || frac_x!=0 || frac_y!=0)
            $fatal(1,"GEOMETRY_AFFINE_ROTATE_FAIL %d %d",x0,y0);
        // Do not issue DDR addresses for negative/out-of-frame coordinates.
        @(negedge clk);a00=32'sd67108864;a01=0;a02=-32'sd67108864;
        a10=0;a11=32'sd67108864;a12=0;output_x=0;output_y=0;
        tick();
        if (!result_valid || source_valid || x0!=0 || x1!=0)
            $fatal(1,"GEOMETRY_NEGATIVE_BOUNDS_FAIL");
        @(negedge clk);a02=0;k1=32'sd16777216;output_x=7;
        tick();
        if (!result_valid || source_valid) $fatal(1,"GEOMETRY_HIGH_BOUNDS_FAIL");

        // A 2x2 RGB neighborhood at its center averages each color to 64.
        @(negedge clk);request_valid=0;sample_valid=1;sample_source_valid=1;
        sample_fx=2048;sample_fy=2048;
        p00=24'h000000;p10=24'hff0000;p01=24'h00ff00;p11=24'h0000ff;
        tick();
        if (!pixel_valid || !pixel_source_valid || pixel!==24'h404040)
            $fatal(1,"GEOMETRY_BILINEAR_FAIL %h",pixel);
        @(negedge clk);p00=24'hffffff;p10=p00;p01=p00;p11=p00;
        sample_fx=4095;sample_fy=4095;
        tick();
        if (pixel!==24'hffffff) $fatal(1,"GEOMETRY_BILINEAR_WHITE_FAIL %h",pixel);
        @(negedge clk);sample_source_valid=0;
        tick();
        if (!pixel_valid || pixel_source_valid || pixel!==0)
            $fatal(1,"GEOMETRY_BLACK_MASK_FAIL");

        // Valid config and V1 angle event remain shadowed until frame_start.
        @(negedge clk);sample_valid=0;config_words=0;
        config_words[351:320]=32'sd16777216;
        config_words[383:352]=32'sd16777216;
        config_words[31:0]=32'sd262144;
        config_version=32'd9;config_valid=1;
        env_valid=1;env_measurement_valid=2'b10;
        env_angle_mdeg=-32'sd45000;env_epoch=64'h1234;
        env_session_id=32'd7;env_event_seq=32'd11;env_board_time_us=64'd123456;
        mcu_context_valid=1;mcu_epoch=env_epoch;mcu_session_id=env_session_id;
        tick();
        if (!config_accepted || active_config_valid || active_angle_valid)
            $fatal(1,"GEOMETRY_SHADOW_FAIL");
        @(negedge clk);config_valid=0;env_valid=0;frame_start=1;
        tick();
        if (!active_config_valid || active_version!=9 || !active_angle_valid ||
            active_angle_mdeg!=-45000 || active_angle_event_seq!=11 ||
            active_angle_epoch!=64'h1234 || active_angle_board_time_us!=123456)
            $fatal(1,"GEOMETRY_FRAME_COMMIT_FAIL");
        // Invalid focal length cannot replace the previously active set.
        @(negedge clk);frame_start=0;config_words[351:320]=0;config_valid=1;
        tick();
        if (!config_rejected || active_version!=9) $fatal(1,"GEOMETRY_REJECT_FAIL");
        // Measurement validity loss is itself a frame-atomic event.
        @(negedge clk);config_valid=0;env_valid=1;env_measurement_valid=0;
        env_event_seq=12;
        tick();
        @(negedge clk);env_valid=0;frame_start=1;
        tick();
        if (active_angle_valid || active_angle_event_seq!=12)
            $fatal(1,"GEOMETRY_ANGLE_INVALIDATE_FAIL");
        // A replacement MCU session must revoke even the previous valid
        // posture before any fresh angle measurement arrives.
        @(negedge clk);frame_start=0;env_valid=1;env_measurement_valid=2'b10;
        env_angle_mdeg=32'sd6000;env_event_seq=13;
        tick();
        @(negedge clk);env_valid=0;frame_start=1;
        tick();
        if (!active_angle_valid) $fatal(1,"GEOMETRY_ANGLE_REVALIDATE_FAIL");
        @(negedge clk);frame_start=0;mcu_session_id=8;
        tick();
        if (active_angle_valid) $fatal(1,"GEOMETRY_STALE_SESSION_FAIL");
        // A delayed event from the old session must not become valid again.
        @(negedge clk);env_valid=1;env_session_id=7;env_event_seq=14;
        tick();
        @(negedge clk);env_valid=0;frame_start=1;
        tick();
        if (active_angle_valid) $fatal(1,"GEOMETRY_OLD_EVENT_FAIL");
        // Loading a new shadow set on frame_start leaves the current frame
        // on the old version and commits the new version next frame.
        @(negedge clk);frame_start=0;config_words[351:320]=32'sd16777216;
        config_version=10;config_valid=1;frame_start=1;
        tick();
        if (active_version!=9 || !config_accepted)
            $fatal(1,"GEOMETRY_SIMULTANEOUS_LOAD_FAIL");
        @(negedge clk);config_valid=0;frame_start=0;
        tick();
        @(negedge clk);frame_start=1;
        tick();
        if (active_version!=10) $fatal(1,"GEOMETRY_NEXT_FRAME_FAIL");
        $display("GEOMETRY_PASS");$finish;
    end
endmodule
