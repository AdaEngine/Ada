"""Physical/data-path acceptance for the offline baker; no graphics context required."""
import json
from pathlib import Path
import struct
import tempfile
import unittest
import numpy as np
from bake_gi import bake,bake_probes,oct_decode,verify
from gi_glb import GLB,charts
from gi_transport import Tracer,Transport,normalize

ROOT=Path(__file__).resolve().parents[2]

def floor_glb(path):
    p=np.array([[-2,0,-2],[-2,0,2],[2,0,-2],[2,0,2]],dtype='<f4')
    n=np.tile([0,1,0],(4,1)).astype('<f4'); uv=np.array([[0,0],[0,1],[1,0],[1,1]],dtype='<f4'); ix=np.array([0,1,2,2,1,3],dtype='<u4')
    binary=bytearray(); views=[]; accessors=[]
    for value,kind,component in [(p,'VEC3',5126),(n,'VEC3',5126),(uv,'VEC2',5126),(ix,'SCALAR',5125)]:
        views.append(dict(buffer=0,byteOffset=len(binary),byteLength=value.nbytes)); binary.extend(value.tobytes())
        a=dict(bufferView=len(views)-1,componentType=component,count=len(value),type=kind)
        if kind=='VEC3': a.update(min=value.min(axis=0).tolist(),max=value.max(axis=0).tolist())
        accessors.append(a)
    doc=dict(asset=dict(version='2.0'),scene=0,scenes=[dict(nodes=[0])],nodes=[dict(mesh=0)],
        meshes=[dict(primitives=[dict(attributes=dict(POSITION=0,NORMAL=1,TEXCOORD_0=2),indices=3,material=0)])],
        materials=[dict(pbrMetallicRoughness=dict(metallicFactor=0,baseColorFactor=[1,1,1,1]))],
        buffers=[dict(byteLength=len(binary))],bufferViews=views,accessors=accessors)
    raw=json.dumps(doc).encode(); raw+=b' '*(-len(raw)%4)
    path.write_bytes(struct.pack('<III',0x46546c67,2,28+len(raw)+len(binary))+struct.pack('<II',len(raw),0x4e4f534a)+raw+struct.pack('<II',len(binary),0x004e4942)+binary)

class BakedGI(unittest.TestCase):
    def test_bvh_distance_and_occlusion_match_known_geometry(self):
        triangles=np.array([[[0,-2,-2],[0,2,-2],[0,2,2]],[[0,-2,-2],[0,2,2],[0,-2,2]]],float)
        tracer=Tracer(triangles)
        distance,hit=tracer.trace([[-1,0,0],[-1,4,0]],[[1,0,0],[1,0,0]])
        self.assertAlmostEqual(float(distance[0]),1,places=6); self.assertGreaterEqual(hit[0],0); self.assertEqual(hit[1],-1)
    def test_cosine_energy_and_analytic_direct_exclusion(self):
        triangles=np.array([[[-10,0,-10],[-10,0,10],[10,0,-10]],[[10,0,-10],[-10,0,10],[10,0,10]]],float)
        transport=Transport(triangles,np.ones((2,3))*.8,np.zeros((2,3)),[.25,.5,1],
            dict(directionToLight=[0,1,0],radiance=[1,1,1],intensity=30),samples=32)
        result=transport.diffuse(np.array([[0,.01,0.]],float),np.array([[0,1,0.]],float))
        np.testing.assert_allclose(result,[[.25,.5,1]],atol=1e-6)
        bounce=transport.diffuse(np.array([[0,1,0.]],float),np.array([[1,0,0.]],float))
        self.assertGreater(float(bounce.mean()),.6,'Sun-lit floor must contribute a real diffuse bounce to another receiver')
    def test_probe_moments_detect_the_wall_between_rooms(self):
        triangles=np.array([[[0,-4,-4],[0,4,-4],[0,4,4]],[[0,-4,-4],[0,4,4],[0,-4,4]]],float)
        transport=Transport(triangles,np.ones((2,3))*.5,np.zeros((2,3)),[.2,.2,.2],None,samples=16)
        ROOT.joinpath('.build-tools').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='gi-probe-',dir=ROOT/'.build-tools') as folder:
            output=Path(folder)
            bake_probes(transport,dict(origin=[-1,-1,-1],spacing=[2,2,2],counts=[2,2,2],visibilityResolution=16),output,128)
            data=np.fromfile(output/'Grid-visibility.rgba16f',dtype='<f2').reshape(64,32,4).astype(float)
            # +X from the lower-left probe, two metres to a receiver on the other side of x=0.
            mean,m2,minimum,_=data[8,15]
            difference=2-mean-.04; variance=max(m2-mean*mean,0)
            visibility=(variance/max(variance+difference*difference,1e-6))**3
            self.assertLess(mean,1.1); self.assertLess(visibility,.001)
            self.assertLess(minimum,1.1)
    def test_bake_derives_uv1_keeps_source_and_rejects_stale_inputs(self):
        with tempfile.TemporaryDirectory(prefix='gi-bake-',dir=ROOT/'.build-tools') as folder:
            root=Path(folder); model=root/'Plane.glb'; floor_glb(model); original=model.read_bytes()
            config=root/'Scene.giscene'; config.write_text(json.dumps(dict(models=[dict(file='Plane.glb',name='Plane')],sky=[.25,.5,1],
                sun=dict(directionToLight=[0,1,0],radiance=[1,1,1],intensity=30))))
            report=bake(config,root/'Output',density=2,samples=16,bounces=1)
            self.assertEqual(model.read_bytes(),original)
            output=root/'Output'; glb=GLB(output/'Plane-Lightmapped.glb')
            primitive=glb.doc['meshes'][0]['primitives'][0]
            self.assertIn('TEXCOORD_1',primitive['attributes'])
            self.assertEqual(len(glb.accessor(primitive['attributes']['POSITION'])),6)
            self.assertTrue(np.all((glb.accessor(primitive['attributes']['TEXCOORD_1'])>0)&(glb.accessor(primitive['attributes']['TEXCOORD_1'])<1)))
            lm=json.loads((output/'Plane.lightmaps').read_text()); m=next(iter(lm['materials'].values()))
            values=np.fromfile(output/m['file'],dtype='<f2').reshape(m['height'],m['width'],4).astype(float)
            np.testing.assert_allclose(values[values[...,3]>.5,:3],np.tile([.25,.5,1],((values[...,3]>.5).sum(),1)),atol=.001)
            verify(output/'Bake.json')
            config.write_text(config.read_text()+' ')
            with self.assertRaisesRegex(ValueError,'Stale'): verify(output/'Bake.json')

if __name__=='__main__': unittest.main()
