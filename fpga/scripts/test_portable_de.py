"""Exercise migration and the real check-only gate without starting PDS.

The installed-help invocation and process inventory are simulated explicitly;
all payload hashes, relocation checks and resume preflight run normally.
"""
from pathlib import Path
from unittest.mock import patch
import json, shutil, subprocess, sys, hashlib
import portable_de as p


def main():
    """Keep test configuration isolated from release and live route scopes."""
    review=p.audit()
    original_fpga=p.FPGA
    test=original_fpga/'build/portable_de_validation/fpga'
    if test.exists():raise ValueError('Validation output already exists')
    (test/'scripts').mkdir(parents=True)
    for src in (original_fpga/'scripts').glob('*.py'):
        shutil.copyfile(src,test/'scripts'/src.name)
    help_bytes=(p.RELEASE/'evidence/original_installed_pnr_help.log').read_bytes()
    real_run=subprocess.run
    help_calls=[]
    def isolated_run(command,**kwargs):
        # Never invoke a real PDS executable in this migration-only test.
        if Path(str(command[0])).name.lower()=='pds_shell.exe':
            assert '-file' in command and str(command[command.index('-file')+1]).endswith('installed_help.tcl')
            help_calls.append(command)
            return subprocess.CompletedProcess(command,0,stdout=help_bytes,stderr=b'')
        assert '--check-only' in command, command
        return real_run(command,**kwargs)
    with patch.object(p,'FPGA',test),patch.object(p,'DISPATCH',test/'build/portable_de/dispatch.json'),patch.object(p,'audit',return_value=review),patch.object(p,'pds_processes',return_value=[]),patch.object(p.subprocess,'run',side_effect=isolated_run):
        p.prepare(Path('E:/PDS_Pangu/PDS_2022.2-SP6.4'))
        dispatch=json.loads(p.DISPATCH.read_text(encoding='utf-8'))
    command=dispatch['command']
    assert command[command.index('--pnr-timeout-minutes')+1]=='0'
    assert command[command.index('--phase-timeout-minutes')+1]=='0'
    assert all(x in command for x in ['--monitor-only','--stop-after-timing','--from-placement'])
    run=Path(dispatch['build'])
    log=(run/'preflight.log').read_text(encoding='utf-8')
    assert '"preflight_passed": true' in log and '"native_launched": false' in log
    for name in ['device_map/pango_video_system_map.adf','place_route/pango_video_system_plc.adf','synthesize/pango_video_system_syn.adf']:
        assert p.sha(run/name)==p.sha(p.INPUTS/name)
    # Reject an inconsistent timeout instead of silently returning to bounded mode.
    bad=command.copy();bad[bad.index('--pnr-timeout-minutes')+1]='90'
    rejected=real_run(bad+['--check-only'],capture_output=True)
    assert rejected.returncode!=0
    (run/'negative_preflight.log').write_bytes(rejected.stdout+rejected.stderr)
    for src in (original_fpga/'scripts').glob('*.py'):
        compile(src.read_text(encoding='utf-8'),str(src),'exec')
    result=dict(passed=True,source_count=review['source_count'],mapped_lut=review['mapped_lut'],plc_sha256=review['plc_sha256'],relocation_passed=True,real_check_only_passed=True,inconsistent_timeout_rejected=True,native_launched=False,installed_help_simulated=True,remote_machine_tested=False,unlimited_native_and_host=True,monitor_only=True,stop_after_timing=True,proof_build=str(run))
    p.save(p.RELEASE/'evidence/portable_validation.json',result)
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
