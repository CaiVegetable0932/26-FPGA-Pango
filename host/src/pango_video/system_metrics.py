"""Small, cached whole-host CPU samples without a third-party dependency."""
from pathlib import Path
import sys
import threading
import time


def cpu_times():
    """Return aggregate total/idle counters; guest time must not be counted twice."""
    if sys.platform.startswith("linux"):
        with Path("/proc/stat").open() as source:
            fields = source.readline().split()
        if not fields or fields[0] != "cpu" or len(fields) < 5:
            raise ValueError("CPU counters unavailable")
        values = [int(v) for v in fields[1:9]]
        # Linux idle and I/O wait do not represent CPU execution. guest and
        # guest_nice are already included in user/nice, so use the first 8 fields.
        return sum(values), values[3] + (values[4] if len(values) > 4 else 0)
    if sys.platform == "win32":
        import ctypes
        from ctypes import wintypes
        idle, kernel, user = wintypes.FILETIME(), wintypes.FILETIME(), wintypes.FILETIME()
        query = ctypes.WinDLL("kernel32", use_last_error=True).GetSystemTimes
        query.argtypes = [ctypes.POINTER(wintypes.FILETIME)] * 3
        query.restype = wintypes.BOOL
        if not query(ctypes.byref(idle), ctypes.byref(kernel), ctypes.byref(user)):
            raise ctypes.WinError(ctypes.get_last_error())
        def ticks(value):
            return (value.dwHighDateTime << 32) | value.dwLowDateTime
        # Windows kernel time includes idle, and user time is separate.
        return ticks(kernel) + ticks(user), ticks(idle)
    raise OSError("CPU sampling is unsupported on this platform")


class SystemMetrics:
    """Share one nonblocking CPU interval across browser tabs and HTTP threads."""
    def __init__(self, reader=cpu_times, clock=time.monotonic):
        self.reader, self.clock = reader, clock
        self.lock = threading.Lock()
        self.previous = None
        self.sampled_at = None
        self.cached = dict(cpu_percent=None, interval_seconds=0.0, scope="host_total")

    def status(self):
        """Return a one-second cached delta, or null when counters are not valid."""
        with self.lock:
            now = self.clock()
            if self.sampled_at is not None and now - self.sampled_at < 1:
                return dict(self.cached)
            interval = 0.0 if self.sampled_at is None else now - self.sampled_at
            self.sampled_at = now
            percent = None
            try:
                current = self.reader()
                if self.previous is not None:
                    total = current[0] - self.previous[0]
                    idle = current[1] - self.previous[1]
                    if total > 0 and 0 <= idle <= total:
                        percent = round(100 * (total - idle) / total, 1)
                self.previous = current
            except (OSError, ValueError):
                # An unavailable sample must never retain a stale percentage.
                self.previous = None
            self.cached = dict(cpu_percent=percent, interval_seconds=round(interval, 3),
                               scope="host_total")
            return dict(self.cached)
