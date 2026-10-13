"""Prove derivative ownership/cache bounds and monotonic timing semantics."""
import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from pango_video.preview_delivery import PreviewDelivery
from pango_video.protocol import frame_header
from pango_video.reassembly import CompleteFrame
from pango_video.web_session import frame_info
from pango_video.linux_udp import load_native


class DeliveryTests(unittest.TestCase):
    def test_shared_derivative_cache_never_changes_raw_or_source_identity(self):
        frame = CompleteFrame(frame_header(stream_epoch=4,frame_id=8,width=16,height=8,bayer_code=1),
                              bytes(range(128)),1_000_000,4_000_000)
        digest = hashlib.sha256(frame.data).hexdigest()
        info = frame_info(frame,"test-run","mock")
        delivery = PreviewDelivery(max_entries=1,max_bytes=128)
        a, ai = delivery.payload(frame,info,"raw",2)
        b, bi = delivery.payload(frame,info,"raw",2)
        self.assertIs(a,b)
        self.assertFalse(ai["host_timing"]["derivative_cache_hit"])
        self.assertTrue(bi["host_timing"]["derivative_cache_hit"])
        self.assertEqual(bi["host_timing"]["assembly_ms"],3)
        self.assertEqual(bi["width"],16)
        self.assertEqual(hashlib.sha256(frame.data).hexdigest(),digest)
        raw, ri = delivery.payload(frame,info,"raw",1)
        self.assertIs(raw,frame.data)
        self.assertNotIn("preview_derivative",ri)
        delivery.payload(frame,info,"color",2)
        self.assertLessEqual(delivery.status()["cache_bytes"],128)
        self.assertEqual(delivery.status()["cache_entries"],1)
        self.assertNotIn("conversion_ms", info["host_timing"])

    def test_native_module_fallback_explains_architecture_and_hash_failure(self):
        # Use only fixture manifests/bytes; never alter the running local build.
        digest=hashlib.sha256(b"fixture").hexdigest()
        import platform
        manifest=dict(machine=platform.machine(),abi=1,source_sha256=digest,binary_sha256=digest)
        for changed,reason in [(dict(machine="other"),"architecture_mismatch"),
                (dict(abi=5),"abi_mismatch"),(dict(source_sha256="bad"),"source_hash_mismatch"),
                (dict(binary_sha256="bad"),"binary_hash_mismatch")]:
            state={}
            with patch.object(Path,"read_text",return_value=json.dumps(dict(manifest,**changed))), \
                 patch.object(Path,"read_bytes",return_value=b"fixture"):
                self.assertIsNone(load_native(state))
            self.assertEqual(state["reason"],reason)
            self.assertFalse(state["enabled"])
        state={}
        with patch.object(Path,"read_text",side_effect=FileNotFoundError()):
            self.assertIsNone(load_native(state))
        self.assertEqual(state["reason"],"missing_build")
