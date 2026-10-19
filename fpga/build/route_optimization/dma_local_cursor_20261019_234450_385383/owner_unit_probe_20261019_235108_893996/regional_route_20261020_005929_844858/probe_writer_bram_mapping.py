"""Screen the existing cycle-proven writer BRAM change in isolation.

Installed ADS guide pp19-20 and 69-72 define the unchanged synthesis/RAM
settings. This measures an existing selected change, not a new candidate.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
from route_supervisor import run_supervised


def digest(path):
    """Bind exact frozen files, including the original differential proof."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def diagnostic_writer(text, tiled, board_rgb_context=False):
    """Specialize only verified production input constants, equally on A/B.

    Keep unused public ports so both scan boundaries remain identical. This
    models the ISP writer's existing fixed connections, not disabled logic.
    """
    if text.count('parameter TILED=0') != 1:
        raise ValueError('Unexpected writer parameter')
    text = text.replace('parameter TILED=0', 'parameter TILED='+str(tiled), 1)
    if board_rgb_context:
        if tiled != 0:
            raise ValueError('Fixed raster ISP context cannot model tiled geometry')
        header, body = text.split(');', 1)
        constants = ''
        for name, width, value in (('frame_width', 16, "16'd1920"),
                                   ('frame_height', 16, "16'd1080"),
                                   ('frame_stride', 32, "32'd6144"),
                                   ('frame_rgb888', 1, "1'b1")):
            # Named constants support the existing stride[4:0] selection in
            # both Verilog front ends; selecting directly from a literal does not.
            local = 'DIAG_'+name.upper()
            constants += f'\n localparam [{width-1}:0] {local}={value};'
            body = re.sub(r'\b'+name+r'\b', local, body)
        text = header+');'+constants+'\n'+body
    return text


def main():
    """Preserve raster/tiled semantics and reject any unproven input bytes."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--proof', type=Path, required=True)
    parser.add_argument('--pause-file', type=Path, required=True)
    parser.add_argument('--tiled', type=int, choices=(0, 1), default=0)
    parser.add_argument('--board-rgb-context', action='store_true',
                        help='Use the actual fixed ISP writer geometry/stride/RGB connections')
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    proof = args.proof.resolve()
    if not proof.is_relative_to(fpga/'build'):
        raise ValueError('Frozen writer proof required')
    checked = json.loads((proof/'result.json').read_text())
    if not all(checked.get(k) for k in ('passed', 'cycle_equivalent', 'inputs_intact', 'storage_edges')):
        raise ValueError('Storage-edge differential proof required')
    if any(digest(Path(p)) != h for p, h in checked['inputs'].items()):
        raise ValueError('Writer proof input drift')
    originals = [Path(p) for p in checked['inputs'] if Path(p).name == 'original_frame_pixel_writer.sv']
    if len(originals) != 1:
        raise ValueError('Unique original writer required')
    current = fpga/'rtl/memory/frame_pixel_writer.sv'
    pack = fpga/'rtl/memory/dma_pixel_pack.v'
    if any(digest(p) not in checked['inputs'].values() for p in (current, pack)):
        raise ValueError('Current writer/packer bytes are not proven')
    candidate = fpga/'build/route_optimization'/datetime.now().strftime('writer_bram_screen_%Y%m%d_%H%M%S_%f')
    source = candidate/'source/rtl/memory'
    source.mkdir(parents=True)
    shutil.copyfile(originals[0], candidate/'original_frame_pixel_writer.sv')
    for p in (current, pack):
        shutil.copyfile(p, source/p.name)
    run = candidate/'unit_screen'
    run.mkdir()
    shutil.copyfile(__file__, run/'probe_script.py')
    shutil.copyfile(Path(__file__).with_name('route_supervisor.py'), run/'route_supervisor.py')
    sources = dict(baseline=candidate/'original_frame_pixel_writer.sv',
                   candidate=source/'frame_pixel_writer.sv')
    inputs = dict(checked['inputs'])
    for p in [*sources.values(), source/'dma_pixel_pack.v', proof/'result.json']:
        inputs[str(p)] = digest(p)
    if args.board_rgb_context:
        board = fpga/'rtl/board/video_memory_core.sv'
        text = board.read_text(encoding='utf-8')
        required = ('parameter WIDTH=1920,HEIGHT=1080',
                    '.frame_stride(32\'d6144)', '.frame_width(WIDTH[15:0])',
                    '.frame_height(HEIGHT[15:0])', '.frame_rgb888(1\'b1)')
        start = text.index('frame_writer_buffer isp_writer(')
        end = text.index('frame_writer_buffer raw_writer(', start)
        if required[0] not in text or any(s not in text[start:end] for s in required[1:]):
            raise ValueError('Production ISP constants changed')
        dest = candidate/'source/rtl/board/video_memory_core.sv'
        dest.parent.mkdir(parents=True)
        shutil.copyfile(board, dest)
        inputs[str(dest)] = digest(dest)
    result = dict(passed=False, routed=False, board_timing_signoff=False,
                  proof=str(proof), inputs=inputs, tiled=args.tiled,
                  board_rgb_context=args.board_rgb_context, jobs=[])
    print('WRITER_UNIT_SCREEN', run, flush=True)
    try:
        for label, writer in sources.items():
            build = run/label
            build.mkdir()
            text = writer.read_text(encoding='utf-8')
            (build/'writer.sv').write_text(diagnostic_writer(text, args.tiled,
                args.board_rgb_context), encoding='utf-8')
            shutil.copyfile(source/'dma_pixel_pack.v', build/'dma_pixel_pack.v')
            (build/'clock.fdc').write_text('create_clock -name clk -period 8.000 [get_ports clk]\n')
            flow = 'set_dir -impl_directory {'+build.as_posix()+'}\n'
            flow += 'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
            for name in ('writer.sv', 'dma_pixel_pack.v'):
                flow += 'add_design {'+(build/name).as_posix()+'}\n'
            flow += 'add_constraint {'+(build/'clock.fdc').as_posix()+'}\n'
            flow += 'compile -top_module frame_pixel_writer -system_verilog\n'
            flow += 'synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2\n'
            (build/'flow.tcl').write_text(flow)
            supervision = run_supervised(['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe',
                '-file', str(build/'flow.tcl'), '-work_dir', str(build)], cwd=build,
                log_path=build/'syn.log', timeout_seconds=1200,
                monitor_path=build/'synthesis_monitor.jsonl', pause_path=args.pause_file)
            errors = re.findall(r'^E:.*', (build/'syn.log').read_text(errors='replace'), re.M)
            result['jobs'].append(dict(label=label, supervision=supervision, errors=errors))
            if supervision['status'] != 'COMPLETED' or errors:
                raise RuntimeError('Writer synthesis did not complete: '+label)
            report = build/'synthesize/frame_pixel_writer.snr'
            text = report.read_text(errors='replace')
            metrics = {k: int(re.search(pattern, text)[1]) for k, pattern in (
                ('LUT', r'Total LUTs: (\d+)'), ('FF', r'Total Registers: (\d+)'),
                ('controlsets', r'Number of unique control sets : (\d+)'))}
            metrics['DRM'] = float(re.search(r'Total DRM = ([\d.]+)', text)[1])
            result[label] = dict(resources=metrics, report_sha256=digest(report))
            print(label, json.dumps(result[label]), flush=True)
        result['passed'] = True
    finally:
        result['inputs_intact'] = all(digest(Path(p)) == h for p, h in inputs.items())
        result['passed'] = result['passed'] and result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
