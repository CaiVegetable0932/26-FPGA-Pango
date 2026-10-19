"""Verify separated phase commands/budgets without starting native PDS."""
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch
from regional_phase_budget import native_pnr_seconds,run_regional_phases


class PhaseBudgetTests(unittest.TestCase):
    def test_action_duration_excludes_prepare(self):
        """Cumulative 6-minute compile must never become PnR wall time."""
        self.assertEqual(native_pnr_seconds('Action pnr: Real time elapsed is 0h:2m:3s\n'
            'Action from compile to pnr: Total Real Time elapsed is 0h:8m:25s'),123)
        self.assertIsNone(native_pnr_seconds('compile incomplete'))

    def run_fake(self,failed_phase=None):
        """Produce only tiny mock checkpoints; assert the actual generated Tcl."""
        root=Path(__file__).resolve().parents[1]/'build/route_optimization'
        with tempfile.TemporaryDirectory(dir=root) as temporary:
            build=Path(temporary)
            flow='set_dir -impl_directory {'+build.as_posix()+'}\nset_arch -family Logos2\n'
            flow+='add_design {unit.sv}\ncompile -top_module regional_wrapper -system_verilog\n'
            flow+='synthesize -ads\ndev_map\npnr -action_timeout 20 -gplace_seed 11\n'
            flow+='report_timing -delay_type min_max\n'
            calls=[]
            def fake(command,**kwargs):
                phase=Path(command[2]).stem
                body=Path(command[2]).read_text()
                calls.append((phase,kwargs['timeout_seconds'],kwargs['baseline_success_seconds']))
                if phase=='prepare':
                    self.assertNotIn('\npnr ',body)
                    folder=build/'device_map';folder.mkdir()
                    (folder/'regional_wrapper_map.adf').write_text('mapped')
                    (folder/'regional_wrapper.pcf').write_text('pins')
                elif phase=='place_route':
                    self.assertIn('pnr -force_to_run -input_db_file',body)
                    self.assertNotIn('\ncompile ',body)
                    folder=build/'place_route';folder.mkdir()
                    (folder/'regional_wrapper_pnr.adf').write_text('routed')
                else:
                    self.assertIn('report_timing -force_to_run -input_db_file',body)
                    self.assertNotIn('\npnr ',body)
                kwargs['log_path'].write_text('native log\n')
                return dict(status='TIMEOUT' if failed_phase==phase else 'COMPLETED',
                    returncode=1 if failed_phase==phase else 0,pid=123,
                    elapsed_seconds=1,monitor=str(kwargs['monitor_path']))
            with patch('regional_phase_budget.run_supervised',side_effect=fake):
                result=run_regional_phases(build,flow,timeout_seconds=1200,
                    pause_path=None,baseline_success_seconds=60)
            return result,calls

    def test_three_phases_and_only_pnr_gets_adaptive_baseline(self):
        result,calls=self.run_fake()
        self.assertEqual(calls,[('prepare',1200,None),('place_route',1200,60),('report_timing',120,None)])
        self.assertEqual(result['status'],'COMPLETED')
        self.assertTrue(result['checkpoint_inputs_intact'])
        self.assertEqual(result['maximum_total_seconds'],2520)

    def test_timeout_never_starts_next_phase(self):
        result,calls=self.run_fake('place_route')
        self.assertEqual([r[0] for r in calls],['prepare','place_route'])
        self.assertEqual(result['status'],'TIMEOUT')


if __name__=='__main__':
    unittest.main()
