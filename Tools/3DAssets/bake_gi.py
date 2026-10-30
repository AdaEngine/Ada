"""Bake static diffuse lightmaps + spatial L2 irradiance probes from a .giscene JSON.

Needs NumPy/Pillow and clang++/g++. Sources are immutable; output GLBs receive
independent padded UV1 triangle charts. Analytic direct lighting is NOT baked
into receiver maps: sky visibility + diffuse interreflection replace ambient.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import time
import numpy as np
from gi_glb import GLB,charts,matrix
from gi_transport import Transport,half_map,normalize,sh_basis,sphere

def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def write_json(path,value): Path(path).write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8')

def oct_decode(uv):
    xy=uv*2-1; z=1-np.abs(xy).sum(axis=-1,keepdims=True)
    folded=(1-np.abs(xy[...,::-1]))*np.where(xy>=0,1.,-1.)
    return normalize(np.concatenate([np.where(z<0,folded,xy),z],axis=-1))

def bake_probes(transport,settings,output,samples):
    origin=np.asarray(settings['origin'],float); spacing=np.asarray(settings['spacing'],float); counts=np.asarray(settings['counts'],int)
    resolution=settings.get('visibilityResolution',16)
    if len(counts)!=3 or np.any(counts<2) or np.any(counts>64) or np.any(spacing<.01) or resolution not in [8,16,32]: raise ValueError('Invalid probe grid')
    nx,ny,nz=counts
    if counts.prod()>4096 or nx*resolution>4096 or ny*nz*resolution>4096: raise ValueError('Probe atlas budget exceeded')
    coefficients=np.zeros((ny*nz,nx*9,4)); visibility=np.zeros((ny*nz*resolution,nx*resolution,4))
    directions=sphere(samples); basis=sh_basis(directions)
    convolution=np.array([1,2/3,2/3,2/3,1/4,1/4,1/4,1/4,1/4])
    # Four primary visibility rays per octahedral texel preserve a distance distribution, not just one depth.
    yy,xx=np.mgrid[:resolution,:resolution]
    uv=np.stack([xx,yy],axis=-1)[...,None,:]+np.array([[.25,.25],[.75,.25],[.25,.75],[.75,.75]])
    visibility_directions=oct_decode(uv/resolution)
    valid_count=0
    for z in range(nz):
        for y in range(ny):
            for x in range(nx):
                position=origin+np.array([x,y,z])*spacing
                radiance,distance,hit=transport.sample(position,directions)
                back=np.sum(transport.normals[np.maximum(hit,0)]*directions,axis=-1)>0
                valid=not ((hit>=0).mean()>.6 and ((hit>=0)&back).mean()>.55) and distance.min()>.012
                valid_count+=int(valid)
                sh=(basis.T@radiance)*(4*math.pi/samples)*convolution[:,None]
                row=z*ny+y; coefficients[row,x*9:x*9+9,:3]=sh if valid else 0
                coefficients[row,x*9:x*9+9,3]=int(valid)
                distances,_=transport.tracer.trace(position,visibility_directions,far=100.)
                moments=np.stack([distances.mean(axis=-1),(distances*distances).mean(axis=-1),distances.min(axis=-1),np.ones((resolution,resolution))],axis=-1)
                visibility[row*resolution:(row+1)*resolution,x*resolution:(x+1)*resolution]=moments
        print(f'Probes slice {z+1}/{nz}',flush=True)
    if valid_count==0: raise ValueError('All probes are inside geometry; change origin/spacing')
    manifest=dict(version=1,encoding='sh9-diffuse-irradiance-over-pi',origin=dict(zip('xyz',origin)),spacing=dict(zip('xyz',spacing)),
        counts=counts.tolist(),visibilityResolution=resolution,
        coefficients=half_map(output/'Grid-sh.rgba16f',coefficients),visibility=half_map(output/'Grid-visibility.rgba16f',visibility))
    write_json(output/'Grid.probegrid',manifest)
    return dict(probes=int(counts.prod()),validProbes=valid_count,manifest='Grid.probegrid',samples=samples)

def bake(source,output,density=4,samples=64,bounces=2,probe_samples=512):
    started=time.monotonic(); source=Path(source).resolve(); output=Path(output).resolve(); output.mkdir(parents=True,exist_ok=True)
    config=json.loads(source.read_text(encoding='utf-8')); records=[]; models=[]; inputs={str(source):digest(source)}
    for index,entry in enumerate(config['models']):
        path=(source.parent/entry['file']).resolve(); inputs[str(path)]=digest(path)
        glb=GLB(path); model_records=glb.collect(matrix(entry.get('transform',{})),entry.get('lightmap',True))
        for record in model_records: record['model']=index
        records.extend(model_records); models.append((glb,entry))
    if not records: raise ValueError('No opaque static triangles')
    faces=np.concatenate([r['faces'] for r in records]); albedo=np.concatenate([r['albedo'] for r in records]); emission=np.concatenate([r['emission'] for r in records])
    print(f'Building transport: {len(faces)} triangles, {samples} samples, {bounces} diffuse levels',flush=True)
    transport=Transport(faces,albedo,emission,config.get('sky',[.1,.15,.2]),config.get('sun'),config.get('lights',[]),samples,bounces)
    maps=[{} for _ in models]; receiver_stats=[]
    for ordinal,record in enumerate(records):
        if not record['lightmapped']: continue
        uv,face,bary=charts(record['faces'],density); mask=face>=0
        points=np.einsum('ni,nij->nj',bary[mask],record['faces'][face[mask]])
        normals=normalize(np.cross(record['faces'][:,1]-record['faces'][:,0],record['faces'][:,2]-record['faces'][:,0]))[face[mask]]
        values=np.zeros(face.shape+(4,)); values[mask,:3]=transport.diffuse(points,normals); values[mask,3]=1
        # A mirrored node's bake uses geometrical winding; UV attributes must still follow source vertex order.
        if np.linalg.det(record['transform'][:3,:3])<0: uv=uv.reshape(-1,3,2)[:,[0,2,1]].reshape(-1,2)
        filename=f'M{record["model"]}-material-{record["material"]}.rgba16f'
        maps[record['model']][str(record['material'])]=half_map(output/filename,values)
        atlas_face=np.maximum(face.reshape(-1),0); atlas_bary=bary.reshape(-1,3)
        record['glb'].install_uv(record,uv,(atlas_face,atlas_bary,face.shape))
        receiver_stats.append(dict(file=filename,width=face.shape[1],height=face.shape[0],triangles=len(record['faces']),sampledTexels=int(mask.sum())))
        print(f'Lightmap {ordinal+1}/{len(records)}: {filename} {face.shape[1]}x{face.shape[0]}',flush=True)
    model_outputs=[]
    for index,(glb,entry) in enumerate(models):
        if not entry.get('lightmap',True): continue
        name=entry.get('name',f'Model{index}')
        if not name or Path(name).name!=name or '/' in name or '\\' in name: raise ValueError('Invalid model output name')
        filename=name+'-Lightmapped.glb'; glb.save(output/filename)
        write_json(output/(name+'.lightmaps'),dict(version=1,encoding='diffuse-irradiance-over-pi',modelFile=filename,modelSHA256=digest(output/filename),materials=maps[index]))
        model_outputs.append(dict(source=entry['file'],model=filename,lightmaps=name+'.lightmaps'))
    probes=bake_probes(transport,config['probes'],output,probe_samples) if 'probes' in config else None
    tool_inputs={str(p.resolve()):digest(p) for p in Path(__file__).parent.glob('gi_*.py')}
    for p in [Path(__file__),Path(__file__).with_name('gi_trace.cpp')]: tool_inputs[str(p.resolve())]=digest(p)
    files={p.name:digest(p) for p in output.iterdir() if p.is_file() and p.name!='Bake.json'}
    report=dict(version=1,inputs=inputs,tools=tool_inputs,outputs=files,models=model_outputs,lightmaps=receiver_stats,probes=probes,
        seconds=time.monotonic()-started,samples=samples,probeSamples=probe_samples,bounces=bounces,texelsPerMeter=density,
        convention='Sky visibility plus static diffuse bounces, irradiance/pi. Runtime sun/point/spot analytic direct excluded.',
        limitations=['Static opaque geometry only; alpha materials excluded','Non-directional surface maps; L2 spatial SH',
            'Source outgoing radiance sampled at triangle centres; no specular or transmission bounce',
            'Probe moments are finite angular resolution; no adaptive refinement or runtime relocation',
            'Rebake after geometry/material/static-light/sky changes; runtime moved flashlights rely on SSGI'])
    write_json(output/'Bake.json',report); return report

def verify(path):
    path=Path(path); report=json.loads(path.read_text()); missing=[]
    for kind in ['inputs','tools']:
        for name,expected in report[kind].items():
            if not Path(name).is_file() or digest(name)!=expected: missing.append(name)
    for name,expected in report['outputs'].items():
        p=path.parent/name
        if not p.is_file() or digest(p)!=expected: missing.append(str(p))
    if missing: raise ValueError('Stale or modified GI bake: '+', '.join(missing))
    print('GI bake fingerprints verified',flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('scene',type=Path,nargs='?'); parser.add_argument('--output',type=Path)
    parser.add_argument('--texels-per-meter',type=float,default=4); parser.add_argument('--samples',type=int,default=64)
    parser.add_argument('--probe-samples',type=int,default=512); parser.add_argument('--bounces',type=int,default=2)
    parser.add_argument('--verify',type=Path)
    args=parser.parse_args()
    if args.verify: verify(args.verify)
    else:
        if not args.scene or not args.output or not 1<=args.texels_per_meter<=32 or not 8<=args.samples<=1024 or not 64<=args.probe_samples<=4096 or not 1<=args.bounces<=4:
            parser.error('Require scene/output; density 1..32, samples 8..1024, probes 64..4096, bounces 1..4')
        bake(args.scene,args.output,args.texels_per_meter,args.samples,args.bounces,args.probe_samples)
