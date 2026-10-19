"""Compile the same RTL video testbench with local Verilator/CMake/Ninja."""
from datetime import datetime
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
from proof_supervisor import run_proof


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl-snapshot', type=Path, help='Read immutable source directory from a board build')
    parser.add_argument('--fixture-snapshot', type=Path,
                        help='Explicit frozen experimental sim/ fixture directory; hashes remain recorded')
    parser.add_argument('--run-timeout-seconds',type=int,help='Explicit prelaunch software simulation allowance, at most 3600 seconds')
    parser.add_argument('--pause-file',type=Path,help='Owned proof stop file; defaults to the regional/account reserve')
    parser.add_argument('--full-frame', action='store_true')
    parser.add_argument('--control-test', action='store_true')
    parser.add_argument('--snapshot-test', action='store_true')
    parser.add_argument('--network-test', action='store_true')
    parser.add_argument('--display-test', action='store_true',help='Attach real HDMI display/context/DMA CDC to the 1080p memory core')
    parser.add_argument('--build-jobs', type=int, default=4,
                        help='C++ build concurrency; does not change RTL or simulation stimulus')
    options = parser.parse_args()
    if not 1 <= options.build_jobs <= 8:
        parser.error('build jobs must be 1..8')
    if options.run_timeout_seconds is not None and not 0<options.run_timeout_seconds<=3600:
        parser.error('software run allowance must be 1..3600 seconds')
    # Link-loss and control fixtures use independent frame identities and
    # display-release schedules; snapshots can accompany either scenario.
    if options.network_test and options.control_test:
        parser.error('run link-loss and parameter-control scenarios separately')
    if options.display_test and (not options.full_frame or options.network_test):
        parser.error('display test requires full-frame; use the control/snapshot scenario, not link-loss stimulus')
    fpga = Path(__file__).resolve().parents[1]
    pause=options.pause_file or fpga/'build/route_optimization/session_20261019/regional_stop_requested.json'
    if pause.exists():raise RuntimeError('Proof launch prevented by regional/account reserve stop')
    run = fpga / 'build/full_integration_20261013' / datetime.now().strftime('verilator_%Y%m%d_%H%M%S_%f')
    source = run / 'source'
    source.mkdir(parents=True)
    # Same SV testbench, source ownership and native byte model as Icarus;
    # this changes simulation implementation, not the design or golden bytes.
    names = ['rtl/memory/frame_manager_pkg.sv']
    rtl_origin = options.rtl_snapshot.resolve() if options.rtl_snapshot else fpga
    for group in ['memory', 'input', 'isp', 'geometry', 'network', 'control', 'video']:
        for path in sorted((rtl_origin / 'rtl' / group).glob('*')):
            if path.suffix in ('.sv', '.v', '.vh') and path.name not in ('frame_manager_pkg.sv', 'ip_integration_bank.v'):
                names.append(path.relative_to(rtl_origin).as_posix())
    names += ['rtl/board/video_memory_core.sv', 'sim/tb_video_memory_core.sv', 'sim/video_core_display_fixture.sv']
    for name in names:
        dest = source / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        # RTL bytes come from the exact native build; stimulus remains the
        # independent live SV fixture with its own recorded source hash.
        fixture_origin = options.fixture_snapshot.resolve() if options.fixture_snapshot else fpga
        origin = (rtl_origin / name) if name.startswith('rtl/') else (fixture_origin / name)
        shutil.copyfile(origin, dest)
    hashes = {n: hashlib.sha256((source / n).read_bytes()).hexdigest() for n in names}
    (run / 'sources.json').write_text(json.dumps(hashes, indent=2), encoding='utf-8')
    shutil.copyfile(Path(__file__), run / 'simulation_script.py')
    for helper in ['proof_supervisor.py','route_supervisor.py']:
        shutil.copyfile(Path(__file__).with_name(helper),run/helper)
    toolkit = fpga / 'build/full_integration_20261013/tools/verilator-wheel/unpacked/verilator'
    # CMake's native Verilator integration avoids shell-generated make commands
    # and preserves the installed Windows C++ compiler/toolchain configuration.
    cmake = 'E:/STM32CubeCLT/STM32CubeCLT_1.18.0/CMake/bin/cmake.exe'
    ninja = 'E:/STM32CubeCLT/STM32CubeCLT_1.18.0/Ninja/bin/ninja.exe'
    cpp = 'D:/C Tool Chains/mingw64/bin/g++.exe'
    cmake_source = run / 'CMakeLists.txt'
    cmake_text = 'cmake_minimum_required(VERSION 3.19)\nproject(fpga_video_sim LANGUAGES CXX)\n'
    cmake_text += 'set(CMAKE_CXX_STANDARD 20)\nset(CMAKE_CXX_STANDARD_REQUIRED ON)\n'
    cmake_text += f'include("{(toolkit / "verilator-config.cmake").as_posix()}")\n'
    # --main supplies the standard scheduled SV simulation loop; the dummy
    # compilation unit intentionally contributes no driver or alternate model.
    (run / 'build_anchor.cpp').write_text('// Build anchor; SV testbench owns all stimulus and checking.\n', encoding='utf-8')
    cmake_text += 'add_executable(video_sim build_anchor.cpp)\n'
    cmake_text += 'verilate(video_sim TOP_MODULE tb_video_memory_core\n SOURCES\n'
    for name in names:
        if not name.endswith('.vh'):
            cmake_text += f' "{(source / name).as_posix()}"\n'
    cmake_text += f' INCLUDE_DIRS "{(source / "rtl/memory").as_posix()}"\n'
    cmake_text += ' VERILATOR_ARGS --timing --main -Wno-fatal'
    if options.full_frame:
        cmake_text += ' -GWIDTH=1920 -GHEIGHT=1080'
    if options.network_test:
        cmake_text += ' -GNETWORK_TEST=1'
    if options.control_test:
        cmake_text += ' -GCONTROL_TEST=1'
    if options.snapshot_test:
        cmake_text += ' -GSNAPSHOT_TEST=1'
    if options.display_test:
        cmake_text += ' -GDISPLAY_TEST=1'
    cmake_text += ')\n'
    cmake_source.write_text(cmake_text, encoding='utf-8')
    environment = os.environ.copy()
    environment['PATH'] = 'D:/C Tool Chains/mingw64/bin;' + environment['PATH']
    environment['VERILATOR_ROOT'] = str(toolkit)
    result = {'passed': False, 'full_frame': options.full_frame, 'network_test': options.network_test,
              'rtl_snapshot': str(options.rtl_snapshot) if options.rtl_snapshot else None, 'snapshot_test': options.snapshot_test, 'control_test': options.control_test,
              'hardware_tested': False, 'board_integrated': False, 'compiler': 'Verilator 5.052 / GCC 13.1.0'}
    result['build_jobs'] = options.build_jobs
    result['fixture_snapshot'] = str(options.fixture_snapshot) if options.fixture_snapshot else None
    result['display_test'] = options.display_test
    result['run_timeout_seconds']=options.run_timeout_seconds or (2400 if options.display_test else 1200)
    result['proof_phases']=[]
    print('VERILATOR_START', run, flush=True)
    try:
        commands = [
            ('configure', [cmake, '-S', str(run), '-B', str(run / 'cpp'), '-G', 'Ninja',
                           '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_CXX_COMPILER=' + cpp, '-DCMAKE_MAKE_PROGRAM=' + ninja]),
            # Limit compiler memory when native PnR jobs are running alongside
            # this independent model. Generated RTL semantics remain identical.
            ('build', [cmake, '--build', str(run / 'cpp'), '--parallel', str(options.build_jobs)]),
            ('run', [str(run / 'cpp/video_sim.exe')]),
        ]
        for phase, command in commands:
            print('VERILATOR', phase, flush=True)
            # Software jobs do not consume the native PDS slot. They still
            # observe quota/user stop, have a fixed prelaunch allowance and
            # reap owned compiler/simulation descendants on interruption.
            process=run_proof(command,cwd=run,environment=environment,log_path=run/(phase+'.log'),
                timeout_seconds=result['run_timeout_seconds'] if phase=='run' else 1200,pause_path=pause)
            result['proof_phases'].append(dict(phase=phase,**process))
            output = (run / (phase + '.log')).read_text(errors='replace')
            if process['returncode'] or (phase == 'run' and ('TB_VIDEO_MEMORY_CORE_PASS' not in output or 'FATAL' in output)):
                raise RuntimeError(phase + ': ' + output[-5000:])
        result['passed'] = True
    finally:
        result['snapshot_intact'] = all(hashlib.sha256((source / n).read_bytes()).hexdigest() == h for n, h in hashes.items())
        (run / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        print('VERILATOR_RESULT', json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
