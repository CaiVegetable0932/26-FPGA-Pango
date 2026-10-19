"""Sweep DMA client-count/verification parameters with an independent memory.

Reuse the already cycle-checked dual wrapper so generic branches also compare
original and candidate public interfaces under the exact same controller.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def sha(path):
    """Bind test inputs to byte identities, including the comparison wrapper."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """Keep every compile/runtime result, including the first failed branch."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--proof', type=Path, required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    proof = args.proof.resolve()
    if not proof.is_relative_to(fpga/'build'):
        raise ValueError('Frozen FPGA DMA cycle proof required')
    checked = json.loads((proof/'result.json').read_text(encoding='utf-8'))
    if not all(checked.get(k) for k in ('passed','cycle_equivalent','inputs_intact')):
        raise ValueError('Passing baseline/candidate transport proof required')
    if any(sha(Path(p)) != digest for p,digest in checked['inputs'].items()):
        raise ValueError('Cycle proof inputs changed')
    wrapper = proof/'ddr_native_dma.v'
    bench = fpga/'sim/tb_dma_grouped_parameters.sv'
    run = proof.parent/datetime.now().strftime('generic_parameters_%Y%m%d_%H%M%S_%f')
    run.mkdir()
    shutil.copyfile(bench,run/bench.name)
    shutil.copyfile(wrapper,run/wrapper.name)
    shutil.copyfile(__file__,run/'verification_script.py')
    inputs = {str(p):sha(p) for p in (bench,wrapper)}
    tool = fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result = dict(passed=False,cycle_equivalent=False,wrapper_proof=str(proof),inputs=inputs,tests=[])
    try:
        # Single/paired/odd/non-power-of-two groups exercise the generate
        # boundaries; verify=0 and 1 retain transport and full readback modes.
        for clients in (1,2,3,5,7,8):
            for verify in (0,1):
                label=str(clients)+'_'+str(verify)
                image=run/(label+'.vvp')
                command=[str(tool/'iverilog.exe'),'-g2012','-s','tb_dma_grouped_parameters',
                         '-Ptb_dma_grouped_parameters.N='+str(clients),
                         '-Ptb_dma_grouped_parameters.VERIFY='+str(verify),'-o',str(image),
                         str(run/bench.name),str(run/wrapper.name)]
                case=dict(clients=clients,verify=verify,passed=False)
                result['tests'].append(case)
                for phase,cmd in [('compile',command),('run',[str(tool/'vvp.exe'),str(image)])]:
                    proc=subprocess.run(cmd,cwd=run,capture_output=True,timeout=30)
                    output=proc.stdout+proc.stderr
                    (run/(label+'.'+phase+'.log')).write_bytes(output)
                    if proc.returncode or (phase=='run' and b'DMA_GENERIC_PARAMETERS_PASS' not in output):
                        raise RuntimeError(label+' '+phase+': '+output.decode(errors='replace')[-3000:])
                case['passed']=True
                print(label,'PASS',flush=True)
        result.update(passed=True,cycle_equivalent=True)
    finally:
        result['inputs_intact']=all(sha(Path(p))==digest for p,digest in inputs.items())
        result['passed']=result['passed'] and result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2)+'\n')
        print('RUN',run,flush=True)
    if not result['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
