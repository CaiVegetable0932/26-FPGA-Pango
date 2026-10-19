"""Test account-quota extraction with synthetic events only."""
import json
from pathlib import Path
import tempfile
import unittest
from optimization_status import latest_quota


class QuotaTests(unittest.TestCase):
    """Quota percentages must come from explicit account events."""
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


if __name__ == '__main__':
    unittest.main()
