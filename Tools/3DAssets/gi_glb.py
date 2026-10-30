"""Static GLB ingestion and deterministic secondary-UV charts. Does not mutate source assets."""
import copy
import io
import json
import math
from pathlib import Path
import struct
import numpy as np
from PIL import Image
from gi_transport import normalize

def matrix(t):
    if 'matrix' in t: return np.asarray(t['matrix']).reshape(4,4).T
    def vector(value,default):
        if isinstance(value,dict): return [value.get(c,default[i]) for i,c in enumerate('xyzw'[:len(default)])]
        return value if value is not None else default
    x,y,z,w=vector(t.get('rotation'),[0,0,0,1])
    r=np.array([[1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],[2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],[2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]])
    m=np.eye(4); m[:3,:3]=r@np.diag(vector(t.get('scale'),[1,1,1])); m[:3,3]=vector(t.get('position',t.get('translation')),[0,0,0])
    return m

def linear(v): return np.where(v<=.04045,v/12.92,((v+.055)/1.055)**2.4)

class GLB:
    def __init__(self,path):
        self.path=Path(path); data=self.path.read_bytes()
        if len(data)<28 or struct.unpack_from('<III',data)!=(0x46546c67,2,len(data)): raise ValueError('Invalid GLB')
        size,kind=struct.unpack_from('<II',data,12)
        if kind!=0x4e4f534a: raise ValueError('Missing GLB JSON')
        self.doc=json.loads(data[20:20+size]); self.binary=bytearray(data[28+size:]); self.images={}
        if len(self.doc.get('buffers',[]))!=1 or 'uri' in self.doc['buffers'][0]: raise ValueError('Embedded GLB buffer required')
        self.output=copy.deepcopy(self.doc); self.output.setdefault('materials',[])
        self.new_meshes=[]; self.records=[]
    def accessor(self,index):
        a=self.doc['accessors'][index]
        if 'sparse' in a: raise ValueError('Sparse static bake accessor not supported')
        view=self.doc['bufferViews'][a['bufferView']]
        dtype={5126:'<f4',5125:'<u4',5123:'<u2',5121:'<u1',5122:'<i2',5120:'<i1'}[a['componentType']]
        n={'SCALAR':1,'VEC2':2,'VEC3':3,'VEC4':4}[a['type']]; item=np.dtype(dtype).itemsize
        ar=np.ndarray((a['count'],n),dtype=dtype,buffer=self.binary,offset=view.get('byteOffset',0)+a.get('byteOffset',0),strides=(view.get('byteStride',item*n),item)).copy()
        if a.get('normalized'): ar=ar.astype(float)/np.iinfo(dtype).max
        return ar
    def append(self,values,kind,integer=False):
        values=np.ascontiguousarray(values,dtype='<u4' if integer else '<f4')
        index=len(self.output['bufferViews']); self.binary.extend(b'\0'*(-len(self.binary)%4))
        self.output['bufferViews'].append(dict(buffer=0,byteOffset=len(self.binary),byteLength=values.nbytes)); self.binary.extend(values.tobytes())
        a=dict(bufferView=index,componentType=5125 if integer else 5126,count=len(values),type=kind)
        if kind=='VEC3': a.update(min=values.min(axis=0).tolist(),max=values.max(axis=0).tolist())
        self.output['accessors'].append(a); return len(self.output['accessors'])-1
    def texture(self,index):
        if index not in self.images:
            image=self.doc['images'][self.doc['textures'][index]['source']]
            if 'bufferView' not in image: raise ValueError('Bake requires embedded images')
            view=self.doc['bufferViews'][image['bufferView']]; begin=view.get('byteOffset',0)
            ar=np.asarray(Image.open(io.BytesIO(self.binary[begin:begin+view['byteLength']])).convert('RGBA'),dtype=float)/255
            self.images[index]=ar
        return self.images[index]
    def sample(self,binding,attributes,indices,srgb=False):
        coord=binding.get('texCoord',0); ext=binding.get('extensions',{}).get('KHR_texture_transform',{})
        coord=ext.get('texCoord',coord)
        key='TEXCOORD_'+str(coord)
        uv=self.accessor(attributes[key])[indices].mean(axis=1) if key in attributes else np.zeros((len(indices),2))
        uv*=np.array(ext.get('scale',[1,1])); angle=ext.get('rotation',0)
        uv=uv@np.array([[math.cos(angle),math.sin(angle)],[-math.sin(angle),math.cos(angle)]])+ext.get('offset',[0,0])
        image=self.texture(binding['index']); h,w,_=image.shape
        # Centroid material sampling preserves spatial colors without retaining texture data in the tracer.
        value=image[np.floor(uv[:,1]*h).astype(int)%h,np.floor(uv[:,0]*w).astype(int)%w].copy()
        if srgb: value[:,:3]=linear(value[:,:3])
        return value
    def collect(self,world,lightmapped=True):
        if any('skin' in n for n in self.doc.get('nodes',[])): raise ValueError('Static GI input cannot be skinned')
        all_records=[]
        def visit(index,parent):
            node=self.doc['nodes'][index]; transform=parent@matrix(node)
            if 'mesh' in node:
                mesh=copy.deepcopy(self.doc['meshes'][node['mesh']]); derived=[]
                for primitive in mesh['primitives']:
                    if primitive.get('mode',4)!=4 or primitive.get('targets'): raise ValueError('Static triangle meshes without morph targets required')
                    mat=self.doc.get('materials',[{}])[primitive.get('material',0)]
                    if mat.get('alphaMode','OPAQUE')!='OPAQUE':
                        derived.append(primitive); continue # Glass is excluded; no misleading opaque transport.
                    attrs=primitive['attributes']; p=self.accessor(attrs['POSITION'])
                    ix=self.accessor(primitive['indices']).reshape(-1,3) if 'indices' in primitive else np.arange(len(p)).reshape(-1,3)
                    points=(np.c_[p,np.ones(len(p))]@transform.T)[:,:3]; faces=points[ix]
                    if np.linalg.det(transform[:3,:3])<0: faces=faces[:,[0,2,1]]
                    pbr=mat.get('pbrMetallicRoughness',{}); base=np.broadcast_to(np.asarray(pbr.get('baseColorFactor',[1,1,1,1])[:3],float),(len(ix),3)).copy()
                    if 'baseColorTexture' in pbr: base*=self.sample(pbr['baseColorTexture'],attrs,ix,True)[:,:3]
                    metal=np.full(len(ix),pbr.get('metallicFactor',1),dtype=float)
                    if 'metallicRoughnessTexture' in pbr: metal*=self.sample(pbr['metallicRoughnessTexture'],attrs,ix)[:,2]
                    emission=np.broadcast_to(np.asarray(mat.get('emissiveFactor',[0,0,0]),float),(len(ix),3)).copy()
                    emission*=mat.get('extensions',{}).get('KHR_materials_emissive_strength',{}).get('emissiveStrength',1)
                    if 'emissiveTexture' in mat: emission*=self.sample(mat['emissiveTexture'],attrs,ix,True)[:,:3]
                    # Default dielectric diffuse energy. Runtime receiver shading supplies its exact Fresnel response.
                    albedo=np.clip(base*(1-metal[:,None])*.96,0,.98)
                    if lightmapped:
                        for name in ['baseColorTexture','metallicRoughnessTexture','normalTexture','emissiveTexture']:
                            binding=pbr.get(name,mat.get(name,{}))
                            if binding.get('texCoord',0)==1 or binding.get('extensions',{}).get('KHR_texture_transform',{}).get('texCoord',0)==1:
                                raise ValueError('UV1 must be reserved for static lighting (AO is remapped)')
                        material=len(self.output['materials']); self.output['materials'].append(copy.deepcopy(mat))
                        primitive['material']=material
                    else: material=primitive.get('material',0)
                    record=dict(glb=self,primitive=primitive,material=material,attributes=attrs,indices=ix,faces=faces,
                        albedo=albedo,emission=emission,transform=transform,lightmapped=lightmapped)
                    all_records.append(record); derived.append(primitive)
                mesh['primitives']=derived
                self.output['nodes'][index]['mesh']=len(self.new_meshes); self.new_meshes.append(mesh)
            for child in node.get('children',[]): visit(child,transform)
        for node in self.doc['scenes'][self.doc.get('scene',0)]['nodes']: visit(node,world)
        self.output['meshes']=self.new_meshes; self.records=all_records
        return all_records
    def install_uv(self,record,uv1,atlas_coordinates):
        ix=record['indices'].reshape(-1); attrs=record['attributes']; primitive=record['primitive']
        primitive['attributes']={key:self.append(self.accessor(accessor)[ix],self.doc['accessors'][accessor]['type']) for key,accessor in attrs.items() if key!='TEXCOORD_1'}
        primitive['attributes']['TEXCOORD_1']=self.append(uv1,'VEC2')
        primitive['indices']=self.append(np.arange(len(ix))[:,None],'SCALAR',True)
        # Preserve old UV1 AO on the new charts. Baked diffuse bypasses this material AO at runtime.
        material=self.output['materials'][record['material']]; ao=material.get('occlusionTexture')
        if ao and ao.get('texCoord',0)==1:
            old=self.accessor(attrs['TEXCOORD_1'])[record['indices']]
            face,bary,shape=atlas_coordinates
            if np.linalg.det(record['transform'][:3,:3])<0: old=old[:,[0,2,1]]
            uv=np.einsum('ni,nij->nj',bary,old[face])
            image=self.texture(ao['index']); h,w,_=image.shape
            value=image[np.clip((uv[:,1]*h).astype(int),0,h-1),np.clip((uv[:,0]*w).astype(int),0,w-1),0]
            array=np.full(shape,255,dtype=np.uint8); array.flat[:len(value)]=np.uint8(np.clip(value,0,1)*255)
            stream=io.BytesIO(); Image.fromarray(array).save(stream,format='PNG')
            raw=stream.getvalue(); self.binary.extend(b'\0'*(-len(self.binary)%4)); view=len(self.output['bufferViews'])
            self.output['bufferViews'].append(dict(buffer=0,byteOffset=len(self.binary),byteLength=len(raw))); self.binary.extend(raw)
            image_index=len(self.output.setdefault('images',[])); self.output['images'].append(dict(bufferView=view,mimeType='image/png'))
            texture=len(self.output.setdefault('textures',[])); self.output['textures'].append(dict(source=image_index))
            material['occlusionTexture']=dict(index=texture,texCoord=1,strength=ao.get('strength',1))
    def save(self,path):
        self.binary.extend(b'\0'*(-len(self.binary)%4)); self.output['buffers']=[dict(byteLength=len(self.binary))]
        raw=json.dumps(self.output,separators=(',',':')).encode(); raw+=b' '*(-len(raw)%4)
        Path(path).write_bytes(struct.pack('<III',0x46546c67,2,28+len(raw)+len(self.binary))+struct.pack('<II',len(raw),0x4e4f534a)+raw+struct.pack('<II',len(self.binary),0x004e4942)+self.binary)

def charts(faces,density=4,padding=2):
    area=np.linalg.norm(np.cross(faces[:,1]-faces[:,0],faces[:,2]-faces[:,0]),axis=1)*.5
    sizes=np.clip(np.ceil(np.sqrt(area*2)*density).astype(int)+padding*2+1,8,128)
    required=max(int(np.ceil(np.sqrt(np.sum(sizes*sizes)))),int(sizes.max()))
    width=2**math.ceil(math.log2(required))
    if width>4096: raise ValueError('Primitive exceeds 4096 lightmap atlas; split the source primitive')
    positions=np.empty((len(faces),2),dtype=int); x=y=row=0
    for i in sorted(range(len(sizes)),key=lambda k:(-sizes[k],k)):
        size=sizes[i]
        if x+size>width: y+=row; x=row=0
        positions[i]=[x,y]; x+=size; row=max(row,size)
    height=2**math.ceil(math.log2(max(y+row,1)))
    if height>4096: raise ValueError('Lightmap atlas exceeds 4096')
    # Dense atlas samples, including chart padding. -1 is an unused atlas texel.
    face=np.full((height,width),-1,dtype=int); bary=np.zeros((height,width,3))
    uv=np.empty((len(faces),3,2))
    for i,(pos,size) in enumerate(zip(positions,sizes)):
        x,y=pos; axis=(np.arange(size)+.5-padding-.5)/max(size-2*padding-1,1)
        u,v=np.meshgrid(axis,axis); b=np.stack([1-u-v,u,v],axis=-1)
        b=np.maximum(b,0); b/=np.maximum(b.sum(axis=-1,keepdims=True),1e-10)
        face[y:y+size,x:x+size]=i; bary[y:y+size,x:x+size]=b
        uv[i]=(pos+np.array([[padding+.5,padding+.5],[size-padding-.5,padding+.5],[padding+.5,size-padding-.5]]))/[width,height]
    return uv.reshape(-1,2),face,bary
