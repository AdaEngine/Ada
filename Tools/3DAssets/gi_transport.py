"""Offline diffuse transport. NumPy + dependency-free native BVH; linear units throughout."""
import ctypes
import hashlib
import math
import os
from pathlib import Path
import shutil
import subprocess
import numpy as np

ROOT=Path(__file__).resolve().parents[2]

def normalize(v):
    return v/np.maximum(np.linalg.norm(v,axis=-1,keepdims=True),1e-12)

def hemisphere(normals,count):
    n=np.asarray(normals)
    axis=np.broadcast_to([0.,1.,0.],n.shape).copy(); axis[np.abs(n[:,1])>.95]=[1,0,0]
    tangent=normalize(np.cross(axis,n)); bitangent=np.cross(n,tangent)
    i=np.arange(count); r=np.sqrt((i+.5)/count); phi=i*2.399963229728653
    return tangent[:,None,:]*(r*np.cos(phi))[None,:,None]+bitangent[:,None,:]*(r*np.sin(phi))[None,:,None]+n[:,None,:]*np.sqrt(1-r*r)[None,:,None]

def sphere(count):
    i=np.arange(count); y=1-2*(i+.5)/count; r=np.sqrt(1-y*y); phi=i*2.399963229728653
    return np.stack([r*np.cos(phi),y,r*np.sin(phi)],axis=-1)

def sh_basis(d):
    x,y,z=np.moveaxis(d,-1,0)
    return np.stack([np.ones_like(x)*.2820947918,.4886025119*y,.4886025119*z,.4886025119*x,
        1.0925484306*x*y,1.0925484306*y*z,.3153915653*(3*z*z-1),1.0925484306*x*z,.5462742153*(x*x-y*y)],axis=-1)

class Tracer:
    def __init__(self,triangles,cache=None):
        source=Path(__file__).with_name('gi_trace.cpp')
        cache=Path(cache or ROOT/'.build-tools/gi-baker'); cache.mkdir(parents=True,exist_ok=True)
        key=hashlib.sha256(source.read_bytes()).hexdigest()[:16]
        library=cache/('gi-'+key+('.dll' if os.name=='nt' else '.dylib' if os.uname().sysname=='Darwin' else '.so'))
        if not library.exists():
            compiler=shutil.which('clang++') or shutil.which('g++')
            if not compiler: raise RuntimeError('Install clang++/g++ to build the offline GI ray tracer')
            flags=['-std=c++17','-O3','-shared']
            flags+=['-fms-runtime-lib=dll','-D_MT','-D_DLL','-lucrt','-lvcruntime','-lmsvcprt','-lmsvcrt','-Xlinker','/NODEFAULTLIB:libcmt'] if os.name=='nt' else ['-fPIC']
            subprocess.run([compiler,*flags,str(source),'-o',str(library)],check=True)
        self.lib=ctypes.CDLL(str(library)); f=ctypes.POINTER(ctypes.c_float); i=ctypes.POINTER(ctypes.c_int32)
        self.lib.gi_create.argtypes=[f,ctypes.c_int]; self.lib.gi_create.restype=ctypes.c_void_p
        self.lib.gi_destroy.argtypes=[ctypes.c_void_p]
        self.lib.gi_trace.argtypes=[ctypes.c_void_p,f,f,ctypes.c_int,ctypes.c_float,ctypes.c_float,f,i]
        triangles=np.ascontiguousarray(triangles,dtype=np.float32)
        if not np.isfinite(triangles).all(): raise ValueError('Nonfinite geometry')
        self.handle=self.lib.gi_create(triangles.ctypes.data_as(f),len(triangles))
        if not self.handle: raise ValueError('Empty/oversized BVH')
    def __del__(self):
        if getattr(self,'handle',None): self.lib.gi_destroy(self.handle)
    def trace(self,origins,directions,far=1000.,near=.002):
        shape=np.broadcast_shapes(np.shape(origins),np.shape(directions))
        o=np.ascontiguousarray(np.broadcast_to(origins,shape).reshape(-1,3),dtype=np.float32)
        d=np.ascontiguousarray(np.broadcast_to(directions,shape).reshape(-1,3),dtype=np.float32)
        distances=np.empty(len(o),dtype=np.float32); hits=np.empty(len(o),dtype=np.int32)
        f=ctypes.POINTER(ctypes.c_float); i=ctypes.POINTER(ctypes.c_int32)
        self.lib.gi_trace(self.handle,o.ctypes.data_as(f),d.ctypes.data_as(f),len(o),near,far,distances.ctypes.data_as(f),hits.ctypes.data_as(i))
        return distances.reshape(shape[:-1]),hits.reshape(shape[:-1])

class Transport:
    def __init__(self,triangles,albedo,emission,sky,sun,locals=(),samples=64,bounces=2,cache=None):
        self.triangles=np.asarray(triangles); self.normals=normalize(np.cross(triangles[:,1]-triangles[:,0],triangles[:,2]-triangles[:,0]))
        self.tracer=Tracer(triangles,cache); self.samples=samples
        self.procedural_sky=sky if isinstance(sky,dict) and 'horizon' in sky else None
        self.sky_lower=np.asarray(sky.get('lower',[0,0,0]) if isinstance(sky,dict) else sky)
        self.sky_upper=np.asarray(sky.get('upper',[0,0,0]) if isinstance(sky,dict) else sky)
        points=triangles.mean(axis=1)+self.normals*.006
        direct=np.zeros_like(points)
        for light in ([sun] if sun else [])+list(locals):
            if 'directionToLight' in light:
                direction=np.broadcast_to(normalize(np.asarray(light['directionToLight'])),points.shape); distance=np.full(len(points),1000.)
                attenuation=np.ones(len(points))
            else:
                delta=np.asarray(light['position'])-points; distance=np.linalg.norm(delta,axis=1); direction=normalize(delta)
                ratio=distance/light['range']; attenuation=np.maximum(1-ratio**4,0)**2/np.maximum(distance**2,.01)
                if 'direction' in light:
                    cosine=(-direction)@normalize(np.asarray(light['direction']))
                    lo,hi=math.cos(math.radians(light['outerConeAngle'])),math.cos(math.radians(light['innerConeAngle']))
                    t=np.clip((cosine-lo)/max(hi-lo,1e-6),0,1); attenuation*=t*t*(3-2*t)
            depth,_=self.tracer.trace(points,direction)
            direct+=np.asarray(light['radiance'])*light['intensity']*(np.maximum(np.sum(self.normals*direction,axis=1),0)*attenuation*(depth>=distance-.012))[:,None]/math.pi
        # Cache diffuse transfer at triangle centres. Iterate bounded diffuse bounces;
        # receiver lightmaps/probes integrate separately at their own world positions.
        transfer=np.empty((len(points),samples),dtype=np.int32)
        sky_term=np.zeros_like(points)
        for begin in range(0,len(points),512):
            end=min(begin+512,len(points)); rays=hemisphere(self.normals[begin:end],samples)
            _,hit=self.tracer.trace(points[begin:end,None,:],rays)
            facing=np.sum(self.normals[np.maximum(hit,0)]*-rays,axis=-1)>0
            hit=np.where((hit>=0)&~facing,-2,hit); transfer[begin:end]=hit
            sky_term[begin:end]=(self.sky(rays)*(hit==-1)[...,None]).mean(axis=1)
        base=np.asarray(emission)+np.asarray(albedo)*(direct+sky_term)
        radiance=base.copy()
        for _ in range(max(0,min(bounces,4)-1)):
            gather=radiance[np.maximum(transfer,0)]*(transfer>=0)[...,None]
            radiance=base+np.asarray(albedo)*gather.mean(axis=1)
        self.radiance=np.maximum(radiance,0)
    def sky(self,directions):
        if self.procedural_sky is not None:
            s=self.procedural_sky; h=directions[...,1:2]; blend=np.abs(h)**.55
            hemisphere=np.where(h>=0,np.asarray(s['zenith']),np.asarray(s['ground']))
            color=np.asarray(s['horizon'])+(hemisphere-np.asarray(s['horizon']))*blend
            return np.where(color<=.04045,color/12.92,((color+.055)/1.055)**2.4)*s.get('intensity',1)
        t=np.clip(directions[...,1:2]*.5+.5,0,1)
        return self.sky_lower+(self.sky_upper-self.sky_lower)*t
    def sample(self,origins,directions):
        distances,hit=self.tracer.trace(origins,directions)
        radiance=self.sky(directions).copy()
        valid=hit>=0; radiance[valid]=self.radiance[hit[valid]]
        facing=np.sum(self.normals[np.maximum(hit,0)]*-directions,axis=-1)>0
        radiance[(hit>=0)&~facing]=0
        return radiance,distances,hit
    def diffuse(self,points,normals,samples=None):
        result=np.empty_like(points)
        for begin in range(0,len(points),256):
            end=min(begin+256,len(points)); rays=hemisphere(normals[begin:end],samples or self.samples)
            radiance,_,_=self.sample(points[begin:end,None,:]+normals[begin:end,None,:]*.008,rays)
            result[begin:end]=radiance.mean(axis=1) # irradiance / pi
        return result

def half_map(path,values):
    rgba=np.ones(values.shape[:-1]+(4,),dtype=np.float32); rgba[...,:values.shape[-1]]=values
    if not np.isfinite(rgba).all() or np.abs(rgba).max()>65000: raise ValueError('Invalid HDR bake')
    rgba.astype('<f2').tofile(path)
    return dict(file=Path(path).name,width=rgba.shape[1],height=rgba.shape[0])
