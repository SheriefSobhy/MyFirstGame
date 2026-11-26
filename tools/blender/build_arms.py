"""First-person arms from the Mixamo soldier (art_source/mixamo/soldier.fbx,
git-ignored). build_guns.bat runs this.

Writes assets/models/arms/arms_<lod>.glb (high / med / low):
  - only the faces skinned to the arms and hands (upper arm to fingertips);
  - the skeleton trimmed to the spine, shoulders, arms and fingers, bone
    names without the "mixamorig:" prefix (Godot poses it with IK, fp_arms.gd);
  - the arm UV islands re-packed into their own square and baked from the
    4K body textures: colour (1024 / 512 / 256 px) and normal map (half
    that, High and Medium only), so the arms get the whole texture;
  - decimated to LODS triangles.

    blender -b --factory-startup --python tools/blender/build_arms.py [-- --preview <dir>]
"""

import math
import os
import sys

import bmesh
import bpy

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "art_source", "mixamo", "soldier.fbx")
OUT = os.path.join(ROOT, "assets", "models", "arms")
BAKE_SIZE = 1024
# name, triangles, colour size, normal map
LODS = [("high", 6000, 1024, True), ("med", 3000, 512, True), ("low", 1500, 256, False)]

ARM_BONES = ("LeftArm", "LeftForeArm", "LeftHand", "RightArm", "RightForeArm", "RightHand")
KEEP_BONES = ("Hips", "Spine", "Spine1", "Spine2", "LeftShoulder", "RightShoulder") + ARM_BONES


def strip(name):
    return name.split(":", 1)[1] if ":" in name else name


def is_arm_bone(name):
    return any(name.startswith(b) for b in ARM_BONES)


def load():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.fbx(filepath=SRC)
    arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
    body = next(o for o in bpy.data.objects if o.type == "MESH")
    for b in arm.data.bones:
        b.name = strip(b.name)
    for g in body.vertex_groups:
        g.name = strip(g.name)
    # The FBX armature comes in at 0.01 scale with bones in centimetres:
    # bake that in, so the exported skeleton is in metres with no transform.
    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    body.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    return arm, body


def keep_arms(body):
    """Deletes every face that isn't mostly skinned to the arm bones."""
    arm_groups = {g.index for g in body.vertex_groups if is_arm_bone(g.name)}
    on_arm = []
    for v in body.data.vertices:
        w = sum(g.weight for g in v.groups if g.group in arm_groups)
        on_arm.append(w > 0.5)
    bm = bmesh.new()
    bm.from_mesh(body.data)
    drop = [f for f in bm.faces if not all(on_arm[v.index] for v in f.verts)]
    bmesh.ops.delete(bm, geom=drop, context="FACES")
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
    bm.to_mesh(body.data)
    bm.free()
    for g in list(body.vertex_groups):
        if not is_arm_bone(g.name):
            body.vertex_groups.remove(g)


def trim_skeleton(arm):
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    eb = arm.data.edit_bones
    for b in list(eb):
        if not (b.name in KEEP_BONES or is_arm_bone(b.name)):
            eb.remove(b)
    bpy.ops.object.mode_set(mode="OBJECT")


def bake(body):
    """New UV with the arm islands packed into 0..1; bakes colour and normal
    from the original materials into it. Returns (colour, normal) images."""
    me = body.data
    old_uv = me.uv_layers.active.name
    new = me.uv_layers.new(name="ArmsUV")
    me.uv_layers.active = new
    bpy.context.view_layer.objects.active = body
    body.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.select_all(action="SELECT")
    bpy.ops.uv.pack_islands(rotate=True, margin=0.004)
    bpy.ops.object.mode_set(mode="OBJECT")
    new.active_render = True

    col = bpy.data.images.new("arms_albedo", BAKE_SIZE, BAKE_SIZE, alpha=False)
    nrm = bpy.data.images.new("arms_normal", BAKE_SIZE, BAKE_SIZE, alpha=False)
    nrm.colorspace_settings.name = "Non-Color"
    targets = []
    for mat in me.materials:
        nt = mat.node_tree
        # Sample the source textures with the original UV.
        uvn = nt.nodes.new("ShaderNodeUVMap")
        uvn.uv_map = old_uv
        for n in nt.nodes:
            if n.type == "TEX_IMAGE":
                nt.links.new(uvn.outputs["UV"], n.inputs["Vector"])
        t = nt.nodes.new("ShaderNodeTexImage")
        nt.nodes.active = t
        targets.append(t)
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = 4
    sc.render.bake.margin = 8
    bpy.ops.object.select_all(action="DESELECT")
    body.select_set(True)
    bpy.context.view_layer.objects.active = body
    for img, kind in ((col, "DIFFUSE"), (nrm, "NORMAL")):
        for t in targets:
            t.image = img
        if kind == "DIFFUSE":
            bpy.ops.object.bake(type="DIFFUSE", pass_filter={"COLOR"}, use_clear=True)
        else:
            bpy.ops.object.bake(type="NORMAL", normal_space="TANGENT", use_clear=True)
        img.pack()
        img.use_fake_user = True
    me.uv_layers.remove(me.uv_layers[old_uv])
    return col, nrm


def arms_material(col, nrm):
    mat = bpy.data.materials.new("arms")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Roughness"].default_value = 0.75
    bsdf.inputs["Metallic"].default_value = 0.0
    tc = nt.nodes.new("ShaderNodeTexImage")
    tc.image = col
    nt.links.new(tc.outputs["Color"], bsdf.inputs["Base Color"])
    if nrm:
        tn = nt.nodes.new("ShaderNodeTexImage")
        tn.image = nrm
        nm = nt.nodes.new("ShaderNodeNormalMap")
        nt.links.new(tn.outputs["Color"], nm.inputs["Color"])
        nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
    return mat


def scaled(img, size, name):
    c = img.copy()
    c.scale(size, size)
    c.name = name
    c.pack()
    return c


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    os.makedirs(OUT, exist_ok=True)
    arm, body = load()
    keep_arms(body)
    trim_skeleton(arm)
    col, nrm = bake(body)
    if "--preview" in argv:
        d = argv[argv.index("--preview") + 1]
        col.filepath_raw = os.path.join(d, "arms_albedo.png")
        col.file_format = "PNG"
        col.save()
        nrm.filepath_raw = os.path.join(d, "arms_normal.png")
        nrm.file_format = "PNG"
        nrm.save()
    # Save the baked state, then make each LOD from it.
    base = os.path.join(ROOT, "art_source", "build", "arms_baked.blend")
    os.makedirs(os.path.dirname(base), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=base)
    for lod, tris, size, use_normal in LODS:
        bpy.ops.wm.open_mainfile(filepath=base)
        arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
        body = next(o for o in bpy.data.objects if o.type == "MESH")
        before = sum(len(p.vertices) - 2 for p in body.data.polygons)
        bpy.context.view_layer.objects.active = body
        ratio = tris / before
        if ratio < 0.999:
            mod = body.modifiers.new("decimate", "DECIMATE")
            mod.decimate_type = "COLLAPSE"
            mod.ratio = ratio
            mod.use_collapse_triangulate = True
            # Keep the armature modifier last.
            while body.modifiers.find("decimate") > 0:
                bpy.ops.object.modifier_move_up(modifier="decimate")
            bpy.ops.object.modifier_apply(modifier="decimate")
        after = sum(len(p.vertices) - 2 for p in body.data.polygons)
        c = scaled(bpy.data.images["arms_albedo"], size, "arms_%s_albedo" % lod)
        n = scaled(bpy.data.images["arms_normal"], size // 2, "arms_%s_normal" % lod) if use_normal else None
        body.data.materials.clear()
        body.data.materials.append(arms_material(c, n))
        bpy.ops.object.select_all(action="DESELECT")
        arm.select_set(True)
        body.select_set(True)
        path = os.path.join(OUT, "arms_%s.glb" % lod)
        bpy.ops.export_scene.gltf(
            filepath=path,
            export_format="GLB",
            use_selection=True,
            export_animations=False,
            export_skins=True,
            export_morph=False,
            export_image_format="WEBP",
            export_image_quality=88,
            export_yup=True,
        )
        print("ARMS %s: %d -> %d tris, %d px, %.0f KB, %d bones" % (
            lod, before, after, size, os.path.getsize(path) / 1024, len(arm.data.bones)))


main()
