"""Original low-poly landscape props for SkeletalGarden. No external textures or downloads."""
from pathlib import Path
import math, random, json, struct
import bpy
OUT = Path(__file__).resolve().parents[2] / 'Demos/SkeletalGarden/Assets'
rng = random.Random(314159)

def material(name, color, roughness=0.9, double=False):
    mat=bpy.data.materials.new(name);mat.use_nodes=True;mat.use_backface_culling=not double
    shader=mat.node_tree.nodes.get('Principled BSDF')
    shader.inputs['Base Color'].default_value=(*color,1)
    shader.inputs['Roughness'].default_value=roughness
    return mat
bark=material('Warm Bark',(0.21,0.09,0.035))
foliage=[material('Forest Green',(0.10,0.25,0.11)),material('Leaf Light',(0.21,0.36,0.14)),material('Leaf Shadow',(0.075,0.19,0.10))]
rock=material('Weathered Rock',(0.30,0.33,0.29))
grass=material('Grass Blade',(0.29,0.43,0.17),double=True)

def clear():
    bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)

def export(name):
    bpy.ops.export_scene.gltf(filepath=str(OUT/(name+'.glb')),export_format='GLB',export_apply=True,export_animations=False)

def rewrite(path, document, binary_chunk):
    encoded=json.dumps(document,separators=(',',':')).encode()
    encoded+=b' '*((-len(encoded))%4)
    path.write_bytes(b'glTF'+struct.pack('<II',2,20+len(encoded)+len(binary_chunk))+struct.pack('<II',len(encoded),0x4E4F534A)+encoded+binary_chunk)

def read_glb(path):
    raw=path.read_bytes();length=struct.unpack_from('<I',raw,12)[0]
    return json.loads(raw[20:20+length]),raw[20+length:]

def export_lods(name):
    objects=[o for o in bpy.context.scene.objects if o.type=='MESH']
    bpy.ops.object.select_all(action='DESELECT')
    for obj in objects:obj.select_set(True)
    bpy.context.view_layer.objects.active=objects[0]
    bpy.ops.object.join();obj=bpy.context.object;obj.name=name;obj.data.name=name+' Mesh'
    bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    original=obj.data.copy()
    export(name)
    base,_=read_glb(OUT/(name+'.glb'))
    materials=base.get('materials',[]);names={m.get('name'):i for i,m in enumerate(materials)}
    for index,ratio in [(1,0.55),(2,0.27)]:
        obj.data=original.copy()
        mod=obj.modifiers.new('Static LOD Reduction','DECIMATE');mod.ratio=ratio;mod.use_collapse_triangulate=True
        bpy.ops.object.modifier_apply(modifier=mod.name)
        export(name+'LOD'+str(index))
        path=OUT/(name+'LOD'+str(index)+'.glb');doc,binary=read_glb(path)
        for mesh in doc['meshes']:
            for primitive in mesh['primitives']:
                old=primitive.get('material')
                if old is not None:primitive['material']=names[doc['materials'][old].get('name')]
        doc['materials']=materials
        rewrite(path,doc,binary)
    obj.data=original.copy()

clear()
bpy.ops.mesh.primitive_cone_add(vertices=10,radius1=0.26,radius2=0.14,depth=2.9,location=(0,0,1.45))
bpy.context.object.name='Tree Trunk';bpy.context.object.data.materials.append(bark)
for i,(position,scale) in enumerate([((0,0,3.3),(1.45,1.2,1.45)),((0.6,0.2,3.0),(1.05,1.0,1.1)),((-0.65,-0.2,3.0),(1.05,0.9,1.05))]):
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1,radius=1,location=position)
    obj=bpy.context.object;obj.name='Tree Canopy';obj.scale=scale
    bpy.ops.object.transform_apply(location=False,rotation=True,scale=True)
    for mat in foliage:obj.data.materials.append(mat)
    for face in obj.data.polygons:face.material_index=rng.randrange(3)
export_lods('Tree')
clear();bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=2,radius=1,location=(0,0,0.55))
obj=bpy.context.object;obj.name='Rock';obj.scale=(0.95,0.8,0.7)
bpy.ops.object.transform_apply(location=False,rotation=True,scale=True)
for vertex in obj.data.vertices:
    vertex.co*=rng.uniform(0.87,1.09)
    vertex.co.z=max(vertex.co.z,-0.55)
obj.data.materials.append(rock);export_lods('Rock')
clear();vertices=[];faces=[]
for i in range(7):
    angle=i*math.tau/7;width=0.075;height=rng.uniform(0.25,0.48)
    x=math.cos(angle)*0.13;y=math.sin(angle)*0.13
    dx=math.cos(angle+math.pi/2)*width;dy=math.sin(angle+math.pi/2)*width
    offset=len(vertices);vertices.extend([(x-dx,y-dy,0),(x+dx,y+dy,0),(x*1.45,y*1.45,height)])
    faces.append((offset,offset+1,offset+2))
mesh=bpy.data.meshes.new('Grass Mesh');mesh.from_pydata(vertices,[],faces);mesh.update()
obj=bpy.data.objects.new('Grass Tuft',mesh);bpy.context.collection.objects.link(obj);obj.data.materials.append(grass)
export('Grass')
print('Landscape props exported: Tree/Rock LOD0/1/2, Grass; transforms and material indices preserved')
