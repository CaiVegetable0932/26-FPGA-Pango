"""Verify stable-body pipelining with UART transactions and baseline comparison."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
from regional_scan_wrapper import ports


def sha(p):
    """Keep results tied to original and generated test inputs."""
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    """Exercise both default compatibility and the enabled board specialization."""
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--candidate', required=True, type=Path)
    ap.add_argument('--only', nargs='+', help='Focused fixture repair; a partial proof cannot authorize adoption')
    a = ap.parse_args(); candidate = a.candidate.resolve()
    fpga = Path(__file__).resolve().parents[1]
    manifest = json.loads((candidate/'sources.json').read_text())
    assert all(sha(candidate/'source'/n) == h for n, h in manifest.items())
    base = Path(json.loads((candidate/'candidate.json').read_text())['baseline'])
    run = candidate/datetime.now().strftime('proof_%Y%m%d_%H%M%S_%f')
    source = run/'source'; source.mkdir(parents=True)
    origins = {}
    for group in ['control', 'geometry', 'memory', 'isp', 'input', 'stabilization']:
        for p in (candidate/'source/rtl'/group).iterdir():
            if p.suffix in ('.sv', '.v', '.vh'):
                assert not (source/p.name).exists()
                shutil.copyfile(p, source/p.name); origins[str(p)] = sha(p)
    original = base/'source/rtl/geometry/tone_entity_control.sv'
    origins[str(original)] = sha(original)
    (source/'tone_baseline.sv').write_text(original.read_text().replace('module tone_entity_control ', 'module tone_baseline ', 1))
    cases = ['tb_pc_reference_upload', 'tb_pc_video_boot', 'tb_pc_tone_gateway',
             'tb_image_entities', 'tb_isp_colour_entity', 'tb_image_manual_profile',
             'tb_pc_camera_validation', 'tb_pc_mcu_link', 'tb_pc_snapshot_ownership']
    fixtures = [n for n in cases if n != 'tb_isp_colour_entity']
    for top in fixtures:
        p = fpga/'sim'/(top+'.sv'); origins[str(p)] = sha(p)
        shutil.copyfile(p, source/p.name)
    # Compare the actual manual tone controller with its old implementation.
    # The independent fixture checks all built-in LUT bytes/publication and
    # unsupported requests. Its body is held through a full clock before submit.
    manual = (source/'tb_image_manual_profile.sv').read_text()
    manual = manual.replace('module tb_image_manual_profile;', 'module tb_tone_pipeline;')
    manual = manual.replace('.SUPPORT_UPLOAD(0)) tone', '.SUPPORT_UPLOAD(0),.REGISTER_BODY_CHECK(1)) tone')
    manual = manual.replace('begin @(negedge clk);#1;if(tcode', 'begin repeat(2)@(negedge clk);#1;if(tcode')
    declarations = ports(original.read_text(), 'tone_entity_control', {})
    peer = '\n// Baseline checks all public state at identical acceptance edges.\n'
    peer += 'tone_baseline #(.SUPPORT_AUTO(0),.SUPPORT_UPLOAD(0)) reference_tone(' + ','.join('.'+n+'(tone.'+n+')' for d,n,w in declarations if d=='input') + ');\n'
    peer += 'integer comparisons=0;always @(negedge clk)begin #2;if(rst_n)begin comparisons++;\n'
    for d,n,w in declarations:
        if d == 'output':
            # The code is allowed to settle during preparation; every real
            # submit edge must agree, while public state always agrees.
            guard = 'tsubmit && ' if n == 'submit_code' else ''
            peer += 'if('+guard+'tone.'+n+' !== reference_tone.'+n+')$fatal(1,"TONE_PIPELINE_DIFF '+n+'");\n'
    peer += 'end end\nfinal $display("TONE_PIPELINE_COMPARED %0d",comparisons);\n'
    manual = manual.replace('endmodule', peer+'endmodule')
    (source/'tb_tone_pipeline.sv').write_text(manual); cases.append('tb_tone_pipeline')
    # Exercise the enabled gateway, including a valid manual kind1 commit,
    # malformed static body, pending BUSY and idempotent COMMIT retry.
    uart = (source/'tb_pc_tone_gateway.sv').read_text()
    uart = uart.replace('module tb_pc_tone_gateway;', 'module tb_tone_pipeline_uart;')
    uart = uart.replace('.ENTITY_MASK(16\'h0006)', '.ENTITY_MASK(16\'h0006),.COMMIT_SETTLE(1)')
    uart = uart.replace('.LUT_PREVALIDATED(1)', '.LUT_PREVALIDATED(1),.REGISTER_BODY_CHECK(1)')
    uart = uart.replace('wire tx,configured,submit;', 'wire tx,configured,submit,raw_attempt;\n wire local_accept=raw_attempt && code==0;')
    uart = uart.replace('.entity_submit_valid(submit),', '.entity_submit_valid(submit),.entity_submit_attempt(raw_attempt),')
    uart = uart.replace('.submit_valid(submit),', '.submit_valid(local_accept),')
    uart = uart.replace('if(submit)begin', 'if(local_accept)begin')
    uart = uart.replace('if(kind!=2 || body[512+:8]!=64)', 'if((kind!=1 && kind!=2) || (kind==2 && body[512+:8]!=64))')
    insertion = '''
  // kind1 goes through the registered static validator, unlike a LUT upload.
  lut=0;lut[7:0]=1;lut[23:16]=7;lut[39:32]=96;lut[47:40]=144;lut[63:48]=1;
  for(block=0;block<3;block=block+1)begin
   if(block==0)lut[39:32]=144;else lut[39:32]=96;
   crc=32'hffffffff;for(i=0;i<32;i=i+1)crc=crc32_byte(crc,lut[i*8+:8]);crc=~crc;
   payload=0;payload[191:0]={crc,16'd0,16'd32,32'd7,32'(3+block),32'(27+block),16'd1,16'd1};
   target++;request(8'ha1,24,payload,target);
   if(response[(target-1)*42+8]!=0)$fatal(1,"kind1 BEGIN");
   payload=0;payload[31:0]=27+block;payload[55:48]=32;payload[64+:256]=lut[255:0];
   target++;request(8'ha2,40,payload,target);
   if(response[(target-1)*42+8]!=0)$fatal(1,"kind1 CHUNK");
   payload=0;payload[95:0]={32'd0,crc,32'(27+block)};
   target++;request(8'ha3,12,payload,target);
   if(response[(target-1)*42+8]!=(block==0?11:block==1?0:4) || submissions!=(block==0?1:2))
    $fatal(1,"kind1 static/BUSY/acceptance mismatch");
   target++;request(8'ha3,12,payload,target);
   if(response[(target-1)*42+8]!=(block==0?11:block==1?0:4) || submissions!=(block==0?1:2))
    $fatal(1,"kind1 COMMIT retry duplicated or changed result");
   if(block!=1)begin
    payload=0;payload[63:0]={32'(27+block),16'd0,16'd1};target++;request(8'ha5,8,payload,target);
   end
  end
'''
    uart = uart.replace('response[0:999]', 'response[0:2999]')
    uart = uart.replace('$display("PC_TONE_GATEWAY_PASS', insertion+'\n  $display("PC_TONE_GATEWAY_PASS')
    uart = uart.replace('endmodule', '''// Check the actual producer contract, not just the consumer test setup.
 reg [2047:0] previous_body;reg [79:0] previous_identity;
 always @(posedge clk)begin
  if(rst && local_accept!==submit)$fatal(1,"local tone acceptance changed UART semantics");
  if(rst && boot_control.upload_submit)begin
   if(body!==previous_body || {kind,version,id}!==previous_identity)
    $fatal(1,"registered validator received an unstable upload");
  end
  previous_body<=body;previous_identity<={kind,version,id};
 end
endmodule''')
    (source/'tb_tone_pipeline_uart.sv').write_text(uart); cases.append('tb_tone_pipeline_uart')
    # Registered motion schema checking retains live versions and pending.
    # Reuse the independent all-field randomized bank comparison, preparing
    # kind/body with submit deasserted before each acceptance edge.
    p=base/'source/rtl/stabilization/motion_config_bank.sv'; origins[str(p)]=sha(p)
    (source/'motion_config_bank_baseline.sv').write_text(p.read_text().replace('module motion_config_bank ', 'module motion_config_bank_baseline ',1))
    p=fpga/'sim/tb_motion_config_distribution.sv'; origins[str(p)]=sha(p)
    motion=p.read_text().replace('parameter SUPPORT_VIEWPORT=1','parameter SUPPORT_VIEWPORT=0')
    motion=motion.replace('.SUPPORT_VIEWPORT(SUPPORT_VIEWPORT)) dut','.SUPPORT_VIEWPORT(SUPPORT_VIEWPORT),.REGISTER_BODY_CHECK(1)) dut')
    motion=motion.replace('integer seed=42','reg requested_submit;\n integer seed=42')
    motion=motion.replace('submit_valid=($random(seed)&3)!=0;', 'submit_valid=0;requested_submit=($random(seed)&3)!=0;')
    motion=motion.replace('   #1;compare();','   repeat(2)@(negedge clk);submit_valid=requested_submit;\n   #1;compare();')
    # Registered legality deliberately resets false. Its combinational code
    # need not match the old unregistered code while reset forbids acceptance.
    motion=motion.replace('#1;compare();','#1;if(rst_n)compare();')
    # Publication can occur during the stable-body preparation interval; count
    # actual clock-edge handshakes rather than sampling only after that wait.
    motion=motion.replace('   if(rst_n && capture_boundary && dut.pending)publishes++;','')
    motion=motion.replace(' initial begin\n', ' always @(posedge clk)if(rst_n && capture_boundary && dut.pending)publishes++;\n initial begin\n',1)
    motion=motion.replace('"insufficient commit coverage"','"insufficient commit coverage accepts=%0d publishes=%0d",accepts,publishes')
    (source/p.name).write_text(motion);cases.append('tb_motion_config_distribution')
    # Exercise the real source-owned slot lookup with accepted calibration,
    # exact pose arithmetic, stale-slot reuse and a reset while lookup waits.
    p=fpga/'sim/tb_viewport_disabled_profile.sv';origins[str(p)]=sha(p)
    motion=p.read_text().replace('.SUPPORT_VIEWPORT(0)) dut', '.SUPPORT_VIEWPORT(0),.REGISTER_CONFIG_CHECK(1),.REGISTER_POSE_MATCH(1)) dut')
    motion=motion.replace('  #1;check(submit_code==0,"C3', '  repeat(2)@(negedge clk);#1;check(submit_code==0,"C3')
    extra='''
  // Freeze model readiness, then reuse the matched slot before acceptance.
  admit(0,6,1,1);
  @(negedge clk);selected_frame=6;
  force dut.selected_epoch=64'd7;force dut.selected_frame=selected_frame;
  force dut.selected_pose=selected_pose;force dut.selected_status=3'd0;
  force dut.selected_error=32'd100;force dut.selected_valid=1'b1;
  force dut.model_ready=1'b0;
  wait(dut.match_pipeline.pending);
  admit(0,7,1,1);#1;
  check(!dut.model_request,"stale matched slot borrowed replacement calibration");
  release dut.model_ready;wait(dut.selected_ready);@(posedge clk);@(negedge clk);
  release dut.selected_valid;release dut.selected_epoch;release dut.selected_frame;
  release dut.selected_pose;release dut.selected_status;release dut.selected_error;
  repeat(30)@(negedge clk);
  check(!dut.pose_ready[0],"stale lookup marked replacement pose ready");
  // A warm reset revokes pending lookup ownership before any stale publish.
  selected_frame=7;force dut.selected_epoch=64'd7;force dut.selected_frame=selected_frame;
  force dut.selected_valid=1'b1;force dut.model_ready=1'b0;
  wait(dut.match_pipeline.pending);@(negedge clk);rst_n=0;
  repeat(2)@(negedge clk);check(!dut.match_pipeline.pending && dut.source_valid==0,"lookup reset fence");
  release dut.model_ready;release dut.selected_valid;release dut.selected_epoch;release dut.selected_frame;
  rst_n=1;repeat(4)@(negedge clk);check(!dut.pose_valid,"stale pose escaped reset");
'''
    motion=motion.replace('  $display("VIEWPORT_DISABLED_PROFILE_PASS',extra+'\n  $display("VIEWPORT_DISABLED_PROFILE_PASS')
    (source/p.name).write_text(motion);cases.append('tb_viewport_disabled_profile')
    # Repeat camera wait/retry, MCU acceptance and reset-fenced snapshot cases
    # through the enabled settling stage as well as the tone-specific proof.
    for top in ['tb_pc_camera_validation', 'tb_pc_mcu_link', 'tb_pc_snapshot_ownership']:
        p = source/(top+'.sv'); t=p.read_text()
        t = re.sub(r'pc_video_boot\s*#\(', 'pc_video_boot #(.COMMIT_SETTLE(1),', t)
        # Keep the old accepted-only output as a cycle-by-cycle oracle, but
        # drive the actual backend from raw attempt plus its local code.
        t = t.replace('module '+top+';', 'module '+top+';\n wire raw_attempt;')
        t = t.replace('.entity_submit_valid(valid),', '.entity_submit_valid(valid),.entity_submit_attempt(raw_attempt),')
        if top in ['tb_pc_mcu_link','tb_pc_snapshot_ownership']:
            assert '.submit_valid(valid && kind==12)' in t
            t = t.replace('.submit_valid(valid && kind==12)', '.submit_valid(raw_attempt && kind==12 && code==0)')
            t = t.replace('endmodule', '''// Check acceptance, including invalid policy and idempotent retry.
 always @(posedge clk)if(rst_n && (raw_attempt && code==0)!==valid)
  $fatal(1,"local MCU acceptance changed UART semantics");
endmodule''')
        else:
            t = t.replace('.entity_submit_valid(entity_submit),', '.entity_submit_valid(entity_submit),.entity_submit_attempt(raw_attempt),')
            assert '.submit_valid(entity_submit&&kind==7)' in t
            t = t.replace('.submit_valid(entity_submit&&kind==7)', '.submit_valid(raw_attempt && kind==7 && backend_code==0)')
            t = t.replace('endmodule', '''// The forced wait token is part of this fixture's selected backend code.
 always @(posedge clk)if(rst_n && (raw_attempt && backend_code==0)!==entity_submit)
  $fatal(1,"local camera acceptance changed UART semantics");
endmodule''')
        p.write_text(t)
    for p in (fpga/'sim/vectors/network_control').glob('*.hex'):
        shutil.copyfile(p, run/p.name); origins[str(p)] = sha(p)
    shutil.copyfile(__file__, run/'verification_script.py')
    frozen = {p.relative_to(run).as_posix():sha(p) for p in run.rglob('*') if p.is_file()}
    binary = fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    sources = sorted([p for p in source.iterdir() if p.suffix in ('.v','.sv')], key=lambda p:0 if p.name=='frame_manager_pkg.sv' else 1)
    result = dict(passed=False, cases=[], origins=origins, frozen=frozen, hardware_tested=False)
    result['complete_suite']=a.only is None
    if a.only:
        assert set(a.only).issubset(cases)
        cases=[top for top in cases if top in a.only]
    print('CONTROL_PIPELINE_PROOF', run, flush=True)
    try:
        for top in cases:
            commands = [[str(binary/'iverilog.exe'), '-g2012', '-I', str(source), '-s', top, '-o', str(run/(top+'.vvp'))]+list(map(str,sources)),
                        [str(binary/'vvp.exe'), str(run/(top+'.vvp'))]]
            entry = dict(test=top, passed=False, commands=commands); result['cases'].append(entry)
            for phase, cmd in zip(['compile','run'], commands):
                p = subprocess.run(cmd, cwd=run, input=b'', capture_output=True, timeout=180)
                out = p.stdout+p.stderr; (run/(top+'.'+phase+'.log')).write_bytes(out)
                if p.returncode: raise RuntimeError(out.decode(errors='replace')[-2000:])
            if b'PASS' not in out or b'FATAL' in out: raise RuntimeError('Incomplete oracle')
            entry.update(passed=True, summary=out.decode(errors='replace'))
            print(top, entry['summary'][-500:], flush=True)
        result['passed'] = True
    finally:
        result['inputs_intact'] = all(sha(Path(n))==h for n,h in origins.items()) and all(sha(run/n)==h for n,h in frozen.items())
        result['passed'] &= result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2))
    if not result['passed']: raise SystemExit(1)


if __name__ == '__main__':
    main()
