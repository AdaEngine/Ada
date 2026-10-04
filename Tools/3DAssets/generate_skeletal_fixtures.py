"""Generate local, redistributable glTF fixtures with Blender's actual GLB exporter.

Run: /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python Tools/3DAssets/generate_skeletal_fixtures.py
"""
from pathlib import Path
import math
import bpy
from mathutils import Vector

OUTPUT = Path(__file__).resolve().parents[2] / "Tests/AdaAssetsTests/Fixtures"
OUTPUT.mkdir(parents=True, exist_ok=True)


def rigged_mesh(name, bones, vertices, faces, influences, clips):
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action)
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    material = bpy.data.materials.new("FixtureBlue")
    material.diffuse_color = (0.08, 0.35, 0.65, 1)
    mesh.materials.append(material)
    armature = bpy.data.armatures.new(name + "Skeleton")
    rig = bpy.data.objects.new(name + "Rig", armature)
    bpy.context.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    rig.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    for bone_name, head, tail, parent in bones:
        bone = armature.edit_bones.new(bone_name)
        bone.head = head
        bone.tail = tail
        if parent:
            bone.parent = armature.edit_bones[parent]
    bpy.ops.object.mode_set(mode="OBJECT")
    for bone_name, _, _, _ in bones:
        group = obj.vertex_groups.new(name=bone_name)
        for vertex, weights in enumerate(influences):
            if weights.get(bone_name, 0) > 0:
                group.add([vertex], weights[bone_name], "REPLACE")
    modifier = obj.modifiers.new("Skin", "ARMATURE")
    modifier.object = rig
    rig.animation_data_create()
    for clip_name, amplitude in clips:
        action = bpy.data.actions.new(clip_name)
        action.use_fake_user = True
        rig.animation_data.action = action
        for frame, phase in ((1, 0), (13, 1), (25, 0)):
            for bone in rig.pose.bones:
                bone.rotation_mode = "XYZ"
                sign = -1 if bone.name.endswith("R") else 1
                bone.rotation_euler = (sign * phase * amplitude if "Leg" in bone.name or "Arm" in bone.name or bone.name == "Tip" else 0, 0, 0)
                bone.keyframe_insert("rotation_euler", frame=frame, group=bone.name)
    bpy.context.scene.render.fps = 24
    bpy.context.scene.frame_start = 1
    bpy.context.scene.frame_end = 25
    bpy.context.scene.frame_set(1)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(
        filepath=str(OUTPUT / (name + ".glb")), export_format="GLB",
        export_skins=True, export_animations=True, export_animation_mode="ACTIONS",
        export_all_influences=False, export_force_sampling=True,
    )


vertices = [(x, 0, z) for z in (0, 0.5, 1, 1.5, 2) for x in (-0.2, 0.2)]
faces = [(row * 2, row * 2 + 1, row * 2 + 3, row * 2 + 2) for row in range(4)]
influences = [{"Root": 1 - min(1, max(0, z - 0.5)), "Tip": min(1, max(0, z - 0.5))} for _, _, z in vertices]
rigged_mesh("TwoBoneRibbon", [("Root", (0, 0, 0), (0, 0, 1), None), ("Tip", (0, 0, 1), (0, 0, 2), "Root")], vertices, faces, influences, [("Bend", 0.5)])

bones = [
    ("Root", (0, 0, 0.9), (0, 0, 1.1), None),
    ("Spine", (0, 0, 1.1), (0, 0, 1.5), "Root"),
    ("Head", (0, 0, 1.5), (0, 0, 1.85), "Spine"),
]
for suffix, sign in (("L", 1), ("R", -1)):
    bones += [
        ("Arm" + suffix, (sign * 0.15, 0, 1.45), (sign * 0.55, 0, 1.45), "Spine"),
        ("ForeArm" + suffix, (sign * 0.55, 0, 1.45), (sign * 0.9, 0, 1.45), "Arm" + suffix),
        ("Leg" + suffix, (sign * 0.12, 0, 0.95), (sign * 0.12, 0, 0.5), "Root"),
        ("LowerLeg" + suffix, (sign * 0.12, 0, 0.5), (sign * 0.12, 0, 0.08), "Leg" + suffix),
    ]
vertices, faces, influences = [], [], []
for bone_name, head, tail, _ in bones:
    axis = (Vector(tail) - Vector(head)).normalized()
    side = axis.cross(Vector((0, 1, 0))).normalized()
    other = axis.cross(side).normalized()
    radius = 0.14 if bone_name in ("Root", "Spine", "Head") else 0.07
    start = len(vertices)
    for point in (head, tail):
        for corner in range(8):
            angle = corner * math.tau / 8
            vertices.append(tuple(Vector(point) + radius * (math.cos(angle) * side + math.sin(angle) * other)))
            influences.append({bone_name: 1})
    faces.extend([(start + i, start + (i + 1) % 8, start + (i + 1) % 8 + 8, start + i + 8) for i in range(8)])
    faces.extend([tuple(start + i for i in reversed(range(8))), tuple(start + 8 + i for i in range(8))])
rigged_mesh("TestHumanoid", bones, vertices, faces, influences, [("Idle", 0.03), ("Walk", 0.35), ("Run", 0.65)])
