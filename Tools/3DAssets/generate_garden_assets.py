"""Author six original textured PBR props and bake a deterministic HDR studio IBL."""
from pathlib import Path
import sys, json, struct, math
import bpy
import numpy as np
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'Demos/SkeletalGarden/Assets'
sys.path.insert(0, str(Path(__file__).resolve().parent))
import bake_ibl
bake_ibl.self_test()
preview = bake_ibl.bake(OUT)
N = 64
u, v = np.meshgrid(np.linspace(0,1,N),np.linspace(0,1,N))

def image(name, rgb, alpha=None, linear=False):
    rgba = np.ones(rgb.shape[:-1]+(4,),dtype=np.float32)
    rgba[...,:3]=rgb
    if alpha is not None: rgba[...,3]=alpha
    value=bpy.data.images.new(name,width=rgb.shape[1],height=rgb.shape[0],alpha=True)
    if linear: value.colorspace_settings.name='Non-Color'
    value.pixels=rgba.reshape(-1).tolist()
    value.pack()
    return value

wood=np.stack([0.28+0.11*np.sin(u*54+np.sin(v*12)*0.5),0.12+0.04*np.sin(u*54),0.05+0.025*np.sin(u*54)],axis=-1)
stone=np.stack([0.35+0.012*np.sin(u*12)*np.cos(v*10),0.38+0.012*np.sin(u*12)*np.cos(v*10),0.39+0.012*np.sin(u*12)*np.cos(v*10)],axis=-1)
leaf=np.stack([0.06+0*u,0.24+0.1*np.cos((u-0.5)*3),0.035+0*u],axis=-1)
alpha=(((u-0.5)/0.43)**2+((v-0.5)/0.49)**2<1).astype(float)
normal=np.stack([0.5+0.12*np.cos(u*54),0.5+0*u,0.99+0*u],axis=-1)
orm=np.stack([0.7+0.25*np.cos(u*8)**2,0.75+0*u,0*u],axis=-1)
textures={
 'Wood':(image('Wood Base',wood),image('Wood ORM',orm,linear=True),image('Wood Normal',normal,linear=True)),
 'Stone':(image('Stone Base',stone),image('Stone ORM',orm,linear=True),image('Stone Normal',normal*0.35+np.array([0.325,0.325,0.6435]),linear=True)),
 'Leaf':(image('Leaf Base',leaf,alpha),None,None),
}

def material(name,color=(1,1,1,1),metallic=0,roughness=0.8,textures=None,emission=None):
    value=bpy.data.materials.new(name);value.use_nodes=True;value.use_backface_culling=True
    nodes=value.node_tree.nodes;links=value.node_tree.links
    shader=nodes.get('Principled BSDF');shader.inputs['Base Color'].default_value=color
    shader.inputs['Metallic'].default_value=metallic;shader.inputs['Roughness'].default_value=roughness
    if textures:
        base,orm,norm=textures
        tex=nodes.new('ShaderNodeTexImage');tex.image=base;links.new(tex.outputs['Color'],shader.inputs['Base Color'])
        if name=='Leaf Mask':
            links.new(tex.outputs['Alpha'],shader.inputs['Alpha']);value.surface_render_method='DITHERED';value.use_backface_culling=False
        if orm:
            maps=nodes.new('ShaderNodeTexImage');maps.image=orm
            split=nodes.new('ShaderNodeSeparateColor');links.new(maps.outputs['Color'],split.inputs['Color'])
            links.new(split.outputs['Green'],shader.inputs['Roughness']);links.new(split.outputs['Blue'],shader.inputs['Metallic'])
            tree=bpy.data.node_groups.new('glTF Material Output','ShaderNodeTree')
            tree.interface.new_socket(name='Occlusion',in_out='INPUT',socket_type='NodeSocketFloat')
            group=nodes.new('ShaderNodeGroup');group.node_tree=tree;links.new(split.outputs['Red'],group.inputs['Occlusion'])
        if norm:
            maps=nodes.new('ShaderNodeTexImage');maps.image=norm
            normal=nodes.new('ShaderNodeNormalMap');normal.inputs['Strength'].default_value=0.6
            links.new(maps.outputs['Color'],normal.inputs['Color']);links.new(normal.outputs['Normal'],shader.inputs['Normal'])
    if emission:
        shader.inputs['Emission Color'].default_value=(*emission,1);shader.inputs['Emission Strength'].default_value=2.5
    return value

woodmat=material('Wood PBR',textures=textures['Wood'])
stonemat=material('Stone PBR',textures=textures['Stone'])
leafmat=material('Leaf Mask',textures=textures['Leaf'])
metalmat=material('Brushed Metal',(0.3,0.36,0.42,1),0.9,0.28)
potmat=material('Terracotta',(0.42,0.1,0.045,1),0,0.75)
emissionmat=material('Lantern Emission',(0.95,0.5,0.06,1),0,0.5,emission=(0.8,0.24,0.025))

def clear():
    bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)

def box(name,location,scale,mat,bevel=0.03):
    bpy.ops.mesh.primitive_cube_add(size=1,location=location);obj=bpy.context.object;obj.name=name;obj.scale=scale
    bpy.ops.object.transform_apply(location=False,rotation=True,scale=True);obj.data.materials.append(mat)
    if bevel:
        mod=obj.modifiers.new('Soft Edges','BEVEL');mod.width=bevel;mod.segments=2
    return obj

def cylinder(name,location,radius,depth,mat):
    bpy.ops.mesh.primitive_cylinder_add(vertices=16,radius=radius,depth=depth,location=location)
    obj=bpy.context.object;obj.name=name;obj.data.materials.append(mat);return obj

def export(name):
    path=OUT/(name+'.glb')
    bpy.ops.export_scene.gltf(filepath=str(path),export_format='GLB',export_apply=True,export_animations=False,export_tangents=True)
    raw=path.read_bytes();length,_=struct.unpack_from('<II',raw,12);doc=json.loads(raw[20:20+length]);binchunk=raw[20+length:]
    for mat in doc.get('materials',[]):
        if mat.get('name')=='Leaf Mask':mat.update(alphaMode='MASK',alphaCutoff=0.5,doubleSided=True)
    encoded=json.dumps(doc,separators=(',',':')).encode();encoded+=b' '*((-len(encoded))%4)
    path.write_bytes(b'glTF'+struct.pack('<II',2,20+len(encoded)+len(binchunk))+struct.pack('<II',len(encoded),0x4E4F534A)+encoded+binchunk)

clear();box('Wooden Crate',(0,0,0.4),(0.85,0.85,0.8),woodmat)
for x in (-0.43,0.43):box('Crate Band',(x,0,0.4),(0.07,0.92,0.86),metalmat,0.01)
export('Crate')
clear();box('Seat',(0,0,0.55),(1.8,0.55,0.13),woodmat)
for x in (-0.65,0.65):box('Bench Leg',(x,0,0.25),(0.15,0.4,0.5),metalmat)
box('Backrest',(0,0.22,0.92),(1.8,0.12,0.55),woodmat);export('Bench')
clear();cylinder('Pot',(0,0,0.25),0.32,0.5,potmat);cylinder('Stem',(0,0,0.85),0.035,1.2,potmat)
for i in range(8):
    angle=i*math.tau/8
    bpy.ops.mesh.primitive_plane_add(size=1,location=(math.cos(angle)*0.18,math.sin(angle)*0.18,0.65+i*0.085))
    obj=bpy.context.object;obj.name='Leaf';obj.scale=(0.45,0.7,1);obj.rotation_euler=(0.9,0,angle)
    bpy.ops.object.transform_apply(location=False,rotation=True,scale=True);obj.data.materials.append(leafmat)
export('Plant')
clear();box('Stone Pedestal',(0,0,0.4),(0.7,0.7,0.8),stonemat);box('Pedestal Cap',(0,0,0.88),(0.9,0.9,0.16),stonemat);export('Pedestal')
clear();cylinder('Lantern Base',(0,0,0.08),0.25,0.16,metalmat);cylinder('Lantern Glow',(0,0,0.36),0.17,0.45,emissionmat)
for x in (-0.19,0.19):
 for y in (-0.19,0.19):box('Lantern Frame',(x,y,0.38),(0.04,0.04,0.65),metalmat,0.008)
box('Lantern Top',(0,0,0.73),(0.48,0.48,0.12),metalmat);export('Lantern')
clear();bpy.ops.mesh.primitive_plane_add(size=12);bpy.context.object.name='Courtyard';bpy.context.object.data.materials.append(stonemat)
for layer in bpy.context.object.data.uv_layers:
 for uv in layer.data:uv.uv*=3
export('Courtyard')
print('Garden asset generation complete: six PBR props and HDR IBL')
