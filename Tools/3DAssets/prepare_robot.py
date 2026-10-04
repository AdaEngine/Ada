"""Prepare CC0 RobotExpressive without resampling its FBX-converted bind matrices.
Blender is the authoring/inspection tool; this lossless GLB profile conversion only
selects skeletal clips, disables unsupported morph data, and sets PBR factors.
"""
from pathlib import Path
import json, struct, hashlib
ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Demos/SkeletalGarden/SourceAssets/RobotExpressive.glb'
OUTPUT = ROOT / 'Demos/SkeletalGarden/Assets/GardenRobot.glb'
raw = SOURCE.read_bytes()
length, kind = struct.unpack_from('<II', raw, 12)
assert kind == 0x4E4F534A
source = json.loads(raw[20:20+length])
bin_chunk = raw[20+length:]
binary = bytearray(bin_chunk[8:])
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
