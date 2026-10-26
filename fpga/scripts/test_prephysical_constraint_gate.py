"""Exercise native-call admission with a fake supervisor; never run PDS.

Both physical entry modes must stop after MAP on STA-3015 or native errors.
Clean logs must still reach the physical phase, so a permanently closed gate
cannot satisfy this regression. Inputs and script hashes are retained.
"""
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import hashlib
import json
import sys
import build_video_system as build
import native_bitgen
import resume_video_system as resume
from constraint_report import require_native_constraints


def main():
    fpga = Path(__file__).resolve().parents[1]
    out = fpga / 'build/core_area_20261023' / datetime.now().strftime('prephysical_gate_%H%M%S_%f')
    out.mkdir(parents=True)
    hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in
              (Path(__file__), Path(build.__file__), Path(resume.__file__),
               Path(native_bitgen.__file__), fpga / 'scripts/constraint_report.py')}
    rows = []
    clean_ccr = 'Found 0 error(s), 0 critical warning(s), 0 warning(s), out of 2 constraint(s)\n'

    def fixture(name, log='I: Device Map done.\n', ccr=clean_ccr):
        """Make only evidence fixtures; no native database or executable."""
        run = out / name
        (run / 'source').mkdir(parents=True)
        (run / 'constraint_check').mkdir()
        (run / 'flow.pds').write_text('mock project\n', encoding='utf-8')
        (run / 'console.log').write_text(log, encoding='utf-8')
        if ccr is not None:
            (run / 'constraint_check/constraint_check.ccr').write_text(ccr, encoding='utf-8')
        return run
    # Use both native severity spellings accepted by the final result scanner.
    logs = {'critical_unmatched': 'C: STA-3015: No path found for specification.\n',
            'warning_unmatched': 'W: STA-3015: No path found for specification.\n',
            'native_error': 'E: Synthesis failed.\n',
            'clean': 'I: Device Map done.\n'}
    for stage in ('report_timing', 'gen_bit_stream'):
        for name, text in logs.items():
            run = fixture(stage + '_' + name)
            calls = []

            def fake_supervisor(command, **kwargs):
                """Record calls and supply logs; no shell or native executable."""
                calls.append(command[command.index('-run') + 1])
                kwargs['log_path'].write_text(text if len(calls) == 1 else 'I: Physical complete.\n', encoding='utf-8')
                return {'status': 'COMPLETED', 'returncode': 0}

            options = SimpleNamespace(stage=stage, overall_timeout_minutes=60, pause_file=None)
            with patch.object(build, 'run_supervised', side_effect=fake_supervisor), \
                    patch.object(build, 'require_mapped_lut_budget', return_value={'below_70_percent': True}) as lut:
                _, _, _, rejection = build.run_native_candidate(run, 'never-executed.exe', options, {})
            expected = ['dev_map', 'report_timing'] if name == 'clean' else ['dev_map']
            assert calls == expected, (stage, name, calls)
            assert bool(rejection) == ('unmatched' in name), (name, rejection)
            assert lut.call_count == (1 if name == 'clean' else 0), (name, lut.call_count)
            rows.append({'stage': stage, 'case': name, 'native_calls': calls,
                         'passed': True, 'rejection': rejection})
    # Prove the shared gate fails closed on incomplete CCR or CCR errors, and
    # sees diagnostics emitted by later physical/LCF or resumed STA processing.
    for name, ccr, extra, should_reject in [
        ('missing_ccr', None, None, True),
        ('bad_ccr', 'truncated report\n', None, True),
        ('ccr_error', 'Found 1 error(s), 0 critical warning(s), 0 warning(s), out of 2 constraint(s)\nE: TEST-0001: bad object\n', None, True),
        ('ccr_unmatched', 'Found 0 error(s), 1 critical warning(s), 0 warning(s), out of 2 constraint(s)\nC: STA-3015: bad path\n', None, True),
        ('physical_unmatched', clean_ccr, 'physical_console.log', True),
        ('resume_unmatched', clean_ccr, 'resume_fixture/report_timing.log', True),
        ('shared_pin_review', 'Found 0 error(s), 1 critical warning(s), 0 warning(s), out of 2 constraint(s)\nC: ConstraintEditor-2002: shared pin\n', None, False),
    ]:
        run = fixture(name, ccr=ccr)
        if extra:
            path = run / extra
            path.parent.mkdir(exist_ok=True)
            path.write_text('C: STA-3015: Missing post-map LCF path.\n', encoding='utf-8')
        rejected = False
        try:
            require_native_constraints(run)
        except ValueError:
            rejected = True
        assert rejected == should_reject, name
        rows.append({'stage': 'shared_gate', 'case': name, 'passed': True, 'rejected': rejected})
    # Exercise the real resume and checkpoint entry functions up to their next
    # mocked boundary. Bad candidates must fail before discovery/Tcl/native;
    # clean candidates must reach that boundary instead of being blanket denied.
    class BoundaryReached(RuntimeError):
        pass
    for entry in ('resume', 'bitgen'):
        for bad in (True, False):
            run = fixture(entry + ('_bad' if bad else '_clean'),
                          logs['critical_unmatched'] if bad else logs['clean'])
            reached = False
            rejected = False
            try:
                if entry == 'resume':
                    with patch.object(sys, 'argv', ['resume', '--build', str(run), '--stop-after-timing']), \
                            patch.object(resume, 'require_whole_design_ready', return_value={}), \
                            patch.object(resume, 'require_mapped_lut_budget', side_effect=BoundaryReached), \
                            patch.object(resume, 'run_supervised', side_effect=AssertionError('Native launch forbidden')):
                        resume.main()
                else:
                    with patch.object(native_bitgen, 'require_whole_design_ready', return_value={'bitstream_generation_allowed': True}), \
                            patch.object(native_bitgen, 'require_routed_lut_budget', side_effect=BoundaryReached), \
                            patch.object(native_bitgen, 'run_supervised', side_effect=AssertionError('Native launch forbidden')):
                        native_bitgen.generate_from_timed_database(run, 'never-executed.exe', run / 'bitgen.log')
            except BoundaryReached:
                reached = True
            except ValueError:
                rejected = True
            assert rejected == bad and reached != bad, (entry, bad, rejected, reached)
            assert not (run / 'bitgen_from_checkpoint.tcl').exists()
            assert not list(run.glob('resume_*'))
            rows.append({'stage': entry, 'case': 'unmatched' if bad else 'clean',
                         'passed': True, 'rejected': rejected, 'next_gate_reached': reached})
    intact = all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == h for p, h in hashes.items())
    assert intact
    result = {'passed': True, 'native_executed': False, 'source_hashes': hashes,
              'sources_intact': intact, 'tests': rows,
              'scope': 'Fresh physical admission, resume/checkpoint admission and shared CCR/later-log checks.'}
    (out / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print('PREPHYSICAL_CONSTRAINT_GATE_PASS', len(rows), out)


if __name__ == '__main__':
    main()
