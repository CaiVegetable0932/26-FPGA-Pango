"""Synthesize shared integration units with installed PDS; no board release."""
from datetime import datetime
from pathlib import Path
import hashlib
import json
import re
import subprocess
import argparse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--units', nargs='+', choices=['frame_memory_fabric', 'geometry_tile_refill',
                        'frame_pixel_writer', 'dma_read_cdc', 'geometry_frame_processor', 'ov5640_integrated_startup'],
                        default=['frame_memory_fabric', 'geometry_tile_refill'])
    parser.add_argument('--closure-only', action='store_true',
                        help='Freeze and validate all unit input paths without launching PDS')
    args = parser.parse_args()
    # Unit synthesis is a separate gate from board constraints and bitstream.
    fpga = Path(__file__).resolve().parents[1]
    run = fpga / 'build/full_integration_20261013' / datetime.now().strftime('pds_%Y%m%d_%H%M%S_%f')
    run.mkdir(parents=True)
    names = ['rtl/memory/' + name for name in ['frame_manager_pkg.sv', 'frame_pool_bank.sv', 'frame_manager.sv',
             'ddr_native_dma.v', 'frame_memory_fabric.sv', 'geometry_tile_refill.sv',
             'dma_pixel_pack.v', 'frame_writer_buffer.sv', 'frame_pixel_writer.sv', 'dma_read_cdc.sv']]
    names += ['rtl/geometry/' + name for name in ['unsigned_mult32_pipe.sv','signed_mult40_unsigned40_pipe.sv','affine_ray_stepper.sv', 'lens_inverse_map.sv',
              'signed_mult32_pipe.sv', 'rgb_tile_cache.sv', 'rgb_cache_bank.sv', 'rgb_bilinear.sv',
              'gamma_lut_bank.sv', 'rgb_enhance.sv', 'geometry_rgb_pipeline.sv', 'geometry_frame_processor.sv']]
    names += ['rtl/input/ov5640_integrated_startup.v', 'rtl/input/ov5640_group_exposure.sv', 'rtl/input/ov5640_exposure_update.sv', 'rtl/input/ov5640_reference_profile.v',
              'rtl/input/ov5640_raw8_mode.v', 'rtl/input/ov5640_register_service.v',
              'rtl/mini_camera_diag/vendor/camera/SCCB.v', 'rtl/mini_camera_diag/vendor/camera/data_init.v']
    hashes = {}
    for name in [*names, 'rtl/memory/frame_manager_layout.vh']:
        data = (fpga / name).read_bytes()
        (run / Path(name).name).write_bytes(data)
        hashes[name] = hashlib.sha256(data).hexdigest()
    (run / 'sources.json').write_text(json.dumps(hashes, indent=2))
    # This gate checks the current affine source closure only. It must never
    # imply synthesis, timing, or execution of any unit test.
    if args.closure_only:
        report = dict(source_closure_complete=True, source_count=len(hashes), units=args.units,
                      architecture='affine_lens', native_started=False, elaborated=False,
                      synthesized=False, hardware_tested=False)
        (run / 'closure_result.json').write_text(json.dumps(report, indent=2))
        print('INTEGRATION_SOURCE_CLOSURE', run, flush=True)
        return
    shell = 'E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe'
    results = []
    for top in args.units:
        directory = run / top
        directory.mkdir()
        # Put include beside every source to match ADS's local include search.
        for name in [*names, 'rtl/memory/frame_manager_layout.vh']:
            (directory / Path(name).name).write_bytes((run / Path(name).name).read_bytes())
        tcl = directory / (top + '.tcl')
        text = '# Unit compile/synthesis only, PG2L100H; no external IO signoff.\n'
        text += f'set_dir -impl_directory {{{directory.as_posix()}}}\n'
        text += 'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
        for name in names:
            text += f'add_design {{{(directory / Path(name).name).as_posix()}}}\n'
        # Synthesis uses the intended internal clock, while board IO and routed
        # setup/hold remain separate gates. Abstract unit pins are not board IO.
        fdc = directory / 'unit.fdc'
        period = '8.0' if top == 'frame_memory_fabric' else ('37.037037' if top=='ov5640_integrated_startup' else '6.666667')
        if top == 'dma_read_cdc':
            fdc.write_text('create_clock -name {client_clk} [get_ports {client_clk}] -period {13.468013}\n'
                           'create_clock -name {memory_clk} [get_ports {memory_clk}] -period {8.0}\n')
        else:
            fdc.write_text(f'create_clock -name {{unit_clk}} [get_ports {{clk}}] -period {{{period}}}\n')
        text += f'add_constraint {{{fdc.as_posix()}}}\n'
        # ADS does not infer SystemVerilog solely from the .sv extension.
        text += f'compile -top_module {top} -system_verilog -include_path [list {{{directory.as_posix()}}}]\n'
        text += 'synthesize -ads -selected_syn_tool_opt 2\n'
        tcl.write_text(text)
        generate = directory / 'generate.tcl'
        generate.write_text(f'tcl2prj -tcl {{{tcl.as_posix()}}}\nputs INTEGRATION_PROJECT_CREATED\n')
        for phase, phase_args in [('generate', ['-file', str(generate)]),
                            ('synthesize', ['-project', str(directory / (top + '.pds')), '-run', 'synthesize'])]:
            print(top, phase, directory, flush=True)
            with (directory / (phase + '.log')).open('wb') as log:
                proc = subprocess.run([shell, *phase_args, '-work_dir', str(directory)], cwd=directory,
                                      stdout=log, stderr=subprocess.STDOUT, timeout=1800,
                                      creationflags=0x08000000)
            output = (directory / (phase + '.log')).read_text(errors='replace')
            success = proc.returncode == 0 and not re.search(r'(?m)^E:|Check license failed', output)
            if not success:
                results.append({'top': top, 'phase': phase, 'passed': False})
                (run / 'result.json').write_text(json.dumps(results, indent=2))
                raise RuntimeError(output[-5000:])
        report = directory / 'synthesize' / (top + '.snr')
        results.append({'top': top, 'passed': report.exists(), 'pnr_tested': False,
                        'board_integrated': False, 'hardware_tested': False})
        (run / 'result.json').write_text(json.dumps(results, indent=2))
        print(top, 'SYNTHESIS', report.exists(), flush=True)


if __name__ == '__main__':
    main()
