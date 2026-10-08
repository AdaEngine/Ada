"""Prepare CC0 RobotExpressive without resampling its FBX-converted bind matrices.
Blender is the authoring/inspection tool; this lossless GLB profile conversion only
selects skeletal clips, disables unsupported morph data, and sets PBR factors.
"""
from pathlib import Path
import json, struct, hashlib, copy
ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Demos/SkeletalGarden/SourceAssets/RobotExpressive.glb'
OUTPUT = ROOT / 'Demos/SkeletalGarden/Assets/GardenRobot.glb'
raw = SOURCE.read_bytes()
length, kind = struct.unpack_from('<II', raw, 12)
assert kind == 0x4E4F534A
source = json.loads(raw[20:20+length])
bin_chunk = raw[20+length:]
binary = bytearray(bin_chunk[8:])
jump_source = copy.deepcopy(next(a for a in source["animations"] if a["name"] == "Jump"))
clips = []
for clip in source['animations']:
    if clip['name'] not in ('Idle','Walking','Running'): continue
    clip['name'] = {'Walking':'Walk','Running':'Run'}.get(clip['name'],clip['name'])
    clip['channels'] = [c for c in clip['channels'] if c['target']['path'] != 'weights']
    used = sorted({c['sampler'] for c in clip['channels']})
    indices = {old:new for new,old in enumerate(used)}
    clip['samplers'] = [clip['samplers'][i] for i in used]
    for channel in clip['channels']: channel['sampler'] = indices[channel['sampler']]
    clips.append(clip)
source['animations'] = clips
for node in source['nodes']: node.pop('weights',None)
for mesh in source['meshes']:
    mesh.pop('weights',None)
    for primitive in mesh['primitives']: primitive.pop('targets',None)
# FBX2GLTF produced a few float weights slightly above one and unnormalized sums.
# Normalize the authoring data once; vertex positions and all bind matrices stay byte-identical.
weights = {primitive['attributes']['WEIGHTS_0'] for mesh in source['meshes'] for primitive in mesh['primitives'] if 'WEIGHTS_0' in primitive['attributes']}
for index in weights:
    accessor = source['accessors'][index]
    assert accessor['componentType'] == 5126 and accessor['type'] == 'VEC4'
    view = source['bufferViews'][accessor['bufferView']]
    start = view.get('byteOffset',0) + accessor.get('byteOffset',0)
    stride = view.get('byteStride',16)
    for vertex in range(accessor['count']):
        offset = start + vertex * stride
        values = [max(0,min(1,x)) for x in struct.unpack_from('<4f',binary,offset)]
        total = sum(values)
        assert total > 0
        struct.pack_into('<4f',binary,offset,*(x/total for x in values))
    accessor.pop('min',None); accessor.pop('max',None)
# Derive rotation-only in-place air/landing clips. Physics owns all root displacement.
def read_float_accessor(index):
    accessor = source['accessors'][index]
    view = source['bufferViews'][accessor['bufferView']]
    width = {'SCALAR':1, 'VEC3':3, 'VEC4':4}[accessor['type']]
    start = view.get('byteOffset',0) + accessor.get('byteOffset',0)
    stride = view.get('byteStride',width*4)
    return [struct.unpack_from('<'+'f'*width,binary,start+i*stride) for i in range(accessor['count'])]

def append_accessor(values, kind):
    binary.extend(b'\0' * (-len(binary)%4))
    offset = len(binary)
    for value in values: binary.extend(struct.pack('<'+'f'*len(value),*value))
    view_index = len(source['bufferViews'])
    source['bufferViews'].append({'buffer':0,'byteOffset':offset,'byteLength':len(binary)-offset})
    accessor = {'bufferView':view_index,'componentType':5126,'count':len(values),'type':kind}
    if kind == 'SCALAR': accessor.update(min=[min(v[0] for v in values)],max=[max(v[0] for v in values)])
    index = len(source['accessors']); source['accessors'].append(accessor)
    return index

for name, first, last in [('Jump',2,8),('Fall',8,8),('Land',10,16)]:
    channels=[];samplers=[]
    for channel in jump_source['channels']:
        if channel['target']['path'] != 'rotation': continue
        sampler=jump_source['samplers'][channel['sampler']]
        times=read_float_accessor(sampler['input']);values=read_float_accessor(sampler['output'])
        selected=values[first:last+1]
        if first==last:
            selected=selected*2;local_times=[(0.0,),(0.2,)]
        else: local_times=[(t[0]-times[first][0],) for t in times[first:last+1]]
        input_index=append_accessor(local_times,'SCALAR');output_index=append_accessor(selected,'VEC4')
        channels.append({'sampler':len(samplers),'target':copy.deepcopy(channel['target'])})
        samplers.append({'input':input_index,'output':output_index,'interpolation':'LINEAR'})
    clips.append({'name':name,'channels':channels,'samplers':samplers})
source['buffers'][0]['byteLength']=len(binary)
bin_chunk = struct.pack('<II',len(binary),0x004E4942) + binary
for material in source['materials']:
    pbr = material['pbrMetallicRoughness']
    pbr['metallicFactor'] = 0.65 if material['name']=='Grey' else 0.2
    pbr['roughnessFactor'] = 0.35 if material['name']=='Grey' else 0.65
encoded = json.dumps(source,separators=(',',':')).encode()
encoded += b' '*((-len(encoded))%4)
OUTPUT.write_bytes(b'glTF'+struct.pack('<II',2,20+len(encoded)+len(bin_chunk))+struct.pack('<II',len(encoded),kind)+encoded+bin_chunk)
print('Robot profile prepared: original nodes, skins and vertex positions preserved; weights normalized;', [c['name'] for c in clips])
print('Source SHA256:',hashlib.sha256(raw).hexdigest())
