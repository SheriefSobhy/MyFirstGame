# Builds assets/models/vehicles/helicopter.glb (Extraction missions) from the
# CC0 OpenGameArt helicopter by z3eus (art_source/opengameart/helicopter/,
# git-ignored): HelicopterBody.fbx + HelicopterWings.fbx.
#   blender -b --factory-startup --python tools/blender/build_helicopter.py
# Output: two meshes, "body" (skids on y = 0, nose towards -Z after glTF's
# Y-up conversion) and "rotor" (origin on the hub, so the game spins it),
# rotor scaled down to ROTOR_DIAMETER and simplified (planar dissolve), flat military colours.
import bpy, os, math, mathutils

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "art_source", "opengameart", "helicopter")
OUT = os.path.join(ROOT, "assets", "models", "vehicles", "helicopter.glb")
ROTOR_DIAMETER = 9.0
ROTOR_DISSOLVE_DEG = 8.0
COLOURS = {  # by source material name: olive body, dark trim, glass, black
    "Material.001": (0.16, 0.2, 0.1), "Material": (0.09, 0.09, 0.08),
    "Material.002": (0.05, 0.06, 0.07), "Material.003": (0.03, 0.03, 0.03),
    "Material.004": (0.06, 0.06, 0.06)}

bpy.ops.wm.read_factory_settings(use_empty=True)
def load(name):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=os.path.join(SRC, name))
    meshes = [o for o in set(bpy.data.objects) - before if o.type == 'MESH']
    o = meshes[0]
    bpy.context.view_layer.objects.active = o
    for x in bpy.data.objects: x.select_set(x == o)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    return o
body = load("HelicopterBody.fbx")
rotor = load("HelicopterWings.fbx")
bpy.context.view_layer.update()
for o in (body, rotor):
    for m in o.data.materials:
        m.use_nodes = True
        bsdf = m.node_tree.nodes.get("Principled BSDF")
        c = COLOURS.get(m.name, (0.1, 0.1, 0.1))
        bsdf.inputs["Base Color"].default_value = (*c, 1.0)
        bsdf.inputs["Roughness"].default_value = 0.2 if m.name == "Material.002" else 0.6
        bsdf.inputs["Metallic"].default_value = 0.3
def bounds(o):
    v = [o.matrix_world @ mathutils.Vector(c) for c in o.bound_box]
    return (mathutils.Vector([min(p[i] for p in v) for i in range(3)]),
            mathutils.Vector([max(p[i] for p in v) for i in range(3)]))
bmin, bmax = bounds(body)
rmin, rmax = bounds(rotor)
hub = mathutils.Vector(((rmin.x + rmax.x) / 2, (rmin.y + rmax.y) / 2, rmin.z))
# Rotor: decimate, scale about the hub, origin on the hub.
mod = rotor.modifiers.new("dec", 'DECIMATE')
mod.decimate_type = 'DISSOLVE'  # planar: keeps the blade outline
mod.angle_limit = math.radians(ROTOR_DISSOLVE_DEG)
bpy.context.view_layer.objects.active = rotor
bpy.ops.object.modifier_apply(modifier="dec")
s = ROTOR_DIAMETER / max(rmax.x - rmin.x, rmax.y - rmin.y)
rotor.data.transform(mathutils.Matrix.Translation(-hub))
rotor.data.transform(mathutils.Matrix.Diagonal((s, s, 1.0, 1.0)))
# Ground: skids on z = 0, hub over the origin in x/y.
shift = mathutils.Vector((-hub.x, -hub.y, -bmin.z))
body.data.transform(mathutils.Matrix.Translation(shift))
rotor.location = hub + shift
body.name = "body"; rotor.name = "rotor"
# The source's nose is towards -X: turn it to face -Y (= -Z in glTF / Godot).
for o in (body,):
    o.data.transform(mathutils.Matrix.Rotation(math.radians(-90), 4, 'Z'))
rotor.location = mathutils.Matrix.Rotation(math.radians(-90), 4, 'Z') @ rotor.location
bpy.context.view_layer.update()
for o in (body, rotor):
    tris = sum(len(p.vertices) - 2 for p in o.data.polygons)
    print("PART", o.name, tris, "tris", [round(x, 2) for x in bounds(o)[0]], [round(x, 2) for x in bounds(o)[1]])
os.makedirs(os.path.dirname(OUT), exist_ok=True)
bpy.ops.export_scene.gltf(filepath=OUT, export_format='GLB', export_apply=True, export_yup=True)
print("WROTE", OUT)
