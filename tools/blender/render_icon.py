"""Renders the Dead Perimeter app icon / splash from the game's own models.

    blender -b --factory-startup --python tools/blender/render_icon.py -- <design> <out.png> [width] [height]

design: A (ash horizon), B (in the sights), C (badge), or splash.
Uses the Quaternius zombies + guns the game ships and Blender's bundled Inter
font (OFL), so nothing new is added to the project's assets.
"""

import math
import os
import random
import sys

import bpy
from mathutils import Vector

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
Q = os.path.join(ROOT, "assets", "models", "quaternius")
FONT = os.path.join(os.path.dirname(bpy.app.binary_path), bpy.app.version_string[:3],
                    "datafiles", "fonts", "Inter.woff2")
TITLE = "DEAD" + chr(10) + "PERIMETER"  # two lines: 14 letters do not fit on one

ORANGE = (1.0, 0.42, 0.08)
EMBER = (1.0, 0.62, 0.2)


# --- helpers ------------------------------------------------------------------

def emission_mat(name, color, strength=1.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (*color, 1)
    em.inputs["Strength"].default_value = strength
    nt.links.new(em.outputs[0], out.inputs[0])
    return m


def flat_mat(name, color, rough=0.6, metal=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    p = m.node_tree.nodes["Principled BSDF"]
    p.inputs["Base Color"].default_value = (*color, 1)
    p.inputs["Roughness"].default_value = rough
    p.inputs["Metallic"].default_value = metal
    return m


def gradient_mat(name, stops, axis="Y", kind="LINEAR", strength=1.0):
    """Emissive gradient: LINEAR along a generated-coord axis (0..1 over the
    object), RADIAL = distance from the object's origin in object space."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Strength"].default_value = strength
    tc = nt.nodes.new("ShaderNodeTexCoord")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    if kind == "RADIAL":
        length = nt.nodes.new("ShaderNodeVectorMath")
        length.operation = "LENGTH"
        nt.links.new(tc.outputs["Object"], length.inputs[0])
        nt.links.new(length.outputs["Value"], ramp.inputs["Fac"])
    else:
        sep = nt.nodes.new("ShaderNodeSeparateXYZ")
        nt.links.new(tc.outputs["Generated"], sep.inputs[0])
        nt.links.new(sep.outputs[axis], ramp.inputs["Fac"])
    els = ramp.color_ramp.elements
    while len(els) > 1:
        els.remove(els[-1])
    els[0].position, els[0].color = stops[0][0], (*stops[0][1], 1)
    for pos, col in stops[1:]:
        e = els.new(pos)
        e.color = (*col, 1)
    nt.links.new(ramp.outputs["Color"], em.inputs["Color"])
    nt.links.new(em.outputs[0], out.inputs[0])
    return m


def plane(name, size, loc, rot, mat):
    bpy.ops.mesh.primitive_plane_add(size=1, location=loc, rotation=rot)
    o = bpy.context.object
    o.name = name
    o.scale = (size[0], size[1], 1)
    o.data.materials.append(mat)
    return o


def pivot(name):
    p = bpy.data.objects.new(name, None)
    bpy.context.collection.objects.link(p)
    return p


def import_zombie(kind="Zombie_Male", frame_frac=0.3, action="Walk"):
    """Returns (pivot, meshes). The pivot faces the camera (-Y); turn it with
    rotation_euler.z, move it with location."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=os.path.join(Q, "characters", kind + ".fbx"))
    new = [o for o in bpy.data.objects if o not in before]
    arm = next(o for o in new if o.type == "ARMATURE")
    act = next(a for a in bpy.data.actions if a.name.endswith("|" + action))
    arm.animation_data_create()
    arm.animation_data.action = act
    if hasattr(arm.animation_data, "action_slot") and act.slots:
        arm.animation_data.action_slot = act.slots[0]
    f0, f1 = act.frame_range
    bpy.context.scene.frame_set(int(f0 + (f1 - f0) * frame_frac))
    meshes = [o for o in new if o.type == "MESH"]
    # The FBX import leaves Alpha at 0 (dithered), which renders invisible.
    for o in meshes:
        for m in o.data.materials:
            p = m.node_tree.nodes.get("Principled BSDF") if m and m.use_nodes else None
            if p:
                p.inputs["Alpha"].default_value = 1.0
                p.inputs["Roughness"].default_value = 0.8
    # The model already faces -Y (the camera).
    pv = pivot(kind + "_pivot")
    arm.parent = pv
    return pv, meshes


def import_gun(name):
    """Returns (pivot, meshes). Pivot space: barrel along +X, top +Z, side
    towards -Y."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(Q, "ultimate_guns", name + ".glb"))
    new = [o for o in bpy.data.objects if o not in before]
    pv = pivot(name + "_pivot")
    for o in new:
        if o.parent is None:
            o.parent = pv
    return pv, [o for o in new if o.type == "MESH"]


def set_mat(objs, mat):
    for o in objs:
        o.data.materials.clear()
        o.data.materials.append(mat)


def text(body, loc, size, mat, bold=0.025, extrude=0.06, spacing=1.12):
    cu = bpy.data.curves.new("title", "FONT")
    cu.body = body
    cu.font = bpy.data.fonts.load(FONT)
    cu.size = size
    cu.align_x = "CENTER"
    cu.align_y = "CENTER"
    cu.offset = bold * size      # thickens the regular weight
    cu.extrude = extrude * size
    cu.space_character = spacing
    o = bpy.data.objects.new("title", cu)
    bpy.context.collection.objects.link(o)
    o.location = loc
    o.rotation_euler = (math.radians(90), 0, 0)
    o.data.materials.append(mat)
    return o


def area_light(loc, target, energy, color, size=2.0):
    d = bpy.data.lights.new("light", "AREA")
    d.energy = energy
    d.color = color
    d.size = size
    o = bpy.data.objects.new("light", d)
    bpy.context.collection.objects.link(o)
    o.location = loc
    look_at(o, target)
    return o


def look_at(o, target):
    o.rotation_euler = (Vector(target) - o.location).to_track_quat("-Z", "Y").to_euler()


def camera(loc, target, lens=50, ortho=None):
    d = bpy.data.cameras.new("cam")
    d.lens = lens
    d.clip_end = 300
    if ortho:
        d.type = "ORTHO"
        d.ortho_scale = ortho
    o = bpy.data.objects.new("cam", d)
    bpy.context.collection.objects.link(o)
    o.location = loc
    look_at(o, target)
    bpy.context.scene.camera = o
    return o


def embers(n, box, seed, size=(0.008, 0.022), strength=6.0):
    rng = random.Random(seed)
    mat = emission_mat("ember", EMBER, strength)
    for _ in range(n):
        loc = [rng.uniform(a, b) for a, b in box]
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=rng.uniform(*size), location=loc)
        o = bpy.context.object
        o.scale.z = rng.uniform(1.0, 2.2)
        o.data.materials.append(mat)


def world(color, strength=1.0):
    w = bpy.data.worlds.new("w")
    w.use_nodes = True
    bg = w.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (*color, 1)
    bg.inputs["Strength"].default_value = strength
    bpy.context.scene.world = w


def glare(strength=0.5, threshold=1.0, size=0.6):
    """Soft bloom via the compositor (skipped if this Blender's API differs)."""
    scn = bpy.context.scene
    try:
        nt = bpy.data.node_groups.new("comp", "CompositorNodeTree")
        scn.compositing_node_group = nt
        rl = nt.nodes.new("CompositorNodeRLayers")
        g = nt.nodes.new("CompositorNodeGlare")
        out = nt.nodes.new("NodeGroupOutput")
        nt.interface.new_socket("Image", in_out="OUTPUT", socket_type="NodeSocketColor")
        for key, val in (("Type", "Bloom"), ("Quality", "High"), ("Threshold", threshold),
                         ("Strength", strength), ("Size", size)):
            if key in g.inputs:
                g.inputs[key].default_value = val
        nt.links.new(rl.outputs["Image"], g.inputs["Image"])
        nt.links.new(g.outputs["Image"], out.inputs[0])
    except Exception as e:  # noqa: BLE001
        print("glare skipped:", e)


# --- designs ------------------------------------------------------------------

def design_a(title=False):
    """Ash horizon: zombie silhouettes walking out of a burning skyline, rifle
    in the foreground like the player's view."""
    world((0.0, 0.0, 0.0))
    sky = gradient_mat("sky", [
        (0.0, (0.0, 0.0, 0.0)),
        (0.44, (0.03, 0.006, 0.0)),
        (0.485, (1.0, 0.4, 0.06)),
        (0.50, (1.0, 0.82, 0.5)),
        (0.53, (0.7, 0.18, 0.03)),
        (0.68, (0.16, 0.03, 0.01)),
        (1.0, (0.015, 0.0, 0.005)),
    ], strength=2.2)
    plane("sky", (120, 40), (0, 40, 1.2), (math.radians(90), 0, 0), sky)
    ground = flat_mat("ground", (0.008, 0.006, 0.005), 0.6)
    plane("ground", (120, 120), (0, 20, 0), (0, 0, 0), ground)
    black = flat_mat("silhouette", (0.006, 0.005, 0.005), 0.45)
    horde = [  # kind, x, y, turn (deg), anim frame
        ("Zombie_Male", -0.15, -1.2, 14, 0.25),
        ("Zombie_Female", 2.4, 6.5, -10, 0.7),
        ("Zombie_Male", -3.2, 9.5, 20, 0.5),
        ("Zombie_Female", -1.0, 15.0, 5, 0.1),
        ("Zombie_Male", 5.5, 17.0, -25, 0.85),
    ]
    for kind, x, y, turn, frame in horde:
        pv, meshes = import_zombie(kind, frame)
        set_mat(meshes, black)
        pv.location = (x, y, 0)
        pv.rotation_euler.z = math.radians(turn)
    area_light((0, 4, 4.5), (0, -1.2, 2.3), 1800, ORANGE, 4)
    gun, gmeshes = import_gun("ak_rifle")
    set_mat(gmeshes, black)
    gun.location = (0.36, -5.85, 0.72)
    gun.rotation_euler = (math.radians(-10), math.radians(-6), math.radians(99))
    embers(55, ((-4, 4), (-2, 10), (0.2, 4.5)), 3)
    if title:
        mat = emission_mat("title", (1.0, 0.6, 0.22), 2.5)
        text(TITLE, (0, -2.0, 3.08), 0.22, mat)
    camera((0, -6.6, 1.05), (0, 0, 2.25), lens=34)
    glare(0.45, 1.0, 0.7)


def design_b():
    """In the sights: a lit zombie under a red-dot reticle, title below."""
    world((0.004, 0.003, 0.003))
    bg = gradient_mat("bg", [
        (0.0, (0.5, 0.12, 0.02)),      # plane-local units: the view is ~0.14 wide
        (0.06, (0.16, 0.04, 0.01)),
        (0.15, (0.012, 0.007, 0.006)),
    ], kind="RADIAL", strength=1.0)
    plane("bg", (14, 14), (0, 3, 2.5), (math.radians(90), 0, 0), bg)
    pv, meshes = import_zombie(frame_frac=0.3)
    pv.rotation_euler.z = math.radians(16)
    area_light((-3, -3, 1.2), (0, 0, 2.2), 700, ORANGE, 2)
    area_light((3, 2, 4), (0, 0, 2.3), 1500, (0.55, 0.7, 1.0), 1.5)
    area_light((0, -5, 4), (0, 0, 2.3), 250, (1, 0.9, 0.8), 4)
    red = emission_mat("reticle", (1.0, 0.08, 0.04), 8)
    cx, cz, y = 0.0, 2.45, -1.8
    bpy.ops.mesh.primitive_torus_add(major_radius=0.62, minor_radius=0.022, location=(cx, y, cz),
                                     rotation=(math.radians(90), 0, 0), major_segments=96)
    bpy.context.object.data.materials.append(red)
    for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        bpy.ops.mesh.primitive_cube_add(size=1, location=(cx + dx * 0.72, y, cz + dz * 0.72))
        o = bpy.context.object
        o.scale = (0.22 if dx else 0.035, 0.01, 0.22 if dz else 0.035)
        o.data.materials.append(red)
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.04, location=(cx, y, cz))
    bpy.context.object.data.materials.append(red)
    title = emission_mat("title", (1.0, 0.55, 0.18), 2.5)
    text(TITLE, (0, -2.2, 0.55), 0.4, title)
    embers(30, ((-2.5, 2.5), (-1, 2), (0.3, 4.2)), 7)
    camera((0, -9, 2.05), (0, 0, 2.05), ortho=3.9)
    glare(0.5, 1.0, 0.6)


def design_c(mode="full"):
    """Badge: zombie over crossed rifles in a burning ring, title banner."""
    world((0.0, 0.0, 0.0))
    bg = flat_mat("bgdark", (0.02, 0.018, 0.017), 0.8)
    layer = mode in ("fg", "mono")
    if not layer:
        plane("bg", (20, 20), (0, 2.0, 2.4), (math.radians(90), 0, 0), bg)
    disc_mat = gradient_mat("disc", [
        (0.0, (0.5, 0.16, 0.03)),
        (0.6, (0.12, 0.03, 0.01)),
        (1.0, (0.03, 0.01, 0.005)),
    ], kind="RADIAL", strength=2.5)
    bpy.ops.mesh.primitive_cylinder_add(vertices=128, radius=1.9, depth=0.02, location=(0, 1.5, 2.55),
                                        rotation=(math.radians(90), 0, 0))
    bpy.context.object.data.materials.append(disc_mat)
    ring = emission_mat("ring", ORANGE, 4)
    bpy.ops.mesh.primitive_torus_add(major_radius=1.92, minor_radius=0.06, location=(0, 1.45, 2.55),
                                     rotation=(math.radians(90), 0, 0), major_segments=128)
    bpy.context.object.data.materials.append(ring)
    for name, sign in (("ak_rifle", 1), ("shotgun", -1)):
        gun, _ = import_gun(name)
        # Crossed behind the shoulders: both centres at (0, 2.3), muzzles
        # up and out. The shotgun is mirrored so its muzzle points up-left.
        s = 3.2
        a = math.radians(42)
        gun.scale = (s * sign, s, s)
        gun.rotation_euler = (0, -a * sign, 0)
        gun.location = (-sign * 0.19 * s * math.cos(a), 1.0, 2.3 - 0.19 * s * math.sin(a))
    pv, meshes = import_zombie(frame_frac=0.35, action="Idle")
    pv.location = (0, 0, 0.1)
    pv.rotation_euler.z = math.radians(10)
    area_light((-2.2, -3, 3.2), (0, 0, 2.45), 650, (1, 0.6, 0.35), 2)
    area_light((2.5, 1, 3.5), (0, 0, 2.5), 1200, ORANGE, 1.5)
    area_light((0, -4, 1.5), (0, 0, 2.4), 150, (0.6, 0.75, 1.0), 3)
    if mode == "full":
        banner = flat_mat("banner", (0.012, 0.01, 0.01), 0.5)
        bpy.ops.mesh.primitive_cube_add(size=1, location=(0, -0.9, 0.82))
        b = bpy.context.object
        b.scale = (4.6, 0.05, 0.78)
        b.data.materials.append(banner)
        edge = emission_mat("edge", ORANGE, 4)
        for z in (0.43, 1.21):
            bpy.ops.mesh.primitive_cube_add(size=1, location=(0, -0.93, z))
            o = bpy.context.object
            o.scale = (4.6, 0.02, 0.035)
            o.data.materials.append(edge)
        title = emission_mat("title", (1.0, 0.62, 0.25), 2.2)
        text(TITLE, (0, -1.0, 0.82), 0.4, title)
    if mode == "full":
        camera((0, -9, 2.3), (0, 0, 2.3), ortho=4.3)
    elif mode == "badge":
        camera((0, -9, 2.45), (0, 0, 2.45), ortho=4.3)
    else:  # adaptive layer: the badge sits inside the 66% safe zone
        camera((0, -9, 2.45), (0, 0, 2.45), ortho=6.0)
    if mode == "mono":
        white = emission_mat("white", (1, 1, 1), 1.0)
        for o in bpy.context.scene.objects:
            if o.type in ("MESH", "CURVE"):
                o.data.materials.clear()
                o.data.materials.append(white)
        for o in list(bpy.context.scene.objects):
            if o.type == "MESH" and (o.data.name.startswith("Cylinder")):
                bpy.data.objects.remove(o)  # the disc: keep only ring + figures
    elif not layer:
        glare(0.4, 1.0, 0.6)


def design_bg():
    """Adaptive icon background: warm dark ember glow, no content."""
    world((0.0, 0.0, 0.0))
    disc = gradient_mat("bgglow", [
        (0.0, (0.34, 0.11, 0.02)),
        (0.7, (0.08, 0.025, 0.008)),
        (1.0, (0.03, 0.01, 0.005)),
    ], kind="RADIAL", strength=1.6)
    bpy.ops.mesh.primitive_cylinder_add(vertices=64, radius=9, depth=0.02, location=(0, 1.5, 2.45),
                                        rotation=(math.radians(90), 0, 0))
    bpy.context.object.data.materials.append(disc)
    camera((0, -9, 2.45), (0, 0, 2.45), ortho=6.0)


DESIGNS = {"A": design_a, "B": design_b, "C": design_c, "splash": lambda: design_a(title=True),
           "Cbadge": lambda: design_c("badge"), "Cfg": lambda: design_c("fg"),
           "Cmono": lambda: design_c("mono"), "Cbg": design_bg}


def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    design, out = argv[0], argv[1]
    w = int(argv[2]) if len(argv) > 2 else 1024
    h = int(argv[3]) if len(argv) > 3 else w
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scn = bpy.context.scene
    scn.render.engine = "BLENDER_EEVEE"
    scn.render.resolution_x, scn.render.resolution_y = w, h
    scn.render.resolution_percentage = 100
    scn.render.image_settings.file_format = "PNG"
    scn.render.image_settings.color_mode = "RGB"
    try:
        scn.view_settings.view_transform = "AgX"
        scn.view_settings.look = "AgX - Punchy"
    except TypeError:
        pass
    if design in ("Cfg", "Cmono"):
        scn.render.film_transparent = True
        scn.render.image_settings.color_mode = "RGBA"
    if design == "Cmono":
        scn.view_settings.view_transform = "Standard"
        scn.view_settings.look = "None"
    DESIGNS[design]()
    scn.render.filepath = os.path.abspath(out)
    bpy.ops.render.render(write_still=True)
    print("WROTE", out)


main()
