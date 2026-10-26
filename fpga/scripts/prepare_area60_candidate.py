"""Freeze independent area candidates from B3; keep route controls untouched.

Every edit is a checked source transformation, with old bytes, patches and a
new manifest. Native results decide whether an experiment is retained.
"""
import argparse
from datetime import datetime
import difflib
from functools import reduce
import hashlib
import json
from pathlib import Path
import re
import shutil


def replace(text, old, new, count=1):
    """Fail closed if the expected implementation no longer matches."""
    if text.count(old) != count:
        raise ValueError('Unexpected source fragment: ' + old[:160])
    return text.replace(old,new)


def refill_lanes(text):
    """Read three halfwords from one-address banks without adding latency."""
    first=text.index(' // Each row has three aligned')
    last=text.index(' // Predecode the next receive context',first)
    text=text[:first]+''' // Each row stores three 256-bit beats in sixteen 16-bit lane banks.
 // A quad needs three consecutive halfwords. Read each bank once, choosing
 // the adjacent beat only for lanes before the starting lane, then gather
 // the three required lanes. This preserves the original combinational
 // read latency without duplicating a full 256-bit read port per row.
 wire [3:0] write_beat={1'b0,returned}+{1'b0,segment_start};
 wire [5:0] halfword_offset={2'b0,quad}*6'd3;
 wire [1:0] read_beat=halfword_offset[5:4];
 wire [1:0] next_beat=read_beat==2 ? 2'd0 : read_beat+2'd1;
 wire [3:0] first_lane=halfword_offset[3:0];
 wire [3:0] second_lane=first_lane+4'd1,third_lane=first_lane+4'd2;
 wire [15:0] even_lane[0:15],odd_lane[0:15];
 wire [47:0] even_pair={even_lane[third_lane],even_lane[second_lane],even_lane[first_lane]};
 wire [47:0] odd_pair={odd_lane[third_lane],odd_lane[second_lane],odd_lane[first_lane]};
''' +text[last:]
    first=text.index(' // Current-cycle DMA payload')
    last=text.index(' // Capture, multiply',first)
    text=text[:first]+''' // Current-cycle DMA writes all lanes on the same original edge. Memories
 // remain unreset; valid-frame masks and drained response ownership protect
 // unwritten tail/virtual bytes. The fourth address remains unused.
 genvar lane;
 generate for(lane=0;lane<16;lane=lane+1)begin: halfword_bank
  reg [15:0] even_words[0:3] /* synthesis syn_ramstyle="lut_ram" */;
  reg [15:0] odd_words[0:3] /* synthesis syn_ramstyle="lut_ram" */;
  wire [1:0] lane_beat=first_lane>lane ? next_beat:read_beat;
  assign even_lane[lane]=even_words[lane_beat];
  assign odd_lane[lane]=odd_words[lane_beat];
  always @(posedge clk)begin
   if(rst_n && r_valid && write_beat<3)begin
    if(receive_odd)odd_words[write_beat[1:0]]<=r_data[lane*16+:16];
    if(receive_even)even_words[write_beat[1:0]]<=r_data[lane*16+:16];
   end
  end
 end endgenerate
''' +text[last:]
    return text


def fabric_bounds(text):
    """Use slot prefix containment plus the existing physical-page bound.

    Every frame slot is an integer multiple of 4096 bytes. Therefore a
    nonempty aligned request whose start belongs to that slot and whose span
    does not cross its current 4KiB page cannot escape the slot. Preserve the
    independent capacity check for generic smaller-capacity integrations.
    """
    first=text.index(' // Requests cannot address another frame')
    last=text.index(' // Narrow client selectors',first)
    text=text[:first]+''' // Frame slots end on 4KiB boundaries. Prefix membership proves that the
 // start belongs to the selected slot; the page-span check then proves the
 // entire request stays in that slot, including exact-end requests. This
 // avoids six wide slot-base additions and end-address comparisons. Keep
 // owner, length, alignment and small-capacity checks unchanged in meaning.
 always @* begin
  address_legal=0;slot_base=0;slot_end=0;span_end=0;slot_bytes=0;
  for(c=0;c<N;c=c+1) begin
   span_end={1'b0,req_addr[c*32+:32]}+({28'd0,req_beats[c*5+:5]}<<5);
   address_legal[c]=req_bank[c*3+:3]<3 && req_slot[c*2+:2]<3 &&
    req_owner[c*3+:3]<=4 && (req_write[c] ? req_owner[c*3+:3]==0 : req_owner[c*3+:3]!=0) &&
    req_beats[c*5+:5]!=0 && req_beats[c*5+:5]<=16 && req_addr[c*32+:5]==0 &&
    ((req_bank[c*3+:3]==0 && req_addr[c*32+23+:9]=={7'd0,req_slot[c*2+:2]}) ||
     (req_bank[c*3+:3]==1 && req_addr[c*32+23+:9]==9'd3+{7'd0,req_slot[c*2+:2]}) ||
     (req_bank[c*3+:3]==2 && req_addr[c*32+22+:10]==10'd12+{8'd0,req_slot[c*2+:2]})) &&
    (CAPACITY_BYTES>=32'h03c00000 || span_end<={1'b0,CAPACITY_BYTES}) &&
    ({1'b0,req_addr[c*32+5+:7]}+{3'd0,req_beats[c*5+:5]})<=8'd128;
  end
 end

''' +text[last:]
    return text


def pack_decode(text):
    """Share mutually exclusive byte selectors instead of priority updates."""
    first=text.index(' integer lane;')
    last=text.index(' always @(posedge clk or negedge rst_n)',first)
    text=text[:first]+''' // Each lane can receive only one of the three consecutive pixel bytes.
 // Decode those disjoint destinations once, OR their data, and use one byte
 // write enable. Drain/start clearing and even invalid output bytes retain
 // the original behavior, including simultaneous drain and RGB overflow.
 wire [34:0] write_low,write_mid,write_high;
 wire [279:0] pixel_lanes;
 genvar p;
 generate for(p=0;p<35;p=p+1)begin: byte_decode
  assign write_low[p]=take_pixel && append_at==p;
  assign write_mid[p]=take_pixel && mode && append_at+6'd1==p;
  assign write_high[p]=take_pixel && mode && append_at+6'd2==p;
  assign pixel_lanes[p*8+:8]=({8{write_low[p]}} & pixel[7:0]) |
   ({8{write_mid[p]}} & pixel[15:8]) | ({8{write_high[p]}} & pixel[23:16]);
 end endgenerate
 integer lane;
 always @* begin
  bytes_next=take_beat ? (bytes_q>>256) : bytes_q;
  mask_next=take_beat ? (mask_q>>32) : mask_q;
  count_next=append_at;
  for(lane=0;lane<35;lane=lane+1)begin
   if(write_low[lane] || write_mid[lane] || write_high[lane])begin
    bytes_next[lane*8+:8]=pixel_lanes[lane*8+:8];mask_next[lane]=1;
   end
  end
  if(take_pixel)count_next=append_at+(mode?6'd3:6'd1);
 end
''' +text[last:]
    return text


def stream_ccm_upload(text):
    """Prove coefficient extension/row bounds during the existing CRC stream."""
    text=replace(text,'parameter UNQUALIFIED_SUBMIT=0)', 'parameter UNQUALIFIED_SUBMIT=0,parameter STREAM_CCM=0)')
    text=replace(text,' reg [7:0] previous_lut_byte;reg lut_decreasing;', ''' reg [7:0] previous_lut_byte;reg lut_decreasing;
 // The optional board gateway validates the nine signed CCM words while
 // consuming new CRC bytes. One absolute-value unit and row accumulator
 // replace nine parallel validators at the consumer. Retried chunks never
 // advance this proof; the exact complete body and CRC are still required.
 reg [23:0] ccm_bytes;reg [19:0] ccm_row_sum;reg ccm_bad;
 wire [31:0] ccm_word={write_byte,ccm_bytes};
 wire [17:0] ccm_magnitude=ccm_word[17] ? (~ccm_word[17:0]+18'd1):ccm_word[17:0];
 wire ccm_row_first=write_address==19 || write_address==31 || write_address==43;
 wire ccm_row_last=write_address==27 || write_address==39 || write_address==51;
 wire [19:0] ccm_sum_next=(ccm_row_first?20'd0:ccm_row_sum)+{2'd0,ccm_magnitude};''')
    text=replace(text,'previous_lut_byte<=0;lut_decreasing<=0;', 'previous_lut_byte<=0;lut_decreasing<=0;ccm_bytes<=0;ccm_row_sum<=0;ccm_bad<=0;',2)
    text=replace(text,'(header[15:0]==2 && lut_decreasing))response_code<=11;',
                 '(header[15:0]==2 && lut_decreasing) || (STREAM_CCM && header[15:0]==3 && ccm_bad))response_code<=11;')
    text=replace(text,'    crc<=crc_byte(crc,write_byte);', '''    crc<=crc_byte(crc,write_byte);
    if(STREAM_CCM && header[15:0]==3 && write_address>=16 && write_address<52)begin
     ccm_bytes<={write_byte,ccm_bytes[23:8]};
     if(write_address[1:0]==3)begin
      ccm_row_sum<=ccm_sum_next;
      if(ccm_word[31:18]!={14{ccm_word[17]}} || (ccm_row_last && ccm_sum_next>131072))ccm_bad<=1;
     end
    end''')
    return text


def stream_ccm_colour(text):
    """Keep general callers' full validation; specialize the proven gateway."""
    text=replace(text,'parameter SUPPORT_AUTO=1)', 'parameter SUPPORT_AUTO=1,parameter CCM_PREVALIDATED=0)')
    text=replace(text,'  for(i=0;i<3;i=i+1)begin\n   row_bound=0;', '''  // Only the physical board's CRC-bound STREAM_CCM gateway may omit this
  // parallel proof. Direct callers keep signed extension and all row bounds.
  if(!CCM_PREVALIDATED)for(i=0;i<3;i=i+1)begin
   row_bound=0;''')
    return text


def stream_ccm_boot(text):
    """Bind the proof to the boot upload instance without new wire messages."""
    text=replace(text,"parameter [15:0] ENTITY_MASK=16'h0200)", "parameter [15:0] ENTITY_MASK=16'h0200,parameter STREAM_CCM=0)")
    text=replace(text,' pc_reference_upload #(.ENTITY_MASK(ENTITY_MASK),.UNQUALIFIED_SUBMIT(1))',
                 ' // STREAM_CCM is an internal proof; command formats and COMMIT timing stay unchanged.\n pc_reference_upload #(.ENTITY_MASK(ENTITY_MASK),.UNQUALIFIED_SUBMIT(1),.STREAM_CCM(STREAM_CCM))')
    return text


def stream_ccm_core(text):
    """Expose explicit proof specialization while retaining direct-core checks."""
    text=replace(text,' parameter MCU_CONFIG_DIGEST_ONLY=0,', ''' parameter MCU_CONFIG_DIGEST_ONLY=0,
 // Enable only with the sole board UART uploader's streaming CCM proof.
 parameter CCM_PREVALIDATED=0,''')
    text=replace(text,'isp_colour_control #(.SUPPORT_AUTO(IMAGE_AUTOMATION))',
                 'isp_colour_control #(.SUPPORT_AUTO(IMAGE_AUTOMATION),.CCM_PREVALIDATED(CCM_PREVALIDATED))')
    return text


def stream_ccm_board(text):
    """Pair both halves of the proof in the only physical-board upload path."""
    text=replace(text," pc_video_boot #(.ENTITY_MASK(16'h1bca))", ''' // The sole kind3 ingress proves coefficient rows during CRC upload. Pair
 // STREAM_CCM with the core specialization; no alternate unproved ingress.
 pc_video_boot #(.ENTITY_MASK(16'h1bca),.STREAM_CCM(1))''')
    text=replace(text,'.MCU_CONFIG_DIGEST_ONLY(1)', '.MCU_CONFIG_DIGEST_ONLY(1),.CCM_PREVALIDATED(1)')
    return text


def annotate_arithmetic(text,expressions):
    """Expose exact-width operators to the installed ADS APM mapping attribute.

    The guide's printed pp.69-71 supports block_mult for add/sub as well as
    multiply. No pipeline or clock/enable/reset semantics change here.
    """
    declarations=[]
    for name,width,expression,count in expressions:
        text=replace(text,expression,name,count)
        declarations.append(f' wire [{width-1}:0] {name} /* synthesis syn_dspstyle="block_mult" */ = {expression};')
    offset=text.index(' localparam ')
    return text[:offset]+''' // Exact modulo-width arithmetic is unchanged; ask installed ADS to use
 // available APM add/sub resources instead of LUT carry chains. This adds no
 // RTL stages. Native resource and timing results decide whether to retain it.
'''+ '\n'.join(declarations)+'\n'+text[offset:]


def apm_mcu(text):
    """Move wide time arithmetic without altering time bounds or protocol."""
    return annotate_arithmetic(text,[
        ('request_elapsed_apm',64,'now_us-request_start',2),
        ('sync_elapsed_apm',64,'now_us-sync_received_us',1),
        ('next_sync_apm',64,'now_us+SYNC_INTERVAL_US',1),
        ('sync_a_base_apm',64,'sync_t1+REQUEST_LINE_US',1),
        ('sync_b_base_apm',64,'sync_t4-REPLY_LINE_US',1),
        ('sync_a_apm',64,'sync_a_base-$signed(sync_t2)',1),
        ('sync_b_apm',64,'sync_b_base-$signed(sync_t3)',1),
        ('sync_rtt_apm',64,'sync_b-sync_a',1),
        ('sync_average_apm',64,'(sync_a>>>1)+(sync_b>>>1)+(sync_a[0] && sync_b[0])',1)])


def apm_selector(text):
    """Map timestamp math while preserving full public 64-bit identity."""
    # Expose the inner mapped-time addition separately from its validity mux.
    return annotate_arithmetic(text,[
        ('mapped_time_apm',64,'($signed(q[480+:64])+offset_q)',1),
        ('anchor_forward_apm',64,'target-sync_anchor',1),
        ('anchor_reverse_apm',64,'sync_anchor-target',1),
        ('sample_age_apm',64,'target-best_tick',3),
        ('uncertain_age_apm',64,'sample_age_apm+error_q',1)])


def selector_widths(text):
    """Bound private ring cursors by DEPTH, including final scan==DEPTH."""
    return replace(text,' integer wr,count,scan,left;', ''' // Ring position is 0..DEPTH-1; occupancy/remaining/final scan can reach
 // DEPTH. These widths retain that terminal value without 32-bit counters.
 localparam PTR_BITS=DEPTH<2?1:$clog2(DEPTH);
 localparam COUNT_BITS=DEPTH<2?1:$clog2(DEPTH+1);
 reg [PTR_BITS-1:0] wr;reg [COUNT_BITS-1:0] count,scan,left;''')


def apm_selector_balanced(text):
    """Keep the serial uncertainty addition in logic after the age APM."""
    text=apm_selector(text)
    return replace(text,
        'wire [63:0] uncertain_age_apm /* synthesis syn_dspstyle="block_mult" */',
        '// Avoid a second unregistered APM carry chain on the age decision.\n'
        ' wire [63:0] uncertain_age_apm')


def config_payload(text):
    """Remove reset only from a completely overwritten, pending-owned payload."""
    text=replace(text,'pending<=0;held_kind<=0;held<=0;held_version<=0;held_id<=0;', 'pending<=0;')
    text=replace(text,"pending<=1;held_kind<=kind;held<={64'b0,entity[959:0]};held_version<=version;held_id<=entity_id;",'pending<=1;')
    offset=text.index(' always @(posedge clk or negedge rst_n)')
    return text[:offset]+''' // Pending is the resettable ownership guard for every held-field read.
 // A legal enqueue overwrites the whole private payload before pending rises;
 // cold reset revokes it. Public active entities and versions still reset.
 always @(posedge clk)begin
  if(rst_n && submit_valid && submit_code==0)begin
   held_kind<=kind;held<={64'b0,entity[959:0]};held_version<=version;held_id<=entity_id;
  end
 end
'''+text[offset:]


def selector_payload(text):
    """Keep valid/state resets but drop reset from the private RAM read stage."""
    text=replace(text,'candidate_valid<=0;q<=0;qt<=0;best<=0;', 'candidate_valid<=0;best<=0;')
    text=replace(text,'0: begin q<=samples[scan];qt<=arrival[scan];row_stage<=1;end','0: begin row_stage<=1;end')
    offset=text.index(' always @(posedge clk or negedge rst_n)')
    return text[:offset]+''' // Stage 0 owns this private RAM payload. Stage 1/2 cannot consume it
 // before a fresh read; reset/clear revoke busy and restart row_stage. Keep
 // best and all public result resets so the no-sample result remains zero.
 always @(posedge clk)begin
  if(rst_n && !clear && busy && timing_step==0 && left!=0 && row_stage==0)begin
   q<=samples[scan];qt<=arrival[scan];
  end
 end
'''+text[offset:]


def stats_share(text):
    """Use the same post-pixel arithmetic for accumulators and EOF snapshots."""
    fields=[('next_luma',48,'accum','luma','selected'),
            ('next_count',32,'count',"1'b1",'selected'),
            ('next_dark',32,'dark_count','(luma<32)','selected'),
            ('next_saturated',32,'sat_count','(luma>=250)','selected'),
            ('next_red',48,'reds','pixel_rgb[23:16]','neutral'),
            ('next_green',48,'greens','pixel_rgb[15:8]','neutral'),
            ('next_blue',48,'blues','pixel_rgb[7:0]','neutral'),
            ('next_neutral',32,'neutrals',"1'b1",'neutral')]
    declarations=[]
    # Explicit original spellings make a changed EOF contract fail preparation.
    snapshots=['accum+(selected ? luma : 0)','count+selected','dark_count+(selected && luma<32)',
               'sat_count+(selected && luma>=250)','reds+(neutral?pixel_rgb[23:16]:0)',
               'greens+(neutral?pixel_rgb[15:8]:0)','blues+(neutral?pixel_rgb[7:0]:0)','neutrals+neutral']
    for (name,width,acc,value,valid),snapshot in zip(fields,snapshots):
        text=replace(text,snapshot,name)
        text=replace(text,acc+'<='+acc+'+'+value,acc+'<='+name)
        declarations.append(f' wire [{width-1}:0] {name}={acc}+({valid}?{value}:{width}\'d0);')
    offset=text.index(' always @(posedge clk or negedge rst_n)')
    return text[:offset]+''' // Accumulator update and last-pixel publication use one exact next-value
 // expression each. This removes duplicate arithmetic while preserving the
 // final included pixel, stalls, ROI selection and abort snapshots.
'''+ '\n'.join(declarations)+'\n'+text[offset:]


def mult_apm(text):
    """Keep all partial products/stages; map the two exact reductions to APM."""
    text=replace(text,'  cross_term<=$signed({lh[32],lh})+$signed({hl[32],hl});','  cross_term<=cross_sum;')
    text=replace(text,'  product<=base+($signed({{30{cross_term[33]}},cross_term})<<<16);','  product<=product_sum;')
    offset=text.index(' always @(posedge clk)')
    return text[:offset]+''' // Installed ADS supports APM add/sub mapping on these result operators.
 // Preserve the exact 34/64-bit reductions and the existing three-stage CE
 // pipeline; the diagnostic SYN/STA will decide the resource/timing tradeoff.
 wire signed [33:0] cross_sum /* synthesis syn_dspstyle="block_mult" */ =
  $signed({lh[32],lh})+$signed({hl[32],hl});
 wire signed [63:0] product_sum /* synthesis syn_dspstyle="block_mult" */ =
  base+($signed({{30{cross_term[33]}},cross_term})<<<16);
'''+text[offset:]


def step49(text):
    """Use the exact full-input affine accumulator bound, including terminal row."""
    text=replace(text,' reg signed [63:0] line_x,line_y,acc_x,acc_y;', ''' // Signed32 coefficients and admitted unsigned16 coordinates bound every
 // origin/step to [-2^48,2^48). This also includes the unused terminal line
 // at v=65536: two coordinate weights plus translation total at most 131072.
 // Signed49 therefore retains every bit for all legal regions, even those
 // rejected later by the public ray-range checks; no calibration clipping.
 reg signed [48:0] line_x,line_y,acc_x,acc_y;''')
    text=replace(text,' reg signed [63:0] origin_x_sum,origin_y_sum;', ' reg signed [48:0] origin_x_sum,origin_y_sum;')
    return text


def bilinear_payload(text):
    """Separate originally unreset payload while retaining reset hold and II=1."""
    start=text.index('   tags[0]<=in_tag;')
    end=text.index('    result[c*8+:8]',start)
    payload=text[start:end]
    # The shared loop formerly carried both resettable output and unreset sums.
    # Keep distinct loop variables so the two clocked processes cannot race.
    text=text[:start]+'   for(c=0;c<3;c=c+1) begin\n'+text[end:]
    payload=re.sub(r'\bj\b','payload_j',payload)
    payload=re.sub(r'\bc\b','payload_c',payload)
    return replace(text,'endmodule', ''' // Payload held its old value throughout reset in the original process.
 // An explicit synchronous guard preserves that behavior while allowing ADS
 // to infer native CE registers without an asynchronous reset-hold feedback.
 integer payload_c,payload_j;
 always @(posedge clk) if(rst_n && advance) begin
'''+payload+'   end\n end\nendmodule')


def enhance_payload(text):
    """Keep valid/mask reset; separate exactly the existing held payload writes."""
    text=replace(text,'    pre_a<=in_a;pre_b<=in_b;pre_tag<=in_tag;\n    pre_raw<=in_samples;','')
    text=replace(text,'post_mask<=core_mask;post_tag<=core_tag;','post_mask<=core_mask;')
    text=replace(text,"    post_rgb<=core_mask ? core_rgb : 24'd0;",'')
    return replace(text,'endmodule', ''' // These payload registers have always held across reset. Keep the same
 // guard/enable boundaries in a clock-only process; public validity and masks
 // still reset immediately, and no latency or page ownership is changed.
 always @(posedge clk) if(rst_n) begin
  if(pre_ready)begin pre_a<=in_a;pre_b<=in_b;pre_tag<=in_tag;pre_raw<=in_samples;end
  if(post_ready)begin post_tag<=core_tag;post_rgb<=core_mask ? core_rgb : 24'd0;end
 end
endmodule''')


def colour_payload(text):
    """Keep public RGB reset, but infer native enables for products and tags."""
    text=replace(text,';tag[0]<=in_tag;tag[1]<=tag[0];tag[2]<=tag[1];',';')
    start=text.index('    for(j=0;j<3;');end=text.index('    out_rgb',start)
    payload=text[start:end]
    text=text[:start]+text[end:]
    payload=re.sub(r'\bi\b','payload_i',payload)
    payload=re.sub(r'\bj\b','payload_j',payload)
    return replace(text,'endmodule', ''' // Unreset products/tags retain reset-hold semantics behind the original
 // advance enable. Only validity, masks and public RGB use asynchronous reset.
 integer payload_i,payload_j;
 always @(posedge clk) if(rst_n && advance) begin
  tag[0]<=in_tag;tag[1]<=tag[0];tag[2]<=tag[1];
  for(payload_i=0;payload_i<3;payload_i=payload_i+1)begin
'''+payload+'  end\n end\nendmodule')


def lens_apm(text):
    """Test dedicated adders for exact lens sums without changing rounding."""
    for name in ('r2_sum','horner_round','tx_round','ty_round','xd_round','yd_round'):
        text=replace(text,'wire signed [63:0] '+name+'=',
                     'wire signed [63:0] '+name+' /* synthesis syn_dspstyle="block_mult" */ =')
    text=replace(text,"   us<=up+($signed({{32{cx[31]}},cx})<<<20);vs<=vp+($signed({{32{cy[31]}},cy})<<<20);",
                 '   us<=projection_x_sum;vs<=projection_y_sum;')
    return replace(text,' integer i;', ''' // Only the mapping preference changes: preserve full signed64 products,
 // each original round/shift location, modulo arithmetic and all overflow tests.
 // APM capacity and timing must be measured before selecting this candidate.
 wire signed [63:0] projection_x_sum /* synthesis syn_dspstyle="block_mult" */ =
  up+($signed({{32{cx[31]}},cx})<<<20);
 wire signed [63:0] projection_y_sum /* synthesis syn_dspstyle="block_mult" */ =
  vp+($signed({{32{cy[31]}},cy})<<<20);
 integer i;''')


def pose_payload(text):
    """Guard private pose work by request ownership and bound accepted deltas."""
    text=replace(text,'reg signed [32:0] dp,dy;', '''// The full signed33 subtraction/domain gate remains below. Only admitted
 // deltas in [-90000,90000] enter a busy calculation, so signed18 is exact.
 reg signed [17:0] dp,dy;''')
    for old,new in [
      ('busy<=0;result_valid<=0;matrix<=0;working<=0;fallback<=0;','busy<=0;result_valid<=0;matrix<=0;'),
      ('base_coefficients<=0;pitch_coefficients<=0;yaw_coefficients<=0;index<=0;phase<=0;','index<=0;phase<=0;'),
      ('   dp<=0;dy<=0;ap<=0;ay<=0;pitch_q30<=0;yaw_q30<=0;pitch_product<=0;yaw_product<=0;',''),
      ('matrix<=manual_matrix;fallback<=manual_matrix;','matrix<=manual_matrix;'),
      ('calibration_id<=calibration[63:32];base_coefficients<=calibration[384+:192];','calibration_id<=calibration[63:32];'),
      ('    pitch_coefficients<=calibration[576+:192];yaw_coefficients<=calibration[768+:192];',''),
      ('index<=0;phase<=0;dp<=delta_p;dy<=delta_y;','index<=0;phase<=0;'),
      ('0:begin ap<=dp*RAD_PER_MDEG_Q46;ay<=dy*RAD_PER_MDEG_Q46;phase<=1;end','0:begin phase<=1;end'),
      ('1:begin pitch_q30<=(ap+32768)>>>16;yaw_q30<=(ay+32768)>>>16;phase<=2;end','1:begin phase<=2;end'),
      ('2:begin pitch_product<=$signed(pitch_coefficients[31:0])*pitch_q30;\n      yaw_product<=$signed(yaw_coefficients[31:0])*yaw_q30;phase<=3;end','2:begin phase<=3;end'),
      ('       working<={coefficient[31:0],working[191:32]};',''),
      ("        base_coefficients<={32'b0,base_coefficients[191:32]};\n        pitch_coefficients<={32'b0,pitch_coefficients[191:32]};\n        yaw_coefficients<={32'b0,yaw_coefficients[191:32]};",'')]:
        text=replace(text,old,new)
    return replace(text,'endmodule', ''' // Private operands are installed by an accepted request, then consumed
 // only by its busy phase. Clear/reset revoke busy before any stale operand
 // can reach a result. Six successful shifts fully replace working before
 // publication; public matrix/identity/status retain their original reset.
 always @(posedge clk) if(rst_n && !clear)begin
  if(request_valid && request_ready)begin
   fallback<=manual_matrix;base_coefficients<=calibration[384+:192];
   pitch_coefficients<=calibration[576+:192];yaw_coefficients<=calibration[768+:192];
   dp<=delta_p;dy<=delta_y;
  end else if(busy)begin
   case(phase)
    0:begin ap<=dp*RAD_PER_MDEG_Q46;ay<=dy*RAD_PER_MDEG_Q46;end
    1:begin pitch_q30<=(ap+32768)>>>16;yaw_q30<=(ay+32768)>>>16;end
    2:begin pitch_product<=$signed(pitch_coefficients[31:0])*pitch_q30;
     yaw_product<=$signed(yaw_coefficients[31:0])*yaw_q30;end
    3:if(coefficient<=2147483647 && coefficient>=-66'sd2147483648)begin
     working<={coefficient[31:0],working[191:32]};
     if(index!=5)begin
      base_coefficients<={32'b0,base_coefficients[191:32]};
      pitch_coefficients<={32'b0,pitch_coefficients[191:32]};
      yaw_coefficients<={32'b0,yaw_coefficients[191:32]};
     end
    end
   endcase
  end
 end
endmodule''')


def main():
    """Select one experiment without altering B3 or production RTL."""
    parser=argparse.ArgumentParser(description=__doc__)
    variants={'refill_lanes':{'rtl/memory/geometry_tile_refill.sv':refill_lanes},
              'fabric_bounds':{'rtl/memory/frame_memory_fabric.sv':fabric_bounds},
              'pack_decode':{'rtl/memory/dma_pixel_pack.v':pack_decode},
              'stream_ccm':{'rtl/control/pc_reference_upload.sv':stream_ccm_upload,
                            'rtl/control/pc_video_boot.sv':stream_ccm_boot,
                            'rtl/isp/isp_colour_control.sv':stream_ccm_colour,
                            'rtl/board/video_memory_core.sv':stream_ccm_core,
                            'rtl/board/pango_video_system.sv':stream_ccm_board},
              'time_apm':{'rtl/control/mcu_readonly_client.sv':apm_mcu,
                          'rtl/control/pose_frame_selector.sv':apm_selector},
              'time_apm_balanced':{'rtl/control/mcu_readonly_client.sv':apm_mcu,
                                   'rtl/control/pose_frame_selector.sv':apm_selector_balanced},
              'selector_widths':{'rtl/control/pose_frame_selector.sv':selector_widths},
              'private_payload':{'rtl/control/pose_frame_selector.sv':selector_payload,
                                 'rtl/stabilization/motion_config_bank.sv':config_payload},
              'stats_share':{'rtl/isp/rgb_frame_statistics.sv':stats_share},
              'mult_apm':{'rtl/geometry/signed_mult32_pipe.sv':mult_apm},
              'step49':{'rtl/geometry/affine_ray_stepper.sv':step49},
              'image_payload':{'rtl/geometry/rgb_bilinear.sv':bilinear_payload,
                               'rtl/geometry/rgb_enhance.sv':enhance_payload,
                               'rtl/isp/rgb_colour_matrix.sv':colour_payload},
              'lens_apm':{'rtl/geometry/lens_inverse_map.sv':lens_apm},
              'pose_payload':{'rtl/control/pose_affine_model.sv':pose_payload}}
    parser.add_argument('--variant',choices=list(variants)+['combined'],required=True)
    parser.add_argument('--include',nargs='+',choices=list(variants),help='Ordered, explicit composition for a combined candidate')
    args=parser.parse_args()
    fpga=Path(__file__).resolve().parents[1]
    base=fpga/'build/block_pressure_20261025/candidate_20261025_003623_380294'
    hashes=json.loads((base/'sources.json').read_text())
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    assert all(sha(base/'source'/n)==h for n,h in hashes.items())
    run=fpga/'build/area60_20261025'/datetime.now().strftime(args.variant+'_%Y%m%d_%H%M%S_%f')
    run.mkdir(parents=True)
    shutil.copytree(base/'source',run/'source')
    shutil.copyfile(base/'sources.json',run/'baseline_sources.json')
    if args.variant=='combined':
        if not args.include:parser.error('combined requires --include')
        grouped={}
        for variant in args.include:
            for name,operation in variants[variant].items():grouped.setdefault(name,[]).append(operation)
        operations={name:(lambda text,ops=ops:reduce(lambda t,f:f(t),ops,text)) for name,ops in grouped.items()}
    else:operations=variants[args.variant]
    for name,operation in operations.items():
        p=run/'source'/name
        old=p.read_text(encoding='utf-8');new=operation(old)
        original=run/'baseline'/name;original.parent.mkdir(parents=True,exist_ok=True)
        original.write_bytes(p.read_bytes());p.write_text(new,encoding='utf-8')
        patch=run/'patches'/(name+'.patch');patch.parent.mkdir(parents=True,exist_ok=True)
        patch.write_text(''.join(difflib.unified_diff(old.splitlines(True),new.splitlines(True),fromfile='a/fpga/'+name,tofile='b/fpga/'+name)),encoding='utf-8')
    (run/'sources.json').write_text(json.dumps({n:sha(run/'source'/n) for n in hashes},indent=2),encoding='utf-8')
    (run/'candidate.json').write_text(json.dumps(dict(variant=args.variant,included_variants=args.include if args.variant=='combined' else [args.variant],baseline=str(base),changed_files=list(operations),
        target_map_lut=39960,production_selected=False,routed=False,hardware_tested=False),indent=2),encoding='utf-8')
    shutil.copyfile(__file__,run/'preparation_script.py')
    print(run,flush=True)


if __name__=='__main__':
    main()
