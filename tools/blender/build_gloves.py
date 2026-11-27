"""First-person gloves for the Pistol, from the Mixamo soldier
(art_source/mixamo/soldier.fbx, git-ignored). build_guns.bat runs this after
build_arms.py (the other guns keep arms_<lod>.glb).

Writes assets/models/arms/gloves_<lod>.glb (high / med / low):
  - only the hands and the last SLEEVE metres of the forearms (the cuff and a
    short piece of sleeve); the cut end is capped so you never look into it;
  - the sleeve's digital camo (blocky pixels up close) is replaced by a plain
    woven fabric colour; folds and seams stay in the normal map;
  - baked at 2048 px from the 4K body textures: colour 2048 / 1024 / 512 px,
    normal map 2048 / 1024 (High / Medium; Low has none);
  - High keeps every original triangle and its smooth normals, Medium and
    Low are decimated and smooth shaded;
  - the same trimmed skeleton as the arms (fp_arms.gd poses both).

    blender -b --factory-startup --python tools/blender/build_gloves.py [-- --preview <dir>]
"""

import os
import sys

import bmesh
import bpy
from mathutils import Vector

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "art_source", "mixamo", "soldier.fbx")
OUT = os.path.join(ROOT, "assets", "models", "arms")
BAKE_SIZE = 2048
SLEEVE = 0.15          # m of forearm kept behind the wrist
CUFF = 0.06            # m of glove-material parts kept behind the wrist (no straps)
GLOVE_MAT = 1          # material index of the gloves / gear texture
SLEEVE_COLOUR = (0.045, 0.05, 0.034)   # dark ranger green (linear)
# name, triangles (0 = all), colour size, normal size (0 = none)
LODS = [("high", 0, 2048, 2048), ("med", 4200, 1024, 1024), ("low", 2000, 512, 0)]

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
    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    body.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    return arm, body


def keep_gloves(arm, body):
    """Keeps the faces skinned to the forearms / hands that lie within SLEEVE
    of the wrist (along the forearm), caps the cut."""
    groups = {g.index: g.name for g in body.vertex_groups}
    axes = {}
    for side in ("Left", "Right"):
        fore = arm.data.bones[side + "ForeArm"]
        hand = arm.data.bones[side + "Hand"]
        wrist = hand.head_local.copy()
        axes[side] = (wrist, (wrist - fore.head_local).normalized())
    keep_v = []
    along = []
    for v in body.data.vertices:
        w = {"Left": 0.0, "Right": 0.0}
        for g in v.groups:
            n = groups[g.group]
            for side in w:
                if n.startswith(side + "ForeArm") or n.startswith(side + "Hand"):
                    w[side] += g.weight
        side = max(w, key=w.get)
        ok = False
        d = 0.0
        if w[side] > 0.5:
            wrist, axis = axes[side]
            d = (v.co - wrist).dot(axis)
            ok = d > -SLEEVE
        keep_v.append(ok)
        along.append(d)
    bm = bmesh.new()
    bm.from_mesh(body.data)
    # Gear on the glove material (straps, buckles) further up than the cuff goes too.
    drop = [f for f in bm.faces if not all(keep_v[v.index] for v in f.verts)
            or (f.material_index == GLOVE_MAT and min(along[v.index] for v in f.verts) < -CUFF)]
    bmesh.ops.delete(bm, geom=drop, context="FACES")
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
    # Cap the sleeve ends (the open loops furthest from the hands).
    edges = [e for e in bm.edges if e.is_boundary]
    res = bmesh.ops.holes_fill(bm, edges=edges, sides=0)
    uv = bm.loops.layers.uv.active
    for f in res["faces"]:
        f.material_index = 0  # sleeve
        f.smooth = True
        # A small planar UV island of its own (the fill has none): the bake
        # packs islands by UV size, so it would otherwise take half the atlas.
        n = f.normal if f.normal.length > 0 else Vector((0, 0, 1))
        t = n.orthogonal().normalized()
        b = n.cross(t)
        for loop in f.loops:
            p = loop.vert.co
            loop[uv].uv = (0.5 + p.dot(t) * 0.3, 0.5 + p.dot(b) * 0.3)
    bm.to_mesh(body.data)
    bm.free()
    for g in list(body.vertex_groups):
        if not is_arm_bone(g.name):
            body.vertex_groups.remove(g)
    print("GLOVES faces kept:", len(body.data.polygons), "caps:", len(res["faces"]))


def trim_skeleton(arm):
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    eb = arm.data.edit_bones
    for b in list(eb):
        if not (b.name in KEEP_BONES or is_arm_bone(b.name)):
            eb.remove(b)
    bpy.ops.object.mode_set(mode="OBJECT")


def sleeve_fabric(mat):
    """Sleeve material: plain fabric colour with a fine weave / mottling, in
    place of the digital camo texture (only used for the colour bake)."""
    nt = mat.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    for link in list(bsdf.inputs["Base Color"].links):
        nt.links.remove(link)
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 220.0
    noise.inputs["Detail"].default_value = 6.0
    big = nt.nodes.new("ShaderNodeTexNoise")
    big.inputs["Scale"].default_value = 9.0
    ramp = nt.nodes.new("ShaderNodeMapRange")
    ramp.inputs["To Min"].default_value = 0.82
    ramp.inputs["To Max"].default_value = 1.12
    mix = nt.nodes.new("ShaderNodeMath")
    mix.operation = "MULTIPLY"
    nt.links.new(noise.outputs["Fac"], mix.inputs[0])
    nt.links.new(big.outputs["Fac"], mix.inputs[1])
    nt.links.new(mix.outputs[0], ramp.inputs["Value"])
    ramp.inputs["From Min"].default_value = 0.1
    ramp.inputs["From Max"].default_value = 0.45
    tint = nt.nodes.new("ShaderNodeMix")
    tint.data_type = "RGBA"
    tint.blend_type = "MULTIPLY"
    tint.inputs["Factor"].default_value = 1.0
    tint.inputs[6].default_value = (*SLEEVE_COLOUR, 1.0)
    comb = nt.nodes.new("ShaderNodeCombineColor")
    for i in range(3):
        nt.links.new(ramp.outputs[0], comb.inputs[i])
    nt.links.new(comb.outputs[0], tint.inputs[7])
    nt.links.new(tint.outputs[2], bsdf.inputs["Base Color"])
    # The source normal map has the camo's pixel blocks embossed in it: use a
    # fine fabric bump instead.
    for link in list(bsdf.inputs["Normal"].links):
        nt.links.remove(link)
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.25
    bump.inputs["Distance"].default_value = 0.002
    nt.links.new(noise.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])


def bake(body):
    me = body.data
    old_uv = me.uv_layers.active.name
    new = me.uv_layers.new(name="GlovesUV")
    me.uv_layers.active = new
    bpy.context.view_layer.objects.active = body
    body.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.select_all(action="SELECT")
    bpy.ops.uv.pack_islands(rotate=True, margin=0.003)
    bpy.ops.object.mode_set(mode="OBJECT")
    new.active_render = True

    col = bpy.data.images.new("gloves_albedo", BAKE_SIZE, BAKE_SIZE, alpha=False)
    nrm = bpy.data.images.new("gloves_normal", BAKE_SIZE, BAKE_SIZE, alpha=False)
    nrm.colorspace_settings.name = "Non-Color"
    targets = []
    for i, mat in enumerate(me.materials):
        nt = mat.node_tree
        uvn = nt.nodes.new("ShaderNodeUVMap")
        uvn.uv_map = old_uv
        for n in nt.nodes:
            if n.type == "TEX_IMAGE":
                nt.links.new(uvn.outputs["UV"], n.inputs["Vector"])
        if i == 0:
            sleeve_fabric(mat)
            # Fabric noise in object space (the source UV would stretch it).
            tc = nt.nodes.new("ShaderNodeTexCoord")
            for n in nt.nodes:
                if n.type == "TEX_NOISE":
                    nt.links.new(tc.outputs["Object"], n.inputs["Vector"])
        t = nt.nodes.new("ShaderNodeTexImage")
        nt.nodes.active = t
        targets.append(t)
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = 4
    sc.render.bake.margin = 16
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


def gloves_material(col, nrm):
    mat = bpy.data.materials.new("gloves")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Roughness"].default_value = 0.82
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
    if size != img.size[0]:
        c.scale(size, size)
    c.name = name
    c.pack()
    return c


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    os.makedirs(OUT, exist_ok=True)
    arm, body = load()
    keep_gloves(arm, body)
    trim_skeleton(arm)
    col, nrm = bake(body)
    if "--preview" in argv:
        d = argv[argv.index("--preview") + 1]
        for img, n in ((col, "gloves_albedo.png"), (nrm, "gloves_normal.png")):
            img.filepath_raw = os.path.join(d, n)
            img.file_format = "PNG"
            img.save()
    base = os.path.join(ROOT, "art_source", "build", "gloves_baked.blend")
    os.makedirs(os.path.dirname(base), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=base)
    for lod, tris, size, nsize in LODS:
        bpy.ops.wm.open_mainfile(filepath=base)
        arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
        body = next(o for o in bpy.data.objects if o.type == "MESH")
        before = sum(len(p.vertices) - 2 for p in body.data.polygons)
        bpy.context.view_layer.objects.active = body
        if tris and tris < before:
            mod = body.modifiers.new("decimate", "DECIMATE")
            mod.decimate_type = "COLLAPSE"
            mod.ratio = tris / before
            mod.use_collapse_triangulate = True
            while body.modifiers.find("decimate") > 0:
                bpy.ops.object.modifier_move_up(modifier="decimate")
            bpy.ops.object.modifier_apply(modifier="decimate")
            # Decimation breaks the imported split normals: plain smooth ones.
            with bpy.context.temp_override(object=body):
                if body.data.has_custom_normals:
                    bpy.ops.mesh.customdata_custom_splitnormals_clear()
            for p in body.data.polygons:
                p.use_smooth = True
        after = sum(len(p.vertices) - 2 for p in body.data.polygons)
        c = scaled(bpy.data.images["gloves_albedo"], size, "gloves_%s_albedo" % lod)
        n = scaled(bpy.data.images["gloves_normal"], nsize, "gloves_%s_normal" % lod) if nsize else None
        body.data.materials.clear()
        body.data.materials.append(gloves_material(c, n))
        bpy.ops.object.select_all(action="DESELECT")
        arm.select_set(True)
        body.select_set(True)
        path = os.path.join(OUT, "gloves_%s.glb" % lod)
        bpy.ops.export_scene.gltf(
            filepath=path,
            export_format="GLB",
            use_selection=True,
            export_animations=False,
            export_skins=True,
            export_morph=False,
            export_image_format="WEBP",
            export_image_quality=90,
            export_yup=True,
        )
        print("GLOVES %s: %d -> %d tris, %d px, %.0f KB" % (
            lod, before, after, size, os.path.getsize(path) / 1024))


main()
