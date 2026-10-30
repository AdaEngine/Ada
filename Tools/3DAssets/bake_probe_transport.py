"""Build static probe-ray surface paths for GPU relighting; moving lights require no rebake."""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
from gi_glb import GLB, matrix
from gi_transport import Tracer, half_map, normalize, sphere


def bake(scene, output, samples=128):
    scene=Path(scene).resolve(); output=Path(output).resolve(); output.mkdir(parents=True,exist_ok=True)
    config=json.loads(scene.read_text(encoding='utf-8')); settings=config['probes']
    counts=np.asarray(settings['counts'],int); origin=np.asarray(settings['origin'],float); spacing=np.asarray(settings['spacing'],float)
    if len(counts)!=3 or np.any(counts<2) or np.any(counts>64) or counts.prod()>4096 or counts[0]*samples>4096 or samples not in [32,64,128,256]:
        raise ValueError('Invalid transport grid budget')
    if origin.shape!=(3,) or spacing.shape!=(3,) or not np.isfinite(origin).all() or not np.isfinite(spacing).all() or np.any(spacing<.01):
        raise ValueError('Invalid transport grid placement')
    records=[]; dependencies=[scene]
    for entry in config['models']:
        path=(scene.parent/entry['file']).resolve(); dependencies.append(path)
        records.extend(GLB(path).collect(matrix(entry.get('transform',{})),False))
    faces=np.concatenate([r['faces'] for r in records]); albedo=np.concatenate([r['albedo'] for r in records])
    normals=normalize(np.cross(faces[:,1]-faces[:,0],faces[:,2]-faces[:,0])); tracer=Tracer(faces)
    nx,ny,nz=counts; shape=(ny*nz,nx*samples,4)
    positions=np.zeros(shape); normal_map=np.zeros(shape); colors=np.zeros(shape); directions=sphere(samples)
    for z in range(nz):
        for y in range(ny):
            for x in range(nx):
                position=origin+np.array([x,y,z])*spacing
                distance,hit=tracer.trace(position,directions,far=100.)
                index=np.maximum(hit,0); valid=(hit>=0)&(np.sum(normals[index]*-directions,axis=-1)>0)
                address=(z*ny+y,slice(x*samples,(x+1)*samples))
                positions[address]=np.concatenate([position+directions*distance[:,None],valid[:,None]],axis=-1)
                normal_map[address]=np.concatenate([normals[index],valid[:,None]],axis=-1)
                colors[address]=np.concatenate([np.clip(albedo[index],0,.96),valid[:,None]],axis=-1)
        print(f'Transport slice {z+1}/{nz}',flush=True)
    valid_positions=positions[positions[...,3]>.5,:3]
    lo=valid_positions.min(axis=0) if len(valid_positions) else origin
    hi=valid_positions.max(axis=0) if len(valid_positions) else origin
    bounds=dict(center=dict(zip('xyz',(lo+hi)*.5)),halfExtents=dict(zip('xyz',(hi-lo)*.5)))
    manifest=dict(version=1,encoding='fibonacci-sphere-surface-transport-v1',origin=dict(zip('xyz',origin)),spacing=dict(zip('xyz',spacing)),surfaceBounds=bounds,
        counts=counts.tolist(),samples=samples,positions=half_map(output/'Paths-position.rgba16f',positions),
        normals=half_map(output/'Paths-normal.rgba16f',normal_map),albedo=half_map(output/'Paths-albedo.rgba16f',colors))
    path=output/'Grid.proberays'; path.write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    dependencies += [Path(__file__),*Path(__file__).parent.glob('gi_*.py'),Path(__file__).with_name('gi_trace.cpp')]
    report=dict(version=1,inputs={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in dependencies},
        outputs={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in output.iterdir() if p.is_file() and p.name!='Transport.json'},
        triangles=len(faces),probes=int(counts.prod()),samples=samples)
    (output/'Transport.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    return report


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('scene',type=Path); p.add_argument('--output',type=Path,required=True)
    p.add_argument('--samples',type=int,choices=[32,64,128,256],default=128); args=p.parse_args(); bake(args.scene,args.output,args.samples)
