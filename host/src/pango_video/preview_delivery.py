"""Bounded immutable display cache and local HTTP submission diagnostics."""
from collections import OrderedDict, deque
import threading
import time

from .preview import preview_payload


class PreviewDelivery:
    """Share derivatives across subscribers without retaining original frame owners."""
    def __init__(self, max_entries=4, max_bytes=16*1024*1024):
        self._lock = threading.Lock()
        self._cache = OrderedDict()
        self.max_entries, self.max_bytes = max_entries, max_bytes
        self._bytes = self.hits = self.misses = 0
        self._writes = deque(maxlen=512)

    def payload(self, frame, info, mode, scale):
        """Cache only immutable derived bytes; same frame/mode/scale shares ownership."""
        key = (info["key"], mode, scale)
        with self._lock:
            start = time.monotonic_ns()/1_000_000
            cached = self._cache.get(key)
            if cached is not None:
                self.hits += 1
                self._cache.move_to_end(key)
                pixels, derivative = cached
            else:
                self.misses += 1
                pixels, derivative = preview_payload(frame, mode, scale)
                # Native RAW is already immutable and session-owned. Avoid
                # retaining old full frames just to count a preview cache hit.
                if derivative and len(pixels) <= self.max_bytes:
                    while self._cache and (len(self._cache) >= self.max_entries or self._bytes+len(pixels)>self.max_bytes):
                        _, old = self._cache.popitem(last=False)
                        self._bytes -= len(old[0])
                    self._cache[key] = (pixels, derivative)
                    self._bytes += len(pixels)
            end = time.monotonic_ns()/1_000_000
        metadata = dict(info)
        metadata.update(derivative)
        metadata["host_timing"] = dict(info.get("host_timing", {}),
            conversion_start_ms=start, conversion_end_ms=end,
            conversion_ms=end-start, derivative_cache_hit=cached is not None)
        return pixels, metadata

    def sent(self, start):
        """Socket write completion is host-local, not proof of client display."""
        with self._lock:
            self._writes.append((time.monotonic_ns()/1_000_000)-start)

    def status(self):
        with self._lock:
            values = sorted(self._writes)
            def at(q):
                import math
                return values[max(0, math.ceil(len(values)*q)-1)] if values else None
            return dict(cache_entries=len(self._cache), cache_bytes=self._bytes,
                max_entries=self.max_entries, max_bytes=self.max_bytes,
                cache_hits=self.hits, cache_misses=self.misses,
                write_ms=dict(count=len(values),p50=at(.5),p95=at(.95),p99=at(.99),max=at(1)),
                scope="host_socket_write_not_browser_presentation")
