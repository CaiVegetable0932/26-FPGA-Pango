"""Golden contract regression, independent arithmetic/property checks for module 06."""
import sys
from pathlib import Path
import unittest
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'model'))
from isp_geometry import (Calibration,bilinear,colour,isp_fixed,map_fixed,map_float,
                          perspective_fixed,quant,reciprocal_fixed,rnd,sample_rgb,TileCacheModel)


class AlgorithmTests(unittest.TestCase):
    """Check colour/border invariants and exceptional coordinates, not just round trips."""
    def test_bayer_constant_colour_all_phases(self):
        for phase in range(4):
            raw=np.array([[ (17,89,89,231)[colour(x,y,phase)] for x in range(9)] for y in range(7)],dtype=np.uint8)
            self.assertTrue(np.all(isp_fixed(raw,phase)==[17,89,231]))

    def test_two_pixel_borders(self):
        raw=np.array([[10,50],[80,220]],dtype=np.uint8)
        np.testing.assert_array_equal(isp_fixed(raw), [[[10,65,220],[10,50,220]],[[10,80,220],[10,65,220]]])

    def test_black_gain_clamp(self):
        self.assertTrue(np.all(isp_fixed(np.zeros((4,4),np.uint8),black=(64,)*4,gains=(65535,)*4)==0))
        self.assertTrue(np.all(isp_fixed(np.full((4,4),255,np.uint8),gains=(65535,)*4)==255))

    def test_colour_matrix(self):
        identity=np.eye(3,dtype=np.int64)*16384
        raw=np.arange(64,dtype=np.uint8).reshape(8,8)
        np.testing.assert_array_equal(isp_fixed(raw),isp_fixed(raw,matrix=identity))
        self.assertTrue(np.all(isp_fixed(raw,matrix=-identity)==0))

    def test_single_rounding(self):
        samples=np.array([[0]*3,[0]*3,[0]*3,[1]*3])
        np.testing.assert_array_equal(bilinear(samples,3000,3000),[1,1,1])
        # Premature horizontal 8-bit rounding would yield zero for this lane.
        np.testing.assert_array_equal(bilinear([[0]*3,[1]*3,[1]*3,[2]*3],2048,2048),[1,1,1])

    def test_border_and_signed_floor(self):
        image=np.arange(36,dtype=np.uint8).reshape(3,4,3)
        for y in range(3):
            for x in range(4):
                pixel,ok=sample_rgb(image,x*4096,y*4096)
                self.assertTrue(ok);np.testing.assert_array_equal(pixel,image[y,x])
        self.assertFalse(sample_rgb(image,-1,0)[1])
        self.assertFalse(sample_rgb(image,3*4096+1,0)[1])
        self.assertEqual((-1)//4096,-1)

    def test_pre_post_differ(self):
        image=np.array([[[0]*3,[255]*3],[[0]*3,[255]*3]],dtype=np.uint8)
        lut=np.array([round(255*(v/255)**0.7) for v in range(256)])
        pre,_=sample_rgb(image,2048,0,1,lut);post,_=sample_rgb(image,2048,0,2,lut)
        self.assertEqual(int(pre[0]),128);self.assertGreater(int(post[0]),128)

    def test_identity_fixed(self):
        c=Calibration(64,48,(32,32,32,24),(0,0,0,0),(1/32,0,-1,0,1/32,-0.75))
        u,v=np.meshgrid(np.arange(64,dtype=np.int64),np.arange(48,dtype=np.int64))
        x,y,mask,ok,_=map_fixed(u,v,c)
        np.testing.assert_array_equal(x,u*4096);np.testing.assert_array_equal(y,v*4096)
        self.assertTrue(np.all(mask&ok))

    def test_recurrence_no_drift(self):
        c=Calibration(1920,1080,(900,910,950,550),(-.2,.03,.001,-.002),(1/900,.0001,-1,.0002,1/910,-.7))
        a=c.coefficients()[:6];x=a[2]+a[1]*1079
        for u in range(1920):
            self.assertEqual(x,a[0]*u+a[1]*1079+a[2]);x+=a[0]

    def test_overflow_rejected(self):
        with self.assertRaises(ValueError):quant(32,32,26)
        c=Calibration(1920,1080,(900,900,960,540),(31,31,31,31),(0,0,7,0,0,7))
        self.assertFalse(map_fixed(np.int64(0),np.int64(0),c)[3])

    def test_reciprocal(self):
        for d in (0,-1,16383,1<<39):self.assertFalse(reciprocal_fixed(d)[1])
        for d in (16384,65535,1<<20,1<<26,3<<26, (1<<39)-1):
            r,ok=reciprocal_fixed(d);self.assertTrue(ok)
            self.assertLess(abs(r/(1<<34)-(1<<26)/d),2e-5)

    def test_negative_depth_invalid(self):
        c=Calibration(64,48,(32,32,32,24),(0,0,0,0),(1/32,0,-1,0,1/32,-.75))
        for depth in (0,-1,1e-6):
            self.assertFalse(perspective_fixed(0,0,[[1/32,0,-1],[0,1/32,-.75],[0,0,depth]],c)[3])

    def test_cache_repeat_and_duplicate(self):
        c=TileCacheModel(32,32)
        c.access(31*4096,31*4096);self.assertEqual(c.misses,1);self.assertEqual(c.duplicates,3)
        b=c.bus_bytes;c.access(31*4096,31*4096);self.assertEqual(c.bus_bytes,b)

    def test_cache_pinned_same_set(self):
        # Four corner tiles can share a set; pinned lines must survive all fills.
        c=TileCacheModel(64,64,sets=1,ways=4)
        for _ in range(10):c.access(15*4096+128,15*4096+128)
        self.assertEqual(c.misses,4)


if __name__=='__main__':unittest.main(verbosity=2)
