"""Fixed-layout frame provenance decoding and malformed record rejection."""
import struct
import unittest
from pango_video.motion_status import decode_motion_frame,decode_runtime_action_status


class MotionStatusTests(unittest.TestCase):
    def record(self):
        """Build a literal frame status with separate current/historical IDs."""
        value=bytearray(160)
        struct.pack_into("<HHIIHBBQQ",value,0,1,11,1,1,128,1,0,9,22)
        struct.pack_into("<6i4BIQQ10I",value,32,1,2,3,4,5,6,0,0,1,0,2,9,21,10,20,70,3,3,4,5,6,7,8)
        return value

    def test_actual_job_and_history(self):
        result=decode_motion_frame(bytes(self.record()))
        self.assertEqual((result.epoch,result.frame_id,result.history_frame_id),(9,22,21))
        self.assertEqual(result.matrix_q26,(1,2,3,4,5,6))
        self.assertEqual((result.current_pixels,result.historical_pixels,result.invalid_pixels),(70,10,20))
        self.assertEqual(result.isp_version,8)

    def test_unapplied_and_reserved(self):
        value=self.record();value[14]=0;self.assertIsNone(decode_motion_frame(bytes(value)))
        value=self.record();value[-1]=1
        with self.assertRaises(ValueError):decode_motion_frame(bytes(value))
        with self.assertRaises(ValueError):decode_motion_frame(bytes(value[:-1]))

    def test_withdrawn_visual_status_cannot_claim_history(self):
        """Status8 is an explicit unavailable certificate, never zero-motion success."""
        value=self.record();value[32+25]=8
        with self.assertRaises(ValueError):decode_motion_frame(bytes(value))
        value[32+26]=0
        for offset in (48,60,64):struct.pack_into('<I',value,32+offset,0)
        result=decode_motion_frame(bytes(value))
        self.assertEqual(result.visual_status,8)
        self.assertFalse(result.history_applied)
        for offset in (48,60,64):
            corrupt=bytearray(value);struct.pack_into('<I',corrupt,32+offset,1)
            with self.assertRaises(ValueError):decode_motion_frame(bytes(corrupt))

    def test_independent_pending_and_applied_action_boundary(self):
        value=self.record();value[14]=0
        struct.pack_into("<BB",value,32+88,2,3)
        struct.pack_into("<QQH",value,32+96,12,44,303)
        status=decode_runtime_action_status(bytes(value))
        self.assertEqual((status.pending_mask,status.last_action,status.applied_epoch,status.applied_frame_id,status.applied_sequence),(2,3,12,44,303))
        self.assertIsNone(decode_motion_frame(bytes(value)))
        value[14]=1
        self.assertEqual(decode_motion_frame(bytes(value)).frame_id,22)
        self.assertEqual(decode_motion_frame(bytes(value)).runtime_action.applied_frame_id,44)

if __name__=="__main__":unittest.main()
