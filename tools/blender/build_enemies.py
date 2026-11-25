"""Step 2 of the enemy model build (build_enemies.bat runs all steps).

Reads art_source/build/<id>_raw.glb (written by tools/mixamo_export.gd from the
Mixamo FBX files) and writes the three detail levels the game loads by
graphics quality:

    assets/models/enemies/<id>_high.glb   ~15k tris, 1024 px textures
    assets/models/enemies/<id>_med.glb     ~7k tris,  512 px
    assets/models/enemies/<id>_low.glb     ~3k tris,  256 px

Meshes are reduced with Blender's Decimate (collapse) modifier, which keeps
the skin weights. Animations are not exported here: tools/mixamo_anims.gd
retargets them onto each character's skeleton.

    blender -b --factory-startup --python tools/blender/build_enemies.py [-- <id> ...]
"""

import array
import os
import sys

import bpy

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "art_source", "build")
OUT = os.path.join(ROOT, "assets", "models", "enemies")

CHARACTERS = ["zombie", "runner", "brute", "soldier", "exploder"]
# name, target triangles, texture size
LODS = [("high", 15000, 1024), ("med", 7000, 512), ("low", 3000, 256)]


def tri_count(objs):
    return sum(len(p.vertices) - 2 for o in objs for p in o.data.polygons)


def min_alpha(img):
    if img.channels < 4:
        return 1.0
    px = array.array("f", [0.0]) * (img.size[0] * img.size[1] * 4)
    img.pixels.foreach_get(px)
    return min(px[3::4])


def set_alpha_mode(mat, cutout):
    """Opaque unless its texture really has holes; then alpha clip (glTF MASK,
    exported from a Round node), never blended: no sorting problems and it
    casts shadows, also in the Compatibility renderer."""
    if not mat.use_nodes:
        return
    nt = mat.node_tree
    bsdf = next((n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if bsdf is None:
        return
    tex = next((n for n in nt.nodes if n.type == "TEX_IMAGE" and n.image), None)
    for link in list(bsdf.inputs["Alpha"].links):
        nt.links.remove(link)
    if tex and tex.image.name in cutout:
        rnd = nt.nodes.new("ShaderNodeMath")
        rnd.operation = "ROUND"
        nt.links.new(tex.outputs["Alpha"], rnd.inputs[0])
        nt.links.new(rnd.outputs[0], bsdf.inputs["Alpha"])
        mat.blend_method = "HASHED"
    else:
        mat.blend_method = "OPAQUE"


def build(cid):
    src = os.path.join(SRC, cid + "_raw.glb")
    for lod, target, tex in LODS:
        bpy.ops.wm.read_factory_settings(use_empty=True)
        bpy.ops.import_scene.gltf(filepath=src)
        meshes = [o for o in bpy.data.objects if o.type == "MESH"]
        before = tri_count(meshes)
        ratio = min(1.0, target / before)
        for o in meshes:
            if o.data.shape_keys:
                o.shape_key_clear()
            if ratio < 0.999:
                bpy.context.view_layer.objects.active = o
                mod = o.modifiers.new("decimate", "DECIMATE")
                mod.decimate_type = "COLLAPSE"
                mod.ratio = ratio
                mod.use_collapse_triangulate = True
                bpy.ops.object.modifier_apply(modifier=mod.name)
        after = tri_count(meshes)
        cutout = set(img.name for img in bpy.data.images if min_alpha(img) < 0.5)
        for m in bpy.data.materials:
            set_alpha_mode(m, cutout)
        for img in bpy.data.images:
            w, h = img.size
            img.scale(min(w, tex), max(1, h * min(w, tex) // w))
            img.pack()
        # WebP: small, keeps the alpha of cut-outs (hair, torn cloth). (Blender's
        # JPEGs carry metadata Godot's JPEG loader rejects.)
        needs_alpha = bool(cutout)
        path = os.path.join(OUT, "%s_%s.glb" % (cid, lod))
        bpy.ops.export_scene.gltf(
            filepath=path,
            export_format="GLB",
            export_animations=False,
            export_skins=True,
            export_morph=False,
            export_image_format="WEBP",
            export_image_quality=88,
            export_yup=True,
        )
        print("ENEMY %s %s: %d -> %d tris, %d px, %s, %.0f KB" % (
            cid, lod, before, after, tex, "cut-out" if needs_alpha else "opaque", os.path.getsize(path) / 1024))


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    os.makedirs(OUT, exist_ok=True)
    for cid in argv or CHARACTERS:
        build(cid)


main()
