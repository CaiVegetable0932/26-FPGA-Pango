"""Independent domain, order and multi-source provenance regressions."""
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/"model"))
from motion_reference import (Observation, complete_pixel, effective_affine,
                              history_eligible, pose_affine, verify_viewport, source_coordinate)


class MotionReferenceTests(unittest.TestCase):
    def test_mechanical_degrees_and_domain(self):
        a=pose_affine((0,)*6, (1,)*6, (2,)*6, 1000, -500, 0, 0, (-2000,2000,-1000,1000))
        self.assertTrue(all(abs(x)<1e-15 for x in a))
        with self.assertRaises(ValueError):
            pose_affine((0,)*6,(1,)*6,(2,)*6,3000,0,0,0,(-2000,2000,-1000,1000))

    def test_noncommuting_order(self):
        # S translates ray x, M turns output pixels, V crops around its centre.
        actual=effective_affine((1,0,.1,0,1,.2),(0,-.01,.5,.02,0,-.4),101,51,2)
        expected=(0,-.005,.475,.01,0,.3)
        for a,b in zip(actual,expected):self.assertAlmostEqual(a,b)

    def test_full_pixel_viewport_border(self):
        self.assertEqual(verify_viewport((.05,0,-.15,0,.05,-.15),(0,0,0,0,10,10,3.5,3.5),8,8),[])
        self.assertGreater(len(verify_viewport((.1,0,-.35,0,.1,-.35),(0,0,0,0,10,10,3.5,3.5),8,8)),0)

    def test_four_corners_cannot_certify_nonlinear_domain(self):
        # This radial polynomial maps all four corners safely while side
        # interiors leave the source. The complete verifier must reject it.
        matrix=(2/15,0,-1,0,2/15,-1)
        lens=(4,-2.175,0,0,7.5,7.5,7.5,7.5)
        for u,v in ((0,0),(0,15),(15,0),(15,15)):
            x,y=source_coordinate(matrix,u,v,lens)
            self.assertTrue(0<x<15 and 0<y<15)
        self.assertGreater(len(verify_viewport(matrix,lens,16,16)),0)

    def test_history_identity_quality_and_provenance(self):
        h=Observation(1,2,3,4,5,6,80)
        c=Observation(1,4,3,4,5,6,82)
        kw=dict(max_age=2,min_confidence=10,confidence=20,max_luma_delta=4,slot_available=True,affine_enabled=True)
        self.assertTrue(history_eligible(c,h,**kw))
        for field,value in (("slot_available",False),("affine_enabled",False),("max_age",1),("confidence",0)):
            changed=dict(kw);changed[field]=value;self.assertFalse(history_eligible(c,h,**changed))
        self.assertFalse(history_eligible(c,Observation(2,2,3,4,5,6,80),**kw))
        self.assertFalse(history_eligible(c,Observation(1,2,3,4,5,6,80,real_s1=False),**kw))
        self.assertEqual(complete_pixel((1,2,3),True,(9,8,7),True,True,False),((1,2,3),1))
        self.assertEqual(complete_pixel((1,2,3),False,(9,8,7),True,True,False),((9,8,7),2))
        self.assertEqual(complete_pixel((1,2,3),False,(9,8,7),True,True,True),((0,0,0),0))

if __name__=="__main__":unittest.main()
