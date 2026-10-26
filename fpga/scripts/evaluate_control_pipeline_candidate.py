"""Run isolated full-frame proof or serialized SYN/MAP for a control candidate."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


def sha(p):
    """Detect source drift before and after the expensive evaluation."""
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    """Never claim physical improvement from SYN or alter an existing route."""
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--candidate', required=True, type=Path)
    ap.add_argument('--phase', required=True, choices=['full', 'native'])
    ap.add_argument('--proof', type=Path)
    ap.add_argument('--wait-for-result', type=Path)
    a = ap.parse_args(); candidate = a.candidate.resolve()
    fpga = Path(__file__).resolve().parents[1]
    hashes = json.loads((candidate/'sources.json').read_text())
    intact = lambda:all(sha(candidate/'source'/n)==h for n,h in hashes.items())
    assert intact()
    run = candidate/datetime.now().strftime(a.phase+'_%Y%m%d_%H%M%S_%f'); run.mkdir()
    shutil.copyfile(__file__, run/'evaluation_script.py')
    result = dict(passed=False, phase=a.phase, candidate=str(candidate), steps=[], routed=False, hardware_tested=False)
    print('CONTROL_EVALUATION', run, flush=True)

    def execute(label, args, marker):
        """Preserve full raw output, publishing only the resulting evidence path."""
        cmd = [sys.executable, str(fpga/'scripts'/args[0])]+args[1:]
        print('BEGIN', label, flush=True)
        with (run/(label+'.log')).open('wb') as log:
            p = subprocess.run(cmd, cwd=fpga.parent, input=b'', stdout=log, stderr=subprocess.STDOUT)
        output = (run/(label+'.log')).read_text(errors='replace')
        found = re.search(r'^'+marker+r' (.+)$', output, re.M)
        entry = dict(label=label, command=cmd, exit_code=p.returncode, path=found[1].strip() if found else None)
        result['steps'].append(entry)
        if not found: raise RuntimeError(output[-2000:])
        folder = Path(entry['path']); evidence = json.loads((folder/'result.json').read_text())
        entry['result_sha256'] = sha(folder/'result.json')
        print(label, folder, 'exit', p.returncode, flush=True)
        return folder, evidence, p.returncode

    try:
        if a.phase == 'full':
            # Production uses the registered check. The video fixture has no
            # UART uploads; enabled-path UART semantics have separate proofs.
            fixture = run/'fixture'; (fixture/'sim').mkdir(parents=True)
            for name in ['tb_video_memory_core.sv', 'video_core_display_fixture.sv']:
                src = fpga/'sim'/name; shutil.copyfile(src, fixture/'sim'/name)
            p = fixture/'sim/tb_video_memory_core.sv'; text = p.read_text()
            token = '.CCM_PREVALIDATED(BOARD_MANUAL_PROFILE),'
            assert text.count(token)==1
            text = '// Match production local acceptance, registered schema checks and pose lookup.\n'+text.replace(token,token+'.TONE_REGISTER_BODY_CHECK(BOARD_MANUAL_PROFILE),.MOTION_REGISTER_BODY_CHECK(BOARD_MANUAL_PROFILE),.POSE_MATCH_PIPELINE(BOARD_MANUAL_PROFILE),.QUALIFY_IMAGE_LOCALLY(BOARD_MANUAL_PROFILE),')
            p.write_text(text)
            (run/'fixture_sources.json').write_text(json.dumps({str(p.relative_to(fixture)):sha(p) for p in fixture.rglob('*') if p.is_file()},indent=2))
            folder, evidence, code = execute('full_frame', ['sim_video_verilator.py', '--rtl-snapshot', str(candidate/'source'),
                '--fixture-snapshot', str(fixture), '--full-frame', '--control-test', '--display-test', '--board-manual-profile',
                '--build-jobs', '2', '--pause-file', str(run/'pause.json')], 'VERILATOR_START')
            assert code==0 and evidence['passed'] and evidence['snapshot_intact']
        else:
            if not a.proof: raise ValueError('Successful source-bound protocol proof required')
            proof = json.loads((a.proof/'result.json').read_text())
            assert proof['passed'] and proof['inputs_intact'] and proof.get('complete_suite')
            assert all(sha(Path(n))==h for n,h in proof['origins'].items())
            assert all(sha(a.proof/n)==h for n,h in proof['frozen'].items())
            result['proof'] = str(a.proof); result['proof_sha256'] = sha(a.proof/'result.json')
            # Wait for the pre-existing owner to finish its entire scope.
            # This queue never deletes a lock or changes live authorization.
            lock = fpga/'build/route_optimization/native_phase.lock'
            deadline = time.monotonic()+1200
            while lock.exists() or (a.wait_for_result and not a.wait_for_result.exists()):
                if (run/'pause.json').exists(): raise RuntimeError('Evaluation paused before native launch')
                if time.monotonic()>deadline: raise TimeoutError('Existing native owner still active')
                time.sleep(2)
            assert intact()
            folder, evidence, code = execute('synthesis_map', ['build_video_system.py', '--rtl-snapshot', str(candidate/'source'),
                '--stage', 'dev_map', '--resource-sharing', 'true', '--overall-timeout-minutes', '60',
                '--pause-file', str(run/'pause.json')], 'BOARD_START')
            # Installed project flow omits the post-SYN SCF overlay. Accept
            # only that known report-gate failure, then explicitly remap it.
            assert evidence['native_exit']==0 and not evidence['errors'] and evidence['snapshot_intact']
            if code:
                assert code==1 and 'missing 10/10 reset SCF exceptions' in (evidence.get('native_constraint_gate_error') or '')
            mapped, mapped_result, code = execute('explicit_scf_map', ['map_postsyn_candidate.py','--build',str(folder)], 'POSTSYN_CANDIDATE')
            assert code==0 and mapped_result['native_exit']==0 and not mapped_result['errors']
            assert json.loads((mapped/'sources.json').read_text())==hashes
            result['mapping'] = str(mapped)
        result['passed'] = True
    finally:
        result['inputs_intact'] = intact(); result['passed'] &= result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2))
    print('EVALUATION_RESULT', json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
