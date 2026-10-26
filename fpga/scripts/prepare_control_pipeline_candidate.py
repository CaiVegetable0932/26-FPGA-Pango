"""Freeze local consumer acceptance and tone validation without changing live routing."""
from datetime import datetime
import difflib
import hashlib
import json
from pathlib import Path
import shutil


def sha(path):
    """Bind each experiment to the exact selected source closure."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def replace(text, old, new):
    """Reject drift instead of silently applying a partial RTL transformation."""
    if text.count(old) != 1:
        raise ValueError('Unexpected source fragment: ' + old)
    return text.replace(old, new)


def transform(name, text):
    """Localize acceptance and pipeline static tone checks; arbitrate at COMMIT."""
    if name.endswith('pc_reference_upload.sv'):
        text = replace(text, 'parameter STREAM_CCM=0)(', 'parameter STREAM_CCM=0,parameter COMMIT_SETTLE=0)(')
        text = replace(text, 'COMMIT=3,RESPONSE=4;', 'COMMIT=3,RESPONSE=4,SETTLE=5;')
        text = replace(text, 'else begin state<=COMMIT;validation_wait<=0;end',
                         'else begin state<=COMMIT_SETTLE?SETTLE:COMMIT;validation_wait<=0;end')
        text = replace(text, '   if(state==COMMIT)begin', '''   // Board-only registered body validators need one full stable cycle before
   // the acceptance edge. SETTLE locks header/body just like COMMIT; it does
   // not pulse a consumer, acknowledge success, or change retry ownership.
   if(state==SETTLE)state<=COMMIT;
   if(state==COMMIT)begin''')
    elif name.endswith('pc_video_boot.sv'):
        text = replace(text, 'parameter STREAM_CCM=0)(', 'parameter STREAM_CCM=0,parameter COMMIT_SETTLE=0)(')
        text = replace(text, '// STREAM_CCM is an internal proof; command formats and COMMIT timing stay unchanged.',
                         '// Streaming CCM proof and optional COMMIT settling preserve the wire format.\n // Settling holds the upload body for registered static consumer checks.')
        text = replace(text, '.STREAM_CCM(STREAM_CCM)) upload', '.STREAM_CCM(STREAM_CCM),.COMMIT_SETTLE(COMMIT_SETTLE)) upload')
        text = replace(text, ' output entity_submit_valid,output [15:0]', ''' // Raw attempt supports local consumer acceptance at the board boundary.
 // The historical accepted-only output and response-code handshake remain.
 output entity_submit_attempt,output entity_submit_valid,output [15:0]''')
        text = replace(text, ' assign entity_submit_valid=upload_submit', ''' assign entity_submit_attempt=upload_submit && entity_kind!=9;
 assign entity_submit_valid=upload_submit''')
    elif name.endswith('tone_entity_control.sv'):
        text = replace(text, 'SUPPORT_UPLOAD=1)(', 'SUPPORT_UPLOAD=1,REGISTER_BODY_CHECK=0)(')
        text = replace(text, ' reg config_legal,lut_legal;integer i;', ''' reg config_legal,lut_legal;integer i;
 // Enable only behind the board uploader's COMMIT_SETTLE handshake. The
 // complete body must be stable for one clock before submit_valid and stay
 // fixed until acceptance. Register only static body legality: current
 // version, page ownership, seeded/pending and generation remain live.
 // Direct consumers retain the original same-cycle validation by default.
 reg config_legal_q;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)config_legal_q<=0;
  else config_legal_q<=config_legal;
 wire checked_config_legal=REGISTER_BODY_CHECK?config_legal_q:config_legal;''')
        # uploaded_version is mutable; move its dependency out of the static
        # predicate so even optional upload callers retain live arbitration.
        text = replace(text, '  if(body[15:8]==3 && (body[7:0]==2 || body[95:64]!=uploaded_version || uploaded_version==0))config_legal=0;',
                         '  if(body[15:8]==3 && body[7:0]==2)config_legal=0;')
        text = replace(text, '!config_legal || version<=active_version',
                         '!checked_config_legal || (body[15:8]==3 && (body[95:64]!=uploaded_version || uploaded_version==0)) || version<=active_version')
    elif name.endswith('video_memory_core.sv'):
        text = replace(text, 'parameter CCM_PREVALIDATED=0,', '''parameter CCM_PREVALIDATED=0,
 // Requires the sole board UART gateway's COMMIT_SETTLE stable-body stage.
 parameter TONE_REGISTER_BODY_CHECK=0,MOTION_REGISTER_BODY_CHECK=0,POSE_MATCH_PIPELINE=0,
 // Board supplies raw image attempts; gate each consumer with its own code
 // so another entity's validator cannot feed this consumer's arbitration.
 parameter QUALIFY_IMAGE_LOCALLY=0,''')
        text = replace(text, '.SUPPORT_UPLOAD(TONE_UPLOAD)) tone_control', '.SUPPORT_UPLOAD(TONE_UPLOAD),.REGISTER_BODY_CHECK(TONE_REGISTER_BODY_CHECK)) tone_control')
        text = replace(text, 'SUPPORT_CONTROLS && image_submit_valid && image_kind==3)',
                         'SUPPORT_CONTROLS && image_submit_valid && image_kind==3 && (!QUALIFY_IMAGE_LOCALLY || colour_code==0))')
        text = replace(text, 'SUPPORT_CONTROLS && image_submit_valid && (image_kind==1 || image_kind==2))',
                         'SUPPORT_CONTROLS && image_submit_valid && (image_kind==1 || image_kind==2) && (!QUALIFY_IMAGE_LOCALLY || tone_code==0))')
        text = replace(text, '.SUPPORT_VIEWPORT(SUPPORT_VIEWPORT)) motion_control',
                         '.SUPPORT_VIEWPORT(SUPPORT_VIEWPORT),.REGISTER_CONFIG_CHECK(MOTION_REGISTER_BODY_CHECK),.REGISTER_POSE_MATCH(POSE_MATCH_PIPELINE)) motion_control')
    elif name.endswith('pango_video_system.sv'):
        text = replace(text, '.STREAM_CCM(1)) boot', '.STREAM_CCM(1),.COMMIT_SETTLE(1)) boot')
        text = replace(text, '.CCM_PREVALIDATED(1),', '.CCM_PREVALIDATED(1),.TONE_REGISTER_BODY_CHECK(1),.MOTION_REGISTER_BODY_CHECK(1),.POSE_MATCH_PIPELINE(1),.QUALIFY_IMAGE_LOCALLY(1),')
        text = replace(text, ' pc_video_boot #(', ''' // Pair COMMIT settling with the core's registered tone-body check. Only
 // the immutable CRC-verified upload body crosses this one-cycle boundary.
 pc_video_boot #(''')
        text = replace(text, ' wire entity_submit_valid;', ' wire entity_submit_valid,entity_submit_attempt;')
        text = replace(text, '.entity_submit_valid(entity_submit_valid),', '.entity_submit_valid(entity_submit_valid),.entity_submit_attempt(entity_submit_attempt),')
        text = replace(text, '.submit_valid(entity_submit_valid && entity_kind==7)', '.submit_valid(entity_submit_attempt && entity_kind==7 && camera_submit_code==0)')
        text = replace(text, '.submit_valid(entity_submit_valid && entity_kind==12)', '.submit_valid(entity_submit_attempt && entity_kind==12 && mcu_policy_code==0)')
        text = replace(text, '.motion_submit_valid(entity_submit_valid && motion_kind_selected)', '.motion_submit_valid(entity_submit_attempt && motion_kind_selected && motion_submit_code==0)')
        text = replace(text, '.image_submit_valid(entity_submit_valid && image_kind_selected)', '.image_submit_valid(entity_submit_attempt && image_kind_selected)')
        text = replace(text, ' assign entity_submit_code=', ''' // Each consumer accepts its raw attempt using only its own live code.
 // The shared code mux serves UART replies, never distributed register CE.
 // Kind selection makes these acceptance conditions identical to the former
 // global accepted pulse, including BUSY/invalid/validation-wait rejection.
 assign entity_submit_code=''')
    elif name.endswith('motion_config_bank.sv'):
        text = replace(text, 'parameter SUPPORT_VIEWPORT=1)(', 'parameter SUPPORT_VIEWPORT=1,REGISTER_BODY_CHECK=0)(')
        text = replace(text, ' reg [31:0] ids[0:3];', ''' // The board uploader holds kind/body through COMMIT_SETTLE. Only the
 // static schema predicate is registered; active version and pending remain
 // live so a coincident frame publication cannot use stale arbitration.
 reg legal_q;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)legal_q<=0;
  else legal_q<=legal;
 wire checked_legal=REGISTER_BODY_CHECK?legal_q:legal;
 reg [31:0] ids[0:3];''')
        text = replace(text, '?8\'d6:!legal || version==0', '?8\'d6:!checked_legal || version==0')
    elif name.endswith('source_motion_controller.sv'):
        text = replace(text, 'SUPPORT_VIEWPORT=1)(', 'SUPPORT_VIEWPORT=1,REGISTER_CONFIG_CHECK=0,REGISTER_POSE_MATCH=0)(')
        text = replace(text, 'motion_config_bank #(.SUPPORT_VIEWPORT(SUPPORT_VIEWPORT))', 'motion_config_bank #(.SUPPORT_VIEWPORT(SUPPORT_VIEWPORT),.REGISTER_BODY_CHECK(REGISTER_CONFIG_CHECK))')
        text = replace(text, ' wire pose_valid;', ''' // Optionally separate wide epoch/frame matching from the slot RAM read,
 // angle subtraction and domain gate. The selector holds its result until
 // selected_ready. Recheck the registered slot's identity at acceptance: a
 // source allocation during the extra cycle must never borrow a new frame's
 // calibration. An unmatched/stale result is drained without model work.
 wire model_ready,model_request;wire [1:0] model_slot;
 generate if(REGISTER_POSE_MATCH)begin: match_pipeline
  reg pending,found;reg [1:0] slot;
  wire still_owned=found && source_valid[slot] && sepoch[slot]==selected_epoch && sframe[slot]==selected_frame;
  assign model_slot=slot,model_request=selected_valid && pending && still_owned;
  assign selected_ready=pending && model_ready;
  always @(posedge clk or negedge rst_n)begin
   if(!rst_n)begin pending<=0;found<=0;slot<=0;end
   else if(!selected_valid || toggle)pending<=0;
   else if(!pending)begin pending<=1;found<=selected_found;slot<=selected_slot;end
   else if(selected_ready)pending<=0;
  end
 end else begin: match_direct
  assign model_slot=selected_slot,model_request=selected_valid && selected_found;
  assign selected_ready=model_ready;
 end endgenerate
 wire pose_valid;''')
        text = replace(text, '.request_valid(selected_valid && selected_found),.request_ready(selected_ready)', '.request_valid(model_request),.request_ready(model_ready)')
        text = replace(text, '.affine_enable(source_enable[selected_slot]),.calibration(pcfg[selected_slot]),.manual_matrix(pose_matrix[selected_slot])',
                         '.affine_enable(source_enable[model_slot]),.calibration(pcfg[model_slot]),.manual_matrix(pose_matrix[model_slot])')
    return text


def main():
    """Leave both the active PnR snapshot and working RTL untouched for review."""
    fpga = Path(__file__).resolve().parents[1]
    base = fpga/'build/area60_20261025/combined_20261025_160537_700472'
    manifest = json.loads((base/'sources.json').read_text())
    assert all(sha(base/'source'/n) == h for n, h in manifest.items())
    names = ['rtl/control/pc_reference_upload.sv', 'rtl/control/pc_video_boot.sv',
             'rtl/geometry/tone_entity_control.sv', 'rtl/board/video_memory_core.sv',
             'rtl/board/pango_video_system.sv', 'rtl/stabilization/motion_config_bank.sv',
             'rtl/stabilization/source_motion_controller.sv']
    # Never overwrite concurrent user edits when this experiment is promoted.
    working = {n: sha(fpga/n) for n in names}
    assert all(working[n] == manifest[n] for n in names)
    run = fpga/'build/control_pipeline_20261025'/datetime.now().strftime('candidate_%Y%m%d_%H%M%S_%f')
    run.mkdir(parents=True)
    shutil.copytree(base/'source', run/'source')
    for name in names:
        p = run/'source'/name
        old = p.read_text(encoding='utf-8'); new = transform(name, old)
        p.write_text(new, encoding='utf-8')
        patch = run/'patches'/(name+'.patch'); patch.parent.mkdir(parents=True, exist_ok=True)
        patch.write_text(''.join(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
                          fromfile='a/fpga/'+name, tofile='b/fpga/'+name)), encoding='utf-8')
    (run/'sources.json').write_text(json.dumps({n: sha(run/'source'/n) for n in manifest}, indent=2))
    (run/'candidate.json').write_text(json.dumps(dict(baseline=str(base), changed_files=names,
        working_before=working, production_selected=False, routed=False, hardware_tested=False), indent=2))
    shutil.copyfile(__file__, run/'preparation_script.py')
    print(run, flush=True)


if __name__ == '__main__':
    main()
