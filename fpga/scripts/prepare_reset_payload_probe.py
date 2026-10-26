"""Freeze two internal payload-only reset candidates for short 4-state review.

This preparation never edits live or board snapshots and never runs PDS. Public
status, ownership, valid/state/op reset and every externally visible latency are
retained; only internal data already protected by whole-record capture is split.
"""
from pathlib import Path
from datetime import datetime
import hashlib
import json


def main():
    fpga = Path(__file__).resolve().parents[1]
    board = fpga / 'build/full_integration_20261013/delay_20261014_171555'
    run = fpga / 'build/full_integration_20261013' / datetime.now().strftime('reset_payload_%Y%m%d_%H%M%S_%f')
    run.mkdir()
    identities = {}
    expected = {
        'rtl/control/pc_video_boot.sv': '663a237b8b6a68848da1751744af5717fd610b547bf399e575c27919c354ecb8',
    }
    for name, digest in expected.items():
        data = (board / 'source' / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != digest:
            raise RuntimeError(f'Frozen source differs: {name}')
        (run / ('original_' + Path(name).name)).write_bytes(data)
        text = data.decode('utf-8')
        if Path(name).name == 'pc_video_boot.sv':
            reset = 'status_snapshot<=0;'
            capture = "status_snapshot<=operation==8'h96 ? {snapshot_result_status,snapshot_s1_status}:{768'd0,(operation==8'h95 ? geometry_status:(operation==8'h97 ? snapshot_geometry_status:control_status))};"
            assert text.count(reset) == text.count(capture) == 1
            text = text.replace(reset, '').replace(capture, '')
            block = '''
 // Purpose: hold one complete PC readback entity without a data reset network.
 // Cold/midstream reset clears have_snapshot and operation/state. Nonzero pages
 // cannot observe this storage before matching page0 has overwritten ALL bits;
 // page0 replies use the live input directly. Keep the original capture edge.
 wire capture_status_payload=state==CHECK && received[7:0]==0 &&
  (operation==8'h90 || operation==8'h95 || operation==8'h96 || operation==8'h97);
 always @(posedge clk) if(rst_n && capture_status_payload)
  status_snapshot<=operation==8'h96 ? {snapshot_result_status,snapshot_s1_status}:
   {768'd0,(operation==8'h95 ? geometry_status:(operation==8'h97 ? snapshot_geometry_status:control_status))};
'''
            module = 'pc_video_boot'
        assert text.count('endmodule') == 1
        candidate = text.replace('endmodule', block + 'endmodule')
        candidate_path = run / ('candidate_' + Path(name).name)
        candidate_path.write_bytes(candidate.encode('utf-8'))
        # Keep the native candidate's module/ports unchanged. A separately named
        # comparison copy permits original and candidate to share one stimulus.
        comparison = candidate.replace('module ' + module, 'module ' + module + '_payload_candidate', 1)
        (run / ('compare_' + Path(name).name)).write_bytes(comparison.encode('utf-8'))
        identities[name] = {'original_sha256': digest,
                            'candidate_sha256': hashlib.sha256(candidate_path.read_bytes()).hexdigest()}
    dependencies = ['rtl/memory/frame_manager_pkg.sv', 'rtl/memory/frame_manager_layout.vh',
                     
                    'rtl/network/raw_dma_reader.sv', 'rtl/memory/dma_byte_unpack.v',
                    'rtl/control/uart_8n1.sv', 'rtl/control/uart_v2_parser.sv',
                    'rtl/control/parameter_entity_guard.sv']
    for name in dependencies:
        data = (board / 'source' / name).read_bytes()
        (run / Path(name).name).write_bytes(data)
        identities[name] = {'original_sha256': hashlib.sha256(data).hexdigest()}
    (run / 'preparation_script.py').write_bytes(Path(__file__).read_bytes())
    (run / 'sources.json').write_text(json.dumps(identities, indent=2), encoding='utf-8')
    (run / 'result.json').write_text(json.dumps({'prepared': True, 'passed': False,
        'source_board': str(board), 'native_synthesis_run': False, 'hardware_tested': False,
        'candidate_identity': identities}, indent=2), encoding='utf-8')
    print(run, flush=True)


if __name__ == '__main__':
    main()
