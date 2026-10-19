"""Test account-quota extraction with synthetic events only."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from optimization_status import latest_quota,record_status


class QuotaTests(unittest.TestCase):
    """Quota percentages must come from explicit account events."""
    def test_reserve_stops_regional_and_whole_design_jobs(self):
        # Regional authorization must never bypass the shared account reserve.
        root=Path(__file__).resolve().parents[1]/'build/route_optimization'
        with tempfile.TemporaryDirectory(dir=root) as directory:
            session=Path(directory)
            quota=dict(available=True,remaining_percent=10,at='2026-10-19T12:00:00Z')
            with patch('optimization_status.latest_quota',return_value=quota):
                result=record_status(session,session)
            self.assertTrue(result['stop_new_optimization'])
            for name in ('stop_requested.json','regional_stop_requested.json'):
                self.assertEqual(json.loads((session/name).read_text())['quota'],quota)

    def test_both_windows_and_newest_event(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'events.jsonl'
            rows = [dict(type='event_msg', timestamp='2026-10-19T12:00:00Z',
                         payload=dict(rate_limits=dict(primary=dict(used_percent=30), secondary=None))),
                    dict(type='event_msg', timestamp='2026-10-19T12:01:00Z',
                         payload=dict(rate_limits=dict(primary=dict(used_percent=40),
                                                       secondary=dict(used_percent=91))))]
            path.write_text('incomplete\n'+'\n'.join(json.dumps(row) for row in rows))
            result = latest_quota(Path(directory))
            self.assertEqual(result['remaining_percent'], 9)
            self.assertEqual(result['at'], rows[-1]['timestamp'])

    def test_unavailable_is_not_unlimited(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(latest_quota(Path(directory)),
                             dict(available=False, remaining_percent=None))

    def test_message_text_cannot_supply_account_quota(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory)/'events.jsonl').write_text(json.dumps(dict(
                type='response_item', timestamp='2026-10-19T12:00:00Z',
                payload=dict(rate_limits=dict(primary=dict(used_percent=0))))))
            self.assertFalse(latest_quota(Path(directory))['available'])

    def test_large_native_output_does_not_hide_last_account_event(self):
        with tempfile.TemporaryDirectory() as directory:
            event = dict(type='event_msg', timestamp='2026-10-19T12:00:00Z',
                         payload=dict(rate_limits=dict(primary=dict(used_percent=60))))
            (Path(directory)/'events.jsonl').write_text(
                json.dumps(event)+'\n'+json.dumps(dict(type='response_item', output='x'*600_000)))
            self.assertEqual(latest_quota(Path(directory))['remaining_percent'], 40)

    def test_partial_campaign_cannot_disable_quota_monitoring(self):
        root=Path(__file__).resolve().parents[1]/'build/route_optimization'
        root.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root) as directory:
            session=Path(directory);campaign=session/'pending';campaign.mkdir()
            (campaign/'campaign.json').write_text('{"attempts": [')
            with patch('optimization_status.latest_quota',return_value=dict(available=False,remaining_percent=None)):
                result=record_status(session,session)
            self.assertEqual(result['campaigns'][0]['attempt']['phase'],'ledger_write_pending')
            self.assertFalse(result['quota_fresh'])


if __name__ == '__main__':
    unittest.main()
