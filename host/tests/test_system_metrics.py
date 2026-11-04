"""CPU readings must use interval deltas and disclose missing/reset counters."""
import unittest
from unittest.mock import mock_open, patch

from pango_video.system_metrics import SystemMetrics, cpu_times


class SystemMetricsTests(unittest.TestCase):
    def test_linux_guest_time_is_not_added_twice(self):
        # guest/guest_nice overlap user/nice; iowait remains part of idle.
        with patch("sys.platform", "linux"), patch("pathlib.Path.open", mock_open(
                read_data="cpu 100 20 30 400 50 6 7 8 9 10\n")):
            self.assertEqual(cpu_times(), (621, 450))

    def test_delta_shared_cache_and_unavailable_samples(self):
        now = [0.0]
        values = iter([(1000, 600), (1200, 650), OSError("missing"),
                       (1500, 800), (10, 5), (110, 105)])
        def reader():
            value = next(values)
            if isinstance(value, Exception):
                raise value
            return value
        metrics = SystemMetrics(reader=reader, clock=lambda: now[0])
        self.assertIsNone(metrics.status()["cpu_percent"])
        now[0] = 1
        self.assertEqual(metrics.status()["cpu_percent"], 75.0)
        # A second browser neither consumes counters nor changes the interval.
        now[0] = 1.5
        self.assertEqual(metrics.status()["cpu_percent"], 75.0)
        now[0] = 2
        self.assertIsNone(metrics.status()["cpu_percent"])
        now[0] = 3
        self.assertIsNone(metrics.status()["cpu_percent"])
        now[0] = 4
        self.assertIsNone(metrics.status()["cpu_percent"])
        now[0] = 5
        self.assertEqual(metrics.status()["cpu_percent"], 0.0)
