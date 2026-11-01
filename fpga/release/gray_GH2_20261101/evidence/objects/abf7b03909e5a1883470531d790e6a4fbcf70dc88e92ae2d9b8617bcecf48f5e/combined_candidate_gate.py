"""Verify BE frozen evidence and serialize behind the existing native queue."""
from pathlib import Path
import hashlib
import json
import subprocess
import time


def read(path):
    """Tolerate a bounded transient publication window, never cache success."""
    for attempt in range(6):
        try:
            return json.loads(path.read_text(encoding='utf-8'))
        except (json.JSONDecodeError, PermissionError):
            if attempt == 5:
                raise
            time.sleep(.2)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def functional_review(fpga):
    """Bind combined video and existing numerical/UART proofs to actual RTL."""
    root=fpga/'build/reader_full_chunks_20261031/BE_working_candidate'
    state=read(root/'state.json');manifest=read(root/'sources.json')
    if len(manifest)!=327 or not all(sha(root/'source'/n)==h for n,h in manifest.items()):
        raise RuntimeError('BE source manifest drift')
    video=Path(state['full_video_build']);vr=read(video/'result.json');vm=read(video/'sources.json')
    if not all(vr.get(k) for k in ('passed','snapshot_intact','full_frame','display_test','fixed_gray','projective','stop_to_update')):
        raise RuntimeError('BE video profile incomplete')
    if sha(video/'result.json')!=state['full_video_result_sha256']:
        raise RuntimeError('BE video result drift')
    if len(vm)!=94 or not all(sha(video/'source'/n)==h for n,h in vm.items()):
        raise RuntimeError('BE video source drift')
    if not all(manifest[n]==h for n,h in vm.items() if n.startswith('rtl/')):
        raise RuntimeError('BE video RTL mismatch')
    b=Path(state['base_B']);bm=read(b/'sources.json');bs=read(b/'state.json')
    for n in ('rtl/control/raw_pose_solver.sv','rtl/control/pc_raw_pose_control.sv'):
        if manifest[n]!=bm[n] or sha(b/'source'/n)!=bm[n]:
            raise RuntimeError('BE solver no longer matches proved B')
    proofs=[]
    for item in bs['proofs']:
        proof=Path(item['directory']);pr=read(proof/'result.json');pm=read(proof/'sources.json')
        if sha(proof/'result.json')!=item['result_sha256'] or not pr.get('passed'):
            raise RuntimeError('B solver proof failed or changed')
        for n,h in pm.items():
            local=n.removeprefix('fpga/')
            candidates=[proof/'source'/n,proof/'source'/local]
            stored=next((p for p in candidates if p.is_file()),None)
            if stored is None or sha(stored)!=h:
                raise RuntimeError('B proof source drift: '+n)
            if local.startswith('rtl/') and manifest[local]!=h:
                raise RuntimeError('B proof RTL does not match BE: '+n)
        proofs.append({'directory':str(proof),'result_sha256':item['result_sha256']})
    return {'passed':True,'combined_source_count':len(manifest),'video_source_count':len(vm),
        'manifest_sha256':sha(root/'sources.json'),'video_result_sha256':sha(video/'result.json'),
        'solver_elaborated_in_video':False,'separate_solver_proofs':proofs}


def wait_and_verify(fpga,out,publish,stop,timeout=10800):
    """Wait at most three hours, then check exact predecessor and native ownership."""
    queue=fpga/'build/gray_candidates_native_20261031/run_1510/state.json'
    obsolete=fpga/'build/gray_candidates_native_20261031/E_after_queue_v2/state.json'
    initial=functional_review(fpga)
    (out/'functional_precheck.json').write_text(json.dumps(initial,indent=2))
    deadline=time.monotonic()+timeout
    while True:
        if stop.exists():raise RuntimeError('Stop requested while waiting')
        q=read(queue);e=read(obsolete)
        if q['status'] in ('FAILED','STOPPED'):
            raise RuntimeError('Predecessor native queue failed')
        if e.get('candidates') or e.get('active_wrapper_pid'):
            raise RuntimeError('Isolated E unexpectedly started; do not overlap')
        e_closed=e['status']=='FAILED' and e.get('error')=='Stop requested while waiting'
        if q['status']=='ALL_MAP_COMPLETE_REVIEW_REQUIRED' and e_closed:break
        if time.monotonic()>=deadline:raise TimeoutError('Prerequisite wait exceeded 10800s')
        publish('WAITING_FOR_BCD_AND_E_WAITER_EXIT');time.sleep(30)
    from review_gray_candidates import inspect
    for label in ('B','C','D'):
        item=q['candidates'][label]
        if item.get('status')!='MAP_COMPLETE_REVIEW_REQUIRED':
            raise RuntimeError('Predecessor incomplete: '+label)
        inspect(Path(item['synthesis']),Path(item['mapping']))
    evidence=functional_review(fpga)
    if (fpga/'build/route_optimization/native_phase.lock').exists():
        raise RuntimeError('Native lock remains')
    query=subprocess.run(['powershell','-NoProfile','-Command',
        "$ErrorActionPreference='Stop'; @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.Name -eq 'pds_shell.exe' } | Select-Object ProcessId,CreationDate,CommandLine) | ConvertTo-Json -Compress"],
        capture_output=True,text=True,timeout=45)
    if query.returncode or query.stdout.strip() not in ('','[]'):
        raise RuntimeError('Native process exists or inventory unavailable')
    evidence.update(predecessor_sha256=sha(queue),isolated_E_native_skipped=True,
                    comparison='B versus BE isolates reader E',native_inventory=query.stdout)
    (out/'prerequisite_review.json').write_text(json.dumps(evidence,indent=2))
