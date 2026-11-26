"""First-person gun models from the Sketchfab (CC BY 4.0) zips in
art_source/sketchfab/ (git-ignored). build_guns.bat runs this, then Godot.

For every gun and every detail level it writes assets/models/guns/<id>_<lod>.glb:
  - barrel along +X, top up (+Y in glTF), real size in metres, origin where
    the right hand holds the grip;
  - moving parts (magazine, slide, bolt, cylinder, cover...) as separate
    meshes named after the part (see PARTS), each with its origin at its own
    centre, so player.gd can animate them; everything else is "body";
  - decimated to LODS triangles; textures scaled to 1024 / 512 / 256 px WebP
    (Low keeps the colour map only).

    blender -b --factory-startup --python tools/blender/build_guns.py [-- <id> ...] [--preview <dir>]

--preview renders a side view of each High model (with a 5 cm grid and the
part outlines) into <dir>, for checking the orientation and grip point.
"""

import math
import os
import sys
import zipfile

import bmesh
import bpy
import mathutils
import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "art_source", "sketchfab")
WORK = os.path.join(ROOT, "art_source", "build", "guns")
OUT = os.path.join(ROOT, "assets", "models", "guns")

# name, share of the High triangle target, texture size
LODS = [("high", 1.0, 1024), ("med", 0.5, 512), ("low", 0.25, 256)]

# id: zip         source archive in art_source/sketchfab/
#     turn        degrees about the up axis that point the barrel at +X
#     length      real overall length (m)
#     grip        (x, z) of the right-hand grip in the oriented model before
#                 moving the origin there, as fractions of the bounding box
#     tris        High triangle target
#     drop        objects to delete (name prefixes)
#     parts       part -> object name prefixes (separate meshes in the source)
#     bone_parts  part -> bones (skinned sources: each face goes to the part
#                 of the bone that moves most of its vertices)
#     flat        no textures: material colours only (metal = dark parts)
GUNS = {
    "pistol": {
        "zip": "pistol.zip", "turn": 90, "length": 0.20, "grip": (0.17, 0.30), "shift": (0.008, 0.012), "tris": 3000,
        "parts": {"slide": ["slide"], "mag": ["mag"], "trigger": ["trigger"]},
    },
    "rifle": {
        "zip": "low_poly_m4_rifle.zip", "turn": -90, "length": 0.84, "grip": (0.30, 0.30), "shift": (-0.008, -0.006), "tris": 6000,
        "flat": True, "drop": ["Cylinder.003"],  # its optic is solid: the game adds a see-through one
        "islands": {"mag": {"box": (0.088, 0.218, -0.094, 0.016), "below": -0.05}},
    },
    "ak": {
        "zip": "low-poly_akm.zip", "turn": 0, "length": 0.88, "grip": (0.32, 0.35), "shift": (-0.005, 0.035), "tris": 6000,
        "drop": ["Icosphere"], "flat": True,
        "bone_parts": {"mag": ["mag_02", "bullets_04", "bullet_03"], "bolt": ["bolt_01"]},
    },
    "smg": {
        "zip": "low-poly_hk416.zip", "turn": 0, "length": 0.80, "grip": (0.34, 0.35), "shift": (-0.028, 0.003), "tris": 6000,
        "drop": ["Icosphere"], "flat": True,
        "bone_parts": {"mag": ["mag_03", "bullets_05"], "bolt": ["bolt_07"], "charger": ["charginghandle_06"]},
    },
    "shotgun": {
        "zip": "low_poly_shotgun.zip", "turn": 90, "length": 1.0, "grip": (0.25, 0.35), "shift": (0.038, 0.042), "tris": 2300,
        "islands": {"pump": {"box": (0.452, 0.652, -0.052, 0.028)}},
    },
    "sniper": {
        "zip": "sniper.zip", "turn": 90, "length": 1.15, "grip": (0.32, 0.35), "shift": (-0.074, -0.036), "tris": 7000,
        "drop": ["bullet"],
        "parts": {"bolt": ["bolt", "boltrear"], "mag": ["clip"], "trigger": ["trigger"]},
        "specgloss": True,
    },
    "lmg": {
        "zip": "lmg.zip", "turn": 90, "length": 1.04, "grip": (0.33, 0.35), "shift": (-0.016, -0.016), "tris": 8000,
        "parts": {"mag": ["mag", "bulletholder", "bullet"], "cover": ["cover", "loaderlid"], "bolt": ["bolt"],
                  "trigger": ["trigger"]},
    },
    "revolver": {
        "zip": "revolver.zip", "turn": 180, "length": 0.29, "grip": (0.17, 0.30), "shift": (-0.004, 0.022), "tris": 7000,
        "drop": ["Light", "AIM", "Bullet2"],
        "parts": {"cylinder": ["Revolver_low.003"]},
    },
}


def tri_count(objs):
    return sum(len(p.vertices) - 2 for o in objs for p in o.data.polygons)


def extract(gid, cfg):
    dst = os.path.join(WORK, gid)
    gltf = os.path.join(dst, "scene.gltf")
    zpath = os.path.join(SRC, cfg["zip"])
    if not os.path.exists(gltf) or os.path.getmtime(gltf) < os.path.getmtime(zpath):
        os.makedirs(dst, exist_ok=True)
        with zipfile.ZipFile(zpath) as z:
            z.extractall(dst)
    return gltf


def select_only(objs):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]


def bake_to_static():
    """Applies armatures and parents, so every mesh is a plain mesh in world space."""
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    for o in meshes:
        select_only([o])
        for m in list(o.modifiers):
            if m.type == "ARMATURE":
                bpy.ops.object.modifier_apply(modifier=m.name)
        bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
    for o in list(bpy.data.objects):
        if o.type != "MESH":
            bpy.data.objects.remove(o)
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    for o in meshes:
        if o.data.users > 1:
            o.data = o.data.copy()
        if o.data.shape_keys:
            select_only([o])
            o.shape_key_clear()
    select_only(meshes)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    return meshes


def matches(name, prefixes):
    return any(name.startswith(p) for p in prefixes)


def split_by_bones(o, bone_parts):
    """Faces of a skinned mesh -> one object per part (by dominant bone)."""
    group_part = {}
    for g in o.vertex_groups:
        for part, bones in bone_parts.items():
            if g.name in bones:
                group_part[g.index] = part
    vpart = []
    for v in o.data.vertices:
        w = {}
        for g in v.groups:
            p = group_part.get(g.group, "body")
            w[p] = w.get(p, 0.0) + g.weight
        vpart.append(max(w, key=w.get) if w else "body")
    fparts = {}
    for f in o.data.polygons:
        votes = {}
        for vi in f.vertices:
            votes[vpart[vi]] = votes.get(vpart[vi], 0) + 1
        fparts.setdefault(max(votes, key=votes.get), []).append(f.index)
    out = []
    for part, faces in fparts.items():
        if len(fparts) == 1:
            o["part"] = part
            return [o]
        c = o.copy()
        c.data = o.data.copy()
        bpy.context.collection.objects.link(c)
        keep = set(faces)
        bm = bmesh.new()
        bm.from_mesh(c.data)
        bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.index not in keep], context="FACES")
        bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
        bm.to_mesh(c.data)
        bm.free()
        c["part"] = part
        out.append(c)
    bpy.data.objects.remove(o)
    return out


def split_islands(objs, regions):
    """Moves loose islands of the body into parts: an island goes to part P
    if its bounding-box centre is inside regions[P]["box"] = (x0, x1, z0, z1)
    and its lowest point is under regions[P].get("below", +inf)."""
    out = []
    for o in objs:
        if o["part"] != "body":
            out.append(o)
            continue
        bm = bmesh.new()
        bm.from_mesh(o.data)
        bm.verts.ensure_lookup_table()
        seen = set()
        face_part = {}
        for f in bm.faces:
            if f.index in seen:
                continue
            # Flood fill one island.
            stack = [f]
            island = []
            seen.add(f.index)
            while stack:
                g = stack.pop()
                island.append(g)
                for e in g.edges:
                    for h in e.link_faces:
                        if h.index not in seen:
                            seen.add(h.index)
                            stack.append(h)
            pts = [v.co for g in island for v in g.verts]
            cx = (min(p.x for p in pts) + max(p.x for p in pts)) / 2
            cz = (min(p.z for p in pts) + max(p.z for p in pts)) / 2
            low = min(p.z for p in pts)
            for part, r in regions.items():
                x0, x1, z0, z1 = r["box"]
                if x0 <= cx <= x1 and z0 <= cz <= z1 and low <= r.get("below", 1e9):
                    for g in island:
                        face_part[g.index] = part
        bm.free()
        parts = {}
        for f in o.data.polygons:
            parts.setdefault(face_part.get(f.index, "body"), set()).add(f.index)
        for part, faces in parts.items():
            c = o.copy()
            c.data = o.data.copy()
            bpy.context.collection.objects.link(c)
            bm = bmesh.new()
            bm.from_mesh(c.data)
            bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.index not in faces], context="FACES")
            bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
            bm.to_mesh(c.data)
            bm.free()
            c["part"] = part
            out.append(c)
            print("ISLANDS %s: %d faces" % (part, len(faces)))
        bpy.data.objects.remove(o)
    return out


def bbox(objs):
    mn = mathutils.Vector((1e9, 1e9, 1e9))
    mx = -mn
    for o in objs:
        for v in o.data.vertices:
            w = o.matrix_world @ v.co
            mn = mathutils.Vector(map(min, mn, w))
            mx = mathutils.Vector(map(max, mx, w))
    return mn, mx


def load_gun(gid, cfg):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=extract(gid, cfg), merge_vertices=True)
    for o in list(bpy.data.objects):
        if o.type == "MESH" and matches(o.name, cfg.get("drop", [])):
            bpy.data.objects.remove(o)
    meshes = bake_to_static()
    # Parts.
    objs = []
    for o in meshes:
        if cfg.get("bone_parts") and o.vertex_groups:
            objs += split_by_bones(o, cfg["bone_parts"])
        else:
            part = "body"
            for p, prefixes in cfg.get("parts", {}).items():
                if matches(o.name, prefixes):
                    part = p
            o["part"] = part
            objs.append(o)
    # Orientation and size: barrel along +X, real length, then the origin
    # at the grip point.
    rot = mathutils.Matrix.Rotation(math.radians(cfg["turn"]), 4, "Z")
    for o in objs:
        o.data.transform(rot)
        o.data.update()
    mn, mx = bbox(objs)
    s = cfg["length"] / (mx.x - mn.x)
    gx = mn.x + (mx.x - mn.x) * cfg["grip"][0]
    gz = mn.z + (mx.z - mn.z) * cfg["grip"][1]
    gy = (mn.y + mx.y) / 2.0
    xf = mathutils.Matrix.Scale(s, 4) @ mathutils.Matrix.Translation((-gx, -gy, -gz))
    shift = cfg.get("shift", (0.0, 0.0))
    xf = mathutils.Matrix.Translation((-shift[0], 0.0, -shift[1])) @ xf
    for o in objs:
        o.data.transform(xf)
        o.data.update()
    # Parts that are loose islands of a single-mesh model (by position).
    if cfg.get("islands"):
        objs = split_islands(objs, cfg["islands"])
    # One object per part, origin at its centre.
    by_part = {}
    for o in objs:
        by_part.setdefault(o["part"], []).append(o)
    result = []
    for part, group in by_part.items():
        select_only(group)
        if len(group) > 1:
            bpy.ops.object.join()
        o = bpy.context.view_layer.objects.active
        o.name = part
        o.data.name = part
        o.vertex_groups.clear()
        if part != "body":
            bpy.ops.object.origin_set(type="ORIGIN_GEOMETRY", center="BOUNDS")
        result.append(o)
    return result


# --- Materials --------------------------------------------------------------

def principled(mat):
    return next((n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)


def linked_image(node_input):
    """The image feeding a socket, through a Normal Map / Separate node if any."""
    for link in node_input.links:
        n = link.from_node
        if n.type == "TEX_IMAGE":
            return n
        for inp in n.inputs:
            img = linked_image(inp)
            if img:
                return img
    return None


def pixels(img, size=None):
    if size:
        img = img.copy()
        img.scale(size, size)
    a = np.empty(img.size[0] * img.size[1] * 4, dtype=np.float32)
    img.pixels.foreach_get(a)
    return a.reshape((img.size[1], img.size[0], 4))


def new_image(name, arr):
    h, w = arr.shape[:2]
    img = bpy.data.images.new(name, w, h, alpha=False)
    img.pixels.foreach_set(arr.astype(np.float32).ravel())
    img.pack()
    return img


def specgloss_to_mr(mat):
    """Sniper: spec/gloss map -> glTF metal/rough map (G rough, B metal)."""
    nt = mat.node_tree
    bsdf = principled(mat)
    sg = next(n for n in nt.nodes if n.type == "TEX_IMAGE" and "specularGlossiness" in n.image.name)
    p = pixels(sg.image)
    spec = p[..., :3].mean(axis=2)
    mr = np.ones_like(p)
    mr[..., 1] = 1.0 - p[..., 3]                                  # roughness
    mr[..., 2] = np.clip((spec - 0.18) / 0.25, 0.0, 1.0)          # metal where specular is bright
    img = new_image(mat.name + "_mr", mr)
    for n in [n for n in nt.nodes if n.type == "TEX_IMAGE" and "specularGlossiness" in n.image.name]:
        nt.nodes.remove(n)
    bsdf.inputs["Specular Tint"].default_value = (1, 1, 1, 1)
    hook_mr(mat, img)


def hook_mr(mat, img):
    nt = mat.node_tree
    bsdf = principled(mat)
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    img.colorspace_settings.name = "Non-Color"
    sep = nt.nodes.new("ShaderNodeSeparateColor")
    nt.links.new(tex.outputs["Color"], sep.inputs["Color"])
    nt.links.new(sep.outputs["Green"], bsdf.inputs["Roughness"])
    nt.links.new(sep.outputs["Blue"], bsdf.inputs["Metallic"])


def setup_materials(gid, cfg, lod, size):
    for mat in bpy.data.materials:
        if not mat.use_nodes or mat.users == 0:
            continue
        bsdf = principled(mat)
        if bsdf is None:
            continue
        # The importer's "glTF Material Output" group would export the
        # full-size metal/rough map again as an occlusion texture.
        for n in [n for n in mat.node_tree.nodes if n.type == "GROUP"]:
            mat.node_tree.nodes.remove(n)
        # glTF specular extension: plain defaults (the importer's values made
        # the dark guns look plastic in Godot, which ignores them anyway).
        for k in ("Specular IOR Level",):
            if k in bsdf.inputs:
                bsdf.inputs[k].default_value = 0.5
        if cfg.get("flat"):
            col = bsdf.inputs["Base Color"].default_value
            lum = 0.2126 * col[0] + 0.7152 * col[1] + 0.0722 * col[2]
            warm = col[0] > col[2] * 1.3  # wood / tan furniture
            if warm:
                bsdf.inputs["Metallic"].default_value = 0.0
                bsdf.inputs["Roughness"].default_value = 0.6
            elif lum < 0.07:
                # Dark steel / polymer: lift it a little so it isn't a black hole.
                f = 0.07 / max(lum, 0.005)
                bsdf.inputs["Base Color"].default_value = (min(col[0] * f, 1), min(col[1] * f, 1), min(col[2] * f, 1), 1)
                bsdf.inputs["Metallic"].default_value = 0.55
                bsdf.inputs["Roughness"].default_value = 0.42
            else:
                bsdf.inputs["Metallic"].default_value = 0.4
                bsdf.inputs["Roughness"].default_value = 0.5
            continue
        if cfg.get("specgloss") and not linked_image(bsdf.inputs["Metallic"]):
            specgloss_to_mr(mat)
        nt = mat.node_tree
        base = linked_image(bsdf.inputs["Base Color"])
        normal = linked_image(bsdf.inputs["Normal"])
        mr = linked_image(bsdf.inputs["Roughness"])
        if lod == "low":
            # Colour map only: average roughness / metal as constants.
            if mr:
                p = pixels(mr.image, 64)
                rough, metal = float(p[..., 1].mean()), float(p[..., 2].mean())
                for inp in ("Roughness", "Metallic"):
                    for link in list(bsdf.inputs[inp].links):
                        nt.links.remove(link)
                bsdf.inputs["Roughness"].default_value = rough
                bsdf.inputs["Metallic"].default_value = metal
            for link in list(bsdf.inputs["Normal"].links):
                nt.links.remove(link)
            normal = mr = None
        for node, kind in ((base, "albedo"), (normal, "normal"), (mr, "mr")):
            if node is None:
                continue
            # Normal and metal/rough maps at half the colour map's size.
            px = size if kind == "albedo" else size // 2
            img = node.image.copy()
            w, h = img.size
            img.scale(min(w, px), max(1, h * min(w, px) // w))
            img.name = "%s_%s_%s" % (gid, lod, kind)
            img.pack()
            node.image = img


# --- LOD + export -----------------------------------------------------------

def decimate(objs, target):
    before = tri_count(objs)
    ratio = min(1.0, target / before)
    for o in objs:
        select_only([o])
        if ratio < 0.999 and len(o.data.polygons) > 24:
            mod = o.modifiers.new("decimate", "DECIMATE")
            mod.decimate_type = "COLLAPSE"
            mod.ratio = ratio
            mod.use_collapse_triangulate = True
            bpy.ops.object.modifier_apply(modifier=mod.name)
            # Re-derive hard edges: decimation breaks the custom normals.
            if o.data.has_custom_normals:
                bpy.ops.mesh.customdata_custom_splitnormals_clear()
            bpy.ops.object.shade_smooth_by_angle(angle=math.radians(40))
    return before, tri_count(objs)


def build(gid):
    cfg = GUNS[gid]
    os.makedirs(OUT, exist_ok=True)
    for lod, share, size in LODS:
        objs = load_gun(gid, cfg)
        before, after = decimate(objs, cfg["tris"] * share)
        setup_materials(gid, cfg, lod, size)
        path = os.path.join(OUT, "%s_%s.glb" % (gid, lod))
        select_only(objs)
        bpy.ops.export_scene.gltf(
            filepath=path,
            export_format="GLB",
            use_selection=True,
            export_animations=False,
            export_skins=False,
            export_morph=False,
            export_image_format="WEBP",
            export_image_quality=88,
            export_yup=True,
            export_apply=True,
        )
        mn, mx = bbox(objs)
        print("GUN %-8s %-4s %5d -> %5d tris, parts %s, %.0f KB, size %.3f x %.3f x %.3f" % (
            gid, lod, before, after, sorted(o.name for o in objs), os.path.getsize(path) / 1024,
            mx.x - mn.x, mx.z - mn.z, mx.y - mn.y))


def preview(gid, out_dir):
    """Side view (from the gun's right) with a 5 cm grid; origin lines blue."""
    cfg = GUNS[gid]
    objs = load_gun(gid, cfg)
    mn, mx = bbox(objs)
    sc = bpy.context.scene
    grid_mat = bpy.data.materials.new("grid")
    grid_mat.diffuse_color = (1, 0.2, 0.2, 1)
    axis_mat = bpy.data.materials.new("axis")
    axis_mat.diffuse_color = (0.2, 0.4, 1, 1)
    def bar(x0, z0, x1, z1, mat):
        bpy.ops.mesh.primitive_cube_add(size=1)
        b = bpy.context.active_object
        b.location = ((x0 + x1) / 2, 0.3, (z0 + z1) / 2)
        b.scale = (max(x1 - x0, 0.0012), 0.001, max(z1 - z0, 0.0012))
        b.data.materials.append(mat)
    step = 0.05
    for i in range(int(math.floor(mn.x / step)), int(math.ceil(mx.x / step)) + 1):
        bar(i * step, mn.z - 0.02, i * step, mx.z + 0.02, axis_mat if i == 0 else grid_mat)
    for j in range(int(math.floor(mn.z / step)), int(math.ceil(mx.z / step)) + 1):
        bar(mn.x - 0.02, j * step, mx.x + 0.02, j * step, axis_mat if j == 0 else grid_mat)
    sc.render.engine = "BLENDER_WORKBENCH"
    sc.display.shading.light = "STUDIO"
    sc.display.shading.color_type = "TEXTURE"
    sc.display.shading.show_object_outline = True
    sc.render.resolution_x = 1400
    sc.render.resolution_y = int(1400 * (mx.z - mn.z + 0.06) / (mx.x - mn.x + 0.06))
    cam = bpy.data.cameras.new("cam")
    cam.type = "ORTHO"
    cam.ortho_scale = (mx.x - mn.x) + 0.06
    co = bpy.data.objects.new("cam", cam)
    sc.collection.objects.link(co)
    sc.camera = co
    co.location = ((mn.x + mx.x) / 2, -2.0, (mn.z + mx.z) / 2)
    co.rotation_euler = (math.radians(90), 0, 0)
    if os.environ.get("GUN_VIEW") == "top":
        co.location = ((mn.x + mx.x) / 2, 0.0, 2.0)
        co.rotation_euler = (0, 0, 0)
        sc.render.resolution_y = int(1400 * (mx.y - mn.y + 0.06) / (mx.x - mn.x + 0.06))
    sc.render.filepath = os.path.join(out_dir, gid + ".png")
    bpy.ops.render.render(write_still=True)
    for o in objs:
        a, b = bbox([o])
        print("PART %-8s %-8s x %.3f..%.3f  y %.3f..%.3f  z %.3f..%.3f  origin %s" % (
            gid, o.name, a.x, b.x, a.y, b.y, a.z, b.z, tuple(round(c, 3) for c in o.location)))


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    prev = None
    if "--preview" in argv:
        i = argv.index("--preview")
        prev = argv[i + 1]
        del argv[i:i + 2]
    for gid in argv or list(GUNS):
        if prev:
            preview(gid, prev)
        else:
            build(gid)


main()
