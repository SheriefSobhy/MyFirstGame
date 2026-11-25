"""Builds the modular level kit used by all three maps.

Run headless (tools/blender/build_kit.bat does this):
    blender -b --factory-startup --python tools/blender/build_kit.py

Writes:
    assets/models/kit/kit.glb             every piece as its own mesh object,
                                          "<name>" (LOD0) and, for the big ones,
                                          "<name>_lod1" (no bevels / small parts)
    assets/textures/kit/kit_albedo.jpg    1024 texture atlas (6 cells, below)
    assets/textures/kit/kit_normal.jpg    matching normal-map atlas
    assets/textures/kit/kit_ao.png        ambient occlusion baked with Cycles

How a piece is textured (materials/kit_surface.gdshader reads this):
    UV  (TEXCOORD_0)  cell-local UV in metres / cell repeat size; it keeps
                      repeating, the shader wraps it inside the cell.
    UV2 (TEXCOORD_1)  unique unwrap of every piece into kit_ao.png.
    COLOR             a = (cell id + 8 * tint index + 0.5) / 128; rgb = white
                      (Godot multiplies in per-instance tints). Alpha is used
                      because it survives the glTF import unchanged.
So the whole kit is ONE material and ONE set of textures: a merged chunk of
walls, frames, pipes and signs is a single draw call.

Everything is low poly: bevels are one segment, cylinders 8 sides.
Coordinates: Blender Z up; a piece's front faces -Y, which is +Z in Godot.
Its origin is the bottom centre (wall-mounted pieces: the wall surface).
"""

import math
import os
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TEX = os.path.join(ROOT, "assets", "textures")
OUT_TEX = os.path.join(TEX, "kit")
OUT_GLB = os.path.join(ROOT, "assets", "models", "kit", "kit.glb")
ATLAS = 1024
AO_SAMPLES = 96

# --- Atlas cells ----------------------------------------------------------------
# id: (source folder, rect x, y, w, h in Blender UV space (origin bottom-left),
#      metres per repeat). Keep in sync with CELLS in kit_surface.gdshader.
BRICK, CONCRETE, CORRUGATED, METAL, WOOD, SIGN = range(6)
CELLS = {
    BRICK: ("factory_brick", 0.0, 0.5, 0.5, 0.5, 3.0),
    CONCRETE: ("concrete_wall_008", 0.5, 0.5, 0.5, 0.5, 3.0),
    CORRUGATED: ("rusty_corrugated_iron", 0.0, 0.0, 0.5, 0.5, 2.0),
    METAL: ("rusty_metal_02", 0.5, 0.25, 0.25, 0.25, 1.0),
    WOOD: ("rough_wood", 0.75, 0.25, 0.25, 0.25, 0.8),
    SIGN: (None, 0.5, 0.0, 0.5, 0.25, 1.0),
}
# Signs: 2 columns x 4 rows of 256 x 64 px in the SIGN cell.
SIGNS = [
    # name, text, background, text colour, border
    ("loading", "LOADING BAY 3", (0.85, 0.62, 0.08), (0.05, 0.05, 0.05), True),
    ("exit", "EXIT", (0.05, 0.45, 0.15), (0.95, 0.95, 0.95), False),
    ("danger", "DANGER  KEEP OUT", (0.85, 0.1, 0.08), (0.97, 0.95, 0.9), True),
    ("storage", "STORAGE", (0.12, 0.2, 0.38), (0.92, 0.92, 0.88), True),
    ("garage", "GARAGE", (0.75, 0.72, 0.65), (0.45, 0.08, 0.06), True),
    ("diner", "DINER", (0.6, 0.12, 0.1), (0.98, 0.88, 0.55), True),
    ("hotel", "HOTEL", (0.1, 0.1, 0.12), (0.95, 0.7, 0.3), True),
    ("pharmacy", "PHARMACY", (0.9, 0.9, 0.86), (0.08, 0.45, 0.2), True),
]

# Tints (linear rgb multipliers on the atlas colour). Keep in sync with PALETTE
# in materials/kit_surface.gdshader (max 16).
WHITE = (1.0, 1.0, 1.0)
PAL = {
    "plain": WHITE,
    "concrete": (0.95, 0.93, 0.9),
    "darkmetal": (0.45, 0.46, 0.5),
    "steel": (0.75, 0.77, 0.8),
    "paint_white": (1.6, 1.58, 1.5),
    "glass": (0.12, 0.15, 0.2),
    "rubber": (0.12, 0.12, 0.12),
    "yellow": (1.9, 1.35, 0.25),
    "green": (0.55, 0.85, 0.55),
    "blue": (0.45, 0.6, 1.1),
    "black": (0.25, 0.25, 0.25),
}
PAL_NAMES = list(PAL.keys())


def mi(cell, tint="plain"):
    """Face material index: cell id + 8 * tint index (decoded in finish())."""
    return cell + 8 * PAL_NAMES.index(tint)


# --- Mesh building ----------------------------------------------------------------

class Piece:
    def __init__(self, name):
        self.name = name
        self.bm = bmesh.new()
        self.sign_faces = {}  # face -> sign index (explicit UVs)

    def box(self, x0, x1, y0, y1, z0, z1, m, bevel=0.0, skip=()):
        """Axis-aligned box. skip: faces to leave out ("-x","+x","-y","+y","-z","+z")."""
        bm = self.bm
        c = [Vector((x, y, z)) for z in (z0, z1) for y in (y0, y1) for x in (x0, x1)]
        v = [bm.verts.new(p) for p in c]
        quads = {
            "-z": (0, 2, 3, 1), "+z": (4, 5, 7, 6), "-y": (0, 1, 5, 4),
            "+y": (2, 6, 7, 3), "-x": (0, 4, 6, 2), "+x": (1, 3, 7, 5),
        }
        faces = []
        for k, q in quads.items():
            if k in skip:
                continue
            f = bm.faces.new([v[i] for i in q])
            f.material_index = m
            faces.append(f)
        if bevel > 0.0:
            edges = {e for f in faces for e in f.edges if len(e.link_faces) == 2}
            bmesh.ops.bevel(bm, geom=list(edges), offset=bevel, segments=1,
                            affect="EDGES", clamp_overlap=True)
        return faces

    def xform_box(self, size, matrix, m, bevel=0.0):
        """A centred box of `size`, then transformed by `matrix` (for rotated parts)."""
        before = set(self.bm.verts)
        sx, sy, sz = size[0] / 2, size[1] / 2, size[2] / 2
        self.box(-sx, sx, -sy, sy, -sz, sz, m, bevel)
        new = [v for v in self.bm.verts if v not in before]
        bmesh.ops.transform(self.bm, matrix=matrix, verts=new)

    def cyl(self, r, z0, z1, m, x=0.0, y=0.0, segs=8, axis="Z", caps=True, r2=None):
        before = set(self.bm.verts)
        h = z1 - z0
        bmesh.ops.create_cone(self.bm, cap_ends=caps, segments=segs, radius1=r,
                              radius2=r if r2 is None else r2, depth=h)
        new = [v for v in self.bm.verts if v not in before]
        rot = {"Z": Matrix.Identity(4), "X": Matrix.Rotation(math.pi / 2, 4, "Y"),
               "Y": Matrix.Rotation(math.pi / 2, 4, "X")}[axis]
        mid = (z0 + z1) / 2
        loc = {"Z": (x, y, mid), "X": (mid, x, y), "Y": (x, mid, y)}[axis]
        bmesh.ops.transform(self.bm, matrix=Matrix.Translation(loc) @ rot, verts=new)
        for f in {f for v in new for f in v.link_faces}:
            f.material_index = m

    def prism(self, pts, plane, d0, d1, m, caps=True):
        """Extrudes polygon `pts` (2D, counter-clockwise) lying in `plane` ("XZ",
        "XY" or "YZ") from depth d0 to d1 along the third axis."""
        def P(p, d):
            if plane == "XZ":
                return Vector((p[0], d, p[1]))
            if plane == "XY":
                return Vector((p[0], p[1], d))
            return Vector((d, p[0], p[1]))  # YZ
        bm = self.bm
        a = [bm.verts.new(P(p, d0)) for p in pts]
        b = [bm.verts.new(P(p, d1)) for p in pts]
        n = len(pts)
        for i in range(n):
            j = (i + 1) % n
            f = bm.faces.new((a[i], a[j], b[j], b[i]))
            f.material_index = m
        if caps:
            for ring in (a, list(reversed(b))):
                f = bm.faces.new(ring)
                f.material_index = m
        bmesh.ops.recalc_face_normals(bm, faces=list({f for v in a + b for f in v.link_faces}))

    def sign_quad(self, x0, x1, z0, z1, y, sign_index):
        """Front-facing (-Y) quad showing sign `sign_index` from the atlas."""
        bm = self.bm
        v = [bm.verts.new(Vector(p)) for p in ((x0, y, z0), (x1, y, z0), (x1, y, z1), (x0, y, z1))]
        f = bm.faces.new(v)
        f.material_index = mi(SIGN)
        self.sign_faces[f] = sign_index
        return f

    def finish(self):
        """Builds the Blender object: cell UVs (box projection), tint/cell colours."""
        bm = self.bm
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.0005)
        bm.normal_update()
        uv = bm.loops.layers.uv.new("tile")
        bm.loops.layers.uv.new("ao")
        col = bm.loops.layers.float_color.new("col")
        sign_uv = {}
        for f, s in self.sign_faces.items():
            if f.is_valid:
                sign_uv[f] = s
        for f in bm.faces:
            cell = f.material_index % 8
            code = (f.material_index + 0.5) / 128.0  # cell + 8 * palette index
            rep = CELLS[cell][5]
            n = f.normal
            ax, ay, az = abs(n.x), abs(n.y), abs(n.z)
            for loop in f.loops:
                p = loop.vert.co
                if f in sign_uv:
                    continue
                if az >= ax and az >= ay:
                    u, v = p.x, p.y * (1 if n.z > 0 else -1)
                elif ax >= ay:
                    u, v = -p.y * (1 if n.x > 0 else -1), p.z
                else:
                    u, v = p.x * (1 if n.y < 0 else -1), p.z
                loop[uv].uv = (u / rep, v / rep)
                loop[col] = (1.0, 1.0, 1.0, code)
            if f in sign_uv:
                s = sign_uv[f]
                # Sign s: column s % 2, row s // 2 (row 0 at the top of the cell).
                cx, cy = s % 2, s // 2
                u0, u1 = cx * 0.5 + 0.004, cx * 0.5 + 0.496
                v1, v0 = 1.0 - cy * 0.25 - 0.008, 1.0 - (cy + 1) * 0.25 + 0.008
                for loop, (a, b) in zip(f.loops, ((u0, v0), (u1, v0), (u1, v1), (u0, v1))):
                    loop[uv].uv = (a, b)
                    loop[col] = (1.0, 1.0, 1.0, (SIGN + 0.5) / 128.0)
            f.material_index = 0
        bmesh.ops.triangulate(bm, faces=bm.faces[:], quad_method="BEAUTY", ngon_method="BEAUTY")
        me = bpy.data.meshes.new(self.name)
        bm.to_mesh(me)
        bm.free()
        me.color_attributes.active_color = me.color_attributes["col"]
        me.color_attributes.render_color_index = me.color_attributes.find("col")
        me.uv_layers["tile"].active_render = True
        ob = bpy.data.objects.new(self.name, me)
        bpy.context.scene.collection.objects.link(ob)
        return ob


# --- The pieces ---------------------------------------------------------------------
# Each builder takes hi (True = LOD0 with bevels and small parts).

def b(hi, size):
    return size if hi else 0.0


def wall(name, hi, H, T, body, L=4.0, broken=False):
    """A 4 m wall segment: concrete plinth, body, concrete coping on top."""
    p = Piece(name)
    t = T / 2
    p.box(-L / 2, L / 2, -t - 0.05, t + 0.05, 0.0, 0.35, mi(CONCRETE, "concrete"), b(hi, 0.03), skip=("-z",))
    if not broken:
        p.box(-L / 2, L / 2, -t, t, 0.35, H - 0.18, mi(body), skip=("-z", "+z"))
        p.box(-L / 2, L / 2, -t - 0.07, t + 0.07, H - 0.18, H, mi(CONCRETE, "concrete"), b(hi, 0.035))
        if hi:
            # Drip groove line under the coping and a few chipped coping corners.
            p.box(-L / 2, L / 2, -t - 0.015, -t, H - 0.24, H - 0.2, mi(CONCRETE, "darkmetal"))
            p.box(-L / 2, L / 2, t, t + 0.015, H - 0.24, H - 0.2, mi(CONCRETE, "darkmetal"))
        return p.finish()
    # Broken: jagged top edge, coping only over the intact part, bricks at the foot.
    top = H - 0.18
    pts = [(-L / 2, 0.35), (L / 2, 0.35), (L / 2, top), (L / 2 - 0.35, top - 0.15), (1.2, top - 0.35),
           (0.75, top - 0.75), (0.2, top - 0.55), (-0.35, top - 0.9), (-0.8, top - 0.55),
           (-1.15, top - 0.35), (-1.45, top - 0.12), (-1.6, top)]
    if not hi:
        pts = [pts[0], pts[1], pts[2], pts[5], pts[7], pts[9], pts[11]]
    # Front face at -t: prism from y=-t to y=+t (XZ points are CCW seen from -Y).
    p.prism(pts, "XZ", -t, t, mi(body))
    p.box(-L / 2, -1.6, -t - 0.07, t + 0.07, top, H, mi(CONCRETE, "concrete"), b(hi, 0.035))
    p.box(L / 2 - 0.25, L / 2, -t - 0.07, t + 0.07, top, H, mi(CONCRETE, "concrete"), b(hi, 0.02))
    if hi:
        # Fallen chunks: a few bricks/blocks lying at the foot on both sides.
        import random
        rnd = random.Random(len(name))
        for side in (-1, 1):
            for i in range(5):
                x = rnd.uniform(-0.9, 1.2)
                y = side * (t + 0.12 + rnd.uniform(0.0, 0.45))
                s = (rnd.uniform(0.18, 0.32), rnd.uniform(0.1, 0.16), rnd.uniform(0.07, 0.1))
                m = Matrix.Translation((x, y, s[2] / 2)) @ Matrix.Rotation(rnd.uniform(0, 3.1), 4, "Z")
                p.xform_box(s, m, mi(body))
    return p.finish()


def pillar(name, hi, H, T, body):
    p = Piece(name)
    t = T / 2 + 0.12
    p.box(-0.4, 0.4, -t - 0.05, t + 0.05, 0.0, 0.4, mi(CONCRETE, "concrete"), b(hi, 0.03), skip=("-z",))
    p.box(-0.35, 0.35, -t, t, 0.4, H + 0.1, mi(body), b(hi, 0.02), skip=("-z",))
    p.box(-0.42, 0.42, -t - 0.07, t + 0.07, H + 0.1, H + 0.26, mi(CONCRETE, "concrete"), b(hi, 0.035))
    if hi:
        p.box(-0.3, 0.3, -t + 0.05, t - 0.05, H + 0.26, H + 0.36, mi(CONCRETE, "concrete"), 0.03)
    return p.finish()


def wh_wall(name, hi, window=False, H=7.0, T=0.5, L=4.0, base=True):
    """Warehouse wall: concrete base, corrugated cladding, metal flashing on top.
    window: a band of high windows (frames on both faces)."""
    p = Piece(name)
    t = T / 2
    zb = 1.2 if base else 0.0
    if base:
        p.box(-L / 2, L / 2, -t - 0.04, t + 0.04, 0.0, 1.2, mi(CONCRETE, "concrete"), b(hi, 0.025), skip=("-z",))
    if hi and base:
        p.box(-L / 2, L / 2, -t - 0.06, t + 0.06, 1.2, 1.26, mi(METAL, "darkmetal"))   # base flashing
    p.box(-L / 2, L / 2, -t, t, zb, H - 0.3, mi(CORRUGATED), skip=() if not base else ("-z", "+z"))
    p.box(-L / 2, L / 2, -t - 0.08, t + 0.08, H - 0.3, H, mi(METAL, "darkmetal"), b(hi, 0.02))
    if window:
        z0, z1, w = 4.4, 5.5, 1.5
        for y, s in ((-t, -1), (t, 1)):
            d = 0.07 * s
            m = mi(METAL, "steel")
            # Glass (dark), then the frame around it and a centre mullion.
            yy = y + 0.006 * s
            p.box(-w, w, min(y, yy), max(y, yy), z0, z1, mi(METAL, "glass"))
            p.box(-w - 0.08, w + 0.08, min(y, y + d), max(y, y + d), z1, z1 + 0.08, m, b(hi, 0.012))
            p.box(-w - 0.08, w + 0.08, min(y, y + d * 1.6), max(y, y + d * 1.6), z0 - 0.1, z0, m, b(hi, 0.012))
            p.box(-w - 0.08, -w, min(y, y + d), max(y, y + d), z0, z1, m, b(hi, 0.012))
            p.box(w, w + 0.08, min(y, y + d), max(y, y + d), z0, z1, m, b(hi, 0.012))
            for x in ((-0.75, 0.0, 0.75) if hi else (0.0,)):
                p.box(x - 0.03, x + 0.03, min(y, y + d * 0.6), max(y, y + d * 0.6), z0, z1, m)
    return p.finish()


def wh_column(name, hi, H=7.0):
    """Steel I-column standing against a wall (wall surface at y=0, column toward -Y)."""
    p = Piece(name)
    m = mi(METAL, "blue")
    f, d = 0.16, 0.32
    p.box(-f, f, -0.03, 0.0, 0.0, H, m, b(hi, 0.008))        # back flange
    p.box(-f, f, -d, -d + 0.03, 0.0, H, m, b(hi, 0.008))     # front flange
    p.box(-0.015, 0.015, -d + 0.03, -0.03, 0.0, H, m)        # web
    if hi:
        p.box(-0.22, 0.22, -d - 0.05, 0.0, 0.0, 0.02, mi(METAL, "darkmetal"))   # base plate
        for z in (2.0, 4.5):
            p.box(-0.08, 0.08, -d - 0.02, -d, z, z + 0.6, mi(METAL, "yellow"))  # hazard paint
    return p.finish()


def wh_door_frame(name, hi, W=8.0, H=5.0, T=0.5):
    """Frame around the 8 x 5 m loading door (opening centred on x, wall depth T)."""
    p = Piece(name)
    t = T / 2
    m = mi(METAL, "darkmetal")
    for s in (-1, 1):
        x0, x1 = s * W / 2, s * (W / 2 + 0.3)
        p.box(min(x0, x1), max(x0, x1), -t - 0.1, t + 0.1, 0.0, H, m, b(hi, 0.02))
        # Yellow impact guards at the bottom of the jambs.
        p.box(min(x0, x1) - 0.02, max(x0, x1) + 0.02, -t - 0.14, t + 0.14, 0.0, 1.0, mi(METAL, "yellow"), b(hi, 0.02))
    p.box(-W / 2 - 0.3, W / 2 + 0.3, -t - 0.1, t + 0.1, H - 0.3, H, m, b(hi, 0.02))
    # Shutter housing inside, and the shutter rolled almost all the way up.
    p.box(-W / 2, W / 2, t + 0.1, t + 0.6, H - 0.7, H - 0.15, mi(METAL, "steel"), b(hi, 0.03))
    p.box(-W / 2 + 0.05, W / 2 - 0.05, -0.04, 0.04, H - 0.9, H - 0.3, mi(CORRUGATED, "steel"))
    if hi:
        p.box(-W / 2 + 0.05, W / 2 - 0.05, -0.06, 0.06, H - 0.98, H - 0.9, mi(METAL, "darkmetal"), 0.015)
        # Rubber dock bumpers either side, outside.
        for s in (-1, 1):
            x = s * (W / 2 + 0.6)
            p.box(x - 0.15, x + 0.15, -t - 0.25, -t, 0.9, 1.35, mi(METAL, "rubber"), 0.03)
    return p.finish()


def truss(name, hi, span=27.0):
    """Roof truss across the warehouse (span along Y), top at z=0 (hung under the roof)."""
    p = Piece(name)
    m = mi(METAL, "darkmetal")
    h = 0.7
    p.box(-0.08, 0.08, -span / 2, span / 2, -0.1, 0.0, m)          # top chord
    p.box(-0.08, 0.08, -span / 2, span / 2, -h, -h + 0.1, m)       # bottom chord
    n = 14 if hi else 7
    for i in range(n):
        y0 = -span / 2 + span * i / n
        y1 = -span / 2 + span * (i + 1) / n
        p.box(-0.03, 0.03, y0 - 0.03, y0 + 0.03, -h + 0.1, -0.1, m)     # vertical
        if hi:
            # Diagonal brace.
            dy, dz = y1 - y0, h - 0.2
            ln = math.hypot(dy, dz)
            ang = math.atan2(dz, dy) * (1 if i % 2 == 0 else -1)
            mx = Matrix.Translation((0, (y0 + y1) / 2, -h / 2)) @ Matrix.Rotation(ang, 4, "X")
            p.xform_box((0.05, ln, 0.05), mx, m)
    return p.finish()


def roof_sheet(name, hi, L=4.0):
    """4 x 4 m corrugated roof panel, 0.15 thick, top at z=0 (both faces)."""
    p = Piece(name)
    p.box(-L / 2, L / 2, -L / 2, L / 2, -0.15, 0.0, mi(CORRUGATED, "darkmetal"))
    if hi:
        p.box(-L / 2, L / 2, -0.06, 0.06, -0.3, -0.15, mi(METAL, "darkmetal"))   # purlin under the panel
    return p.finish()


def shed(name, hi, W=8.0, D=5.0, H=6.0):
    """The yard's storage shed: concrete base, corrugated walls, roller door,
    windows, flat roof with parapet, gutter and downpipes, AC unit, sign."""
    p = Piece(name)
    w, d = W / 2, D / 2
    p.box(-w, w, -d, d, 0.0, 0.6, mi(CONCRETE, "concrete"), b(hi, 0.03), skip=("-z",))
    p.box(-w + 0.04, w - 0.04, -d + 0.04, d - 0.04, 0.6, H - 0.5, mi(CORRUGATED, "steel"), skip=("-z", "+z"))
    # Parapet with metal capping, overhanging a little at the front.
    p.box(-w - 0.08, w + 0.08, -d - 0.25, d + 0.08, H - 0.5, H - 0.05, mi(CONCRETE, "concrete"), b(hi, 0.03))
    p.box(-w - 0.12, w + 0.12, -d - 0.29, d + 0.12, H - 0.05, H, mi(METAL, "darkmetal"), b(hi, 0.015))
    fy = -d + 0.04  # front wall surface
    # Roller door 3.2 x 3.4 with frame and housing.
    dm = mi(METAL, "darkmetal")
    p.box(-1.7, 1.7, fy - 0.03, fy, 0.6, 3.6, mi(CORRUGATED, "blue"))
    p.box(-1.9, -1.7, fy - 0.12, fy, 0.6, 3.8, dm, b(hi, 0.015))
    p.box(1.7, 1.9, fy - 0.12, fy, 0.6, 3.8, dm, b(hi, 0.015))
    p.box(-1.9, 1.9, fy - 0.35, fy, 3.6, 4.0, mi(METAL, "steel"), b(hi, 0.03))
    if hi:
        p.box(-1.65, 1.65, fy - 0.06, fy - 0.03, 0.6, 0.72, mi(METAL, "rubber"))
        p.box(-0.3, 0.3, fy - 0.07, fy - 0.03, 1.05, 1.12, mi(METAL, "steel"), 0.01)   # handle
    # Windows either side of the door.
    for x in (-3.0, 3.0):
        window(p, hi, x, fy, 2.4, 1.1, 0.9, boarded=(x > 0))
    # Sign over the door.
    p.box(-1.3, 1.3, fy - 0.08, fy, 4.15, 4.85, dm, b(hi, 0.01))
    p.sign_quad(-1.25, 1.25, 4.2, 4.8, fy - 0.081, 3)
    # Gutter along the front and downpipes at the front corners.
    p.box(-w - 0.1, w + 0.1, -d - 0.45, -d - 0.29, H - 0.62, H - 0.5, mi(METAL, "steel"), b(hi, 0.01))
    for x in (-w + 0.25, w - 0.25):
        p.cyl(0.06, 0.15, H - 0.6, mi(METAL, "steel"), x=x, y=-d - 0.37, segs=8 if hi else 6)
        if hi:
            for z in (1.5, 3.5):
                p.box(x - 0.08, x + 0.08, -d - 0.37, fy, z, z + 0.05, mi(METAL, "darkmetal"))
            p.box(x - 0.07, x + 0.07, -d - 0.6, -d - 0.3, 0.12, 0.25, mi(METAL, "steel"), 0.01)  # shoe
    # AC unit on the east side wall, a vent on the west side.
    ex = w - 0.04
    p.box(ex, ex + 0.55, -0.5, 0.5, 2.2, 2.9, mi(METAL, "paint_white"), b(hi, 0.03))
    if hi:
        p.box(ex + 0.55, ex + 0.57, -0.4, 0.4, 2.3, 2.8, mi(METAL, "black"))
        p.box(ex, ex + 0.5, -0.45, -0.4, 2.0, 2.2, mi(METAL, "darkmetal"))
        p.box(ex, ex + 0.5, 0.4, 0.45, 2.0, 2.2, mi(METAL, "darkmetal"))
        p.cyl(0.03, 0.6, 2.2, mi(METAL, "darkmetal"), x=ex + 0.06, y=0.3, segs=6)
        p.box(-w - 0.08, -w + 0.04, -0.4, 0.4, 3.8, 4.4, mi(METAL, "steel"), 0.015)
    return p.finish()


def window(p, hi, x, fy, z0, w, h, boarded=False):
    """Window in a wall whose front surface is at y=fy (front = -Y)."""
    m = mi(METAL, "paint_white")
    x0, x1 = x - w / 2, x + w / 2
    p.box(x0, x1, fy - 0.01, fy, z0, z0 + h, mi(METAL, "glass"))
    f = 0.07
    p.box(x0 - f, x1 + f, fy - 0.08, fy, z0 + h, z0 + h + f, m, b(hi, 0.012))
    p.box(x0 - f, x0, fy - 0.08, fy, z0, z0 + h, m, b(hi, 0.012))
    p.box(x1, x1 + f, fy - 0.08, fy, z0, z0 + h, m, b(hi, 0.012))
    p.box(x0 - 0.12, x1 + 0.12, fy - 0.16, fy, z0 - 0.08, z0, mi(CONCRETE, "concrete"), b(hi, 0.015))  # sill
    if hi and not boarded:
        p.box(x - 0.025, x + 0.025, fy - 0.05, fy, z0, z0 + h, m)
        p.box(x0, x1, fy - 0.05, fy, z0 + h * 0.5 - 0.025, z0 + h * 0.5 + 0.025, m)
    if boarded:
        for i, (zz, ang) in enumerate(((0.2, 0.12), (0.5, -0.08), (0.78, 0.05))):
            mx = Matrix.Translation((x, fy - 0.1, z0 + h * zz)) @ Matrix.Rotation(ang, 4, "Y")
            p.xform_box((w + 0.3, 0.03, 0.16), mx, mi(WOOD), b(hi, 0.008))


def container(name, hi, L=6.1, H=2.6, W=2.44):
    """Shipping container: corrugated side walls (real ridges), corner posts,
    rails, door end with locking bars. Tinted per instance in Godot."""
    p = Piece(name)
    l, w = L / 2, W / 2
    pm = mi(METAL)
    post = 0.16
    # Corrugated long sides: zigzag outline in the XY plane, extruded up.
    ridge = 0.3 if hi else 0.6
    n = int((L - 2 * post) / ridge)
    for s in (-1, 1):
        y_out, depth = s * w, 0.05 if hi else 0.0
        pts_out = []
        for i in range(n + 1):
            x = -l + post + i * (L - 2 * post) / n
            pts_out.append((x, y_out - s * (depth if i % 2 else 0.0)))
        inner = [(x, y_out - s * 0.09) for x, _ in reversed(pts_out)]
        pts = pts_out + inner
        if s > 0:
            pts = list(reversed(pts))
        p.prism(pts, "XY", 0.12, H - 0.12, mi(CORRUGATED), caps=False)
    # Back end (corrugated, flat here), roof, floor.
    p.box(-l, -l + 0.06, -w + post, w - post, 0.12, H - 0.12, mi(CORRUGATED))
    p.box(-l + post, l - post, -w + 0.05, w - 0.05, H - 0.13, H - 0.03, mi(CORRUGATED))
    # Door end: two doors with locking bars and hinges.
    p.box(l - 0.06, l, -w + post, w - post, 0.12, H - 0.12, mi(CORRUGATED))
    if hi:
        p.box(l, l + 0.01, -0.01, 0.01, 0.15, H - 0.15, mi(METAL, "darkmetal"))  # door gap
        for yb in (-0.85, -0.3, 0.3, 0.85):
            p.cyl(0.022, 0.2, H - 0.2, mi(METAL, "steel"), x=l + 0.04, y=yb, segs=6)
            p.box(l, l + 0.07, yb - 0.04, yb + 0.04, 0.95, 1.05, mi(METAL, "steel"))
            p.box(l + 0.04, l + 0.08, yb - 0.02, yb + 0.25, 1.0, 1.04, mi(METAL, "steel"))  # handle
    # Corner posts and top/bottom rails (frame).
    for x in (-l, l - post):
        for y in (-w, w - post):
            p.box(x, x + post, y, y + post, 0.0, H, pm, b(hi, 0.015))
    for z0, z1 in ((0.0, 0.14), (H - 0.12, H)):
        for y in (-w, w - 0.1):
            p.box(-l + post, l - post, y, y + 0.1, z0, z1, pm, b(hi, 0.01))
        for x in (-l, l - 0.1):
            p.box(x, x + 0.1, -w + post, w - post, z0, z1, pm, b(hi, 0.01))
    if hi:
        # Corner castings (darker blocks).
        for x in (-l - 0.01, l - 0.17):
            for y in (-w - 0.01, w - 0.17):
                for z in (0.0, H - 0.12):
                    p.box(x, x + 0.18, y, y + 0.18, z, z + 0.12, mi(METAL, "darkmetal"))
    return p.finish()


def barrier(name, hi, L=3.0, broken=False):
    """Jersey barrier, 1 m tall, 0.6 m wide base (along Y)."""
    p = Piece(name)
    prof = [(-0.3, 0.0), (0.3, 0.0), (0.3, 0.08), (0.17, 0.3), (0.09, 0.95), (0.06, 1.0),
            (-0.06, 1.0), (-0.09, 0.95), (-0.17, 0.3), (-0.3, 0.08)]
    if not hi:
        prof = [(-0.3, 0.0), (0.3, 0.0), (0.3, 0.08), (0.17, 0.3), (0.07, 1.0), (-0.07, 1.0), (-0.17, 0.3), (-0.3, 0.08)]
    # Profile in the YZ plane, extruded along X.
    x0, x1 = -L / 2, L / 2
    if broken:
        x1 = L / 2 - 0.4
    p.prism(prof, "YZ", x0, x1, mi(CONCRETE, "concrete"))
    if broken:
        # The broken end: a lower jagged stub and some rebar sticking out.
        stub = [(-0.3, 0.0), (0.3, 0.0), (0.3, 0.08), (0.2, 0.25), (0.05, 0.42), (-0.12, 0.3), (-0.3, 0.08)]
        p.prism(stub, "YZ", x1, L / 2, mi(CONCRETE, "concrete"))
        if hi:
            for y, z in ((-0.05, 0.6), (0.06, 0.75)):
                mx = Matrix.Translation((x1 + 0.12, y, z)) @ Matrix.Rotation(0.5, 4, "Y")
                p.xform_box((0.4, 0.02, 0.02), mx, mi(METAL, "darkmetal"))
    if hi:
        # Lifting slots at the base.
        for x in (-L / 4, L / 4):
            p.box(x - 0.2, x + 0.2, -0.31, 0.31, 0.0, 0.08, mi(METAL, "black"), skip=("-z", "+z"))
    return p.finish()


def crate(name, hi, S=1.2):
    """Metal crate: beveled frame along every edge and inset panels."""
    p = Piece(name)
    s = S / 2
    f = 0.08
    m = mi(METAL, "steel")
    p.box(-s + 0.03, s - 0.03, -s + 0.03, s - 0.03, 0.03, S - 0.03, mi(METAL, "darkmetal"), skip=("-z",))
    for x in (-s, s - f):
        for y in (-s, s - f):
            p.box(x, x + f, y, y + f, 0.0, S, m, b(hi, 0.012))
    for z in (0.0, S - f):
        for y in (-s, s - f):
            p.box(-s + f, s - f, y, y + f, z, z + f, m, b(hi, 0.012))
        for x in (-s, s - f):
            p.box(x, x + f, -s + f, s - f, z, z + f, m, b(hi, 0.012))
    if hi:
        # Diagonal brace on two sides and stencil-like latch plates.
        ln = math.hypot(S - 2 * f, S - 2 * f)
        for y in (-s + 0.015, s - 0.015):
            mx = Matrix.Translation((0, y, S / 2)) @ Matrix.Rotation(math.pi / 4, 4, "Y")
            p.xform_box((ln, 0.03, 0.06), mx, m)
        for x in (-s + 0.015, s - 0.015):
            p.box(x - 0.012, x + 0.012, -0.12, 0.12, S * 0.55, S * 0.7, mi(METAL, "darkmetal"))
    return p.finish()


def dumpster(name, hi, L=1.9, H=1.3, W=1.1):
    p = Piece(name)
    l, w = L / 2, W / 2
    m = mi(METAL, "green")
    # Tapered body (narrower at the bottom), profile in YZ, extruded along X.
    prof = [(-w + 0.12, 0.15), (w - 0.05, 0.15), (w, H - 0.12), (-w, H - 0.12)]
    p.prism(prof, "YZ", -l, l, m)
    # Rim and the two lids (sloping toward the front).
    p.box(-l - 0.04, l + 0.04, -w - 0.04, w + 0.04, H - 0.14, H - 0.06, mi(METAL, "darkmetal"), b(hi, 0.015))
    for x0, x1, ang in ((-l, -0.01, 0.06), (0.01, l, 0.0 if hi else 0.06)):
        mx = Matrix.Translation(((x0 + x1) / 2, 0.0, H - 0.02)) @ Matrix.Rotation(ang, 4, "X")
        p.xform_box((x1 - x0, W + 0.06, 0.05), mx, mi(METAL, "black"), b(hi, 0.012))
    if hi:
        # Lift pockets on the sides, wheels.
        for s in (-1, 1):
            p.box(s * l - 0.06 if s > 0 else -l - 0.06, s * l + 0.06 if s > 0 else -l + 0.06,
                  -0.35, 0.35, 0.75, 0.9, mi(METAL, "darkmetal"), 0.01)
        for x in (-l + 0.2, l - 0.2):
            for y in (-w + 0.25, w - 0.2):
                p.cyl(0.075, y - 0.03, y + 0.03, mi(METAL, "rubber"), x=x, y=0.075, axis="Y", segs=8)
                p.box(x - 0.05, x + 0.05, y - 0.05, y + 0.05, 0.075, 0.16, mi(METAL, "darkmetal"))
    return p.finish()


def pipe_v(name, hi):
    """1 m of vertical downpipe 0.12 m from the wall, with a wall bracket.
    Scaled along its height in Godot."""
    p = Piece(name)
    p.cyl(0.06, 0.0, 1.0, mi(METAL, "steel"), y=-0.14, segs=8, caps=False)
    if hi:
        p.box(-0.075, 0.075, -0.16, 0.0, 0.48, 0.52, mi(METAL, "darkmetal"))
    return p.finish()


def pipe_h(name, hi):
    """1 m of horizontal pipe along X, 0.2 m from the wall, on a bracket."""
    p = Piece(name)
    p.cyl(0.09, -0.5, 0.5, mi(METAL, "darkmetal"), x=-0.2, y=0.0, axis="X", segs=8, caps=False)
    if hi:
        p.box(-0.04, 0.04, -0.2, 0.0, -0.13, -0.09, mi(METAL, "darkmetal"))
        p.cyl(0.1, -0.02, 0.02, mi(METAL, "steel"), x=-0.2, y=0.0, axis="X", segs=8)  # collar
    return p.finish()


def pipe_elbow(name, hi):
    """Bend from a vertical pipe (going down) to the wall: top cap with shoe."""
    p = Piece(name)
    # Vertical stub, a 45 degree piece and a stub into the wall.
    p.cyl(0.06, 0.0, 0.25, mi(METAL, "steel"), y=-0.14, segs=8, caps=False)
    mx = Matrix.Translation((0, -0.08, 0.33)) @ Matrix.Rotation(math.radians(-45), 4, "X")
    p.xform_box((0.12, 0.12, 0.24), mx, mi(METAL, "steel"), b(hi, 0.03))
    p.cyl(0.06, -0.05, 0.0, mi(METAL, "steel"), x=0.0, y=0.4, axis="Y", segs=8)
    return p.finish()


def sign_board(name, hi, sign_index, w, h, post=False):
    """Wall sign: metal backing board with the printed face (wall surface at y=0)."""
    p = Piece(name)
    p.box(-w / 2 - 0.03, w / 2 + 0.03, -0.05, 0.0, -0.03, h + 0.03, mi(METAL, "darkmetal"), b(hi, 0.01))
    p.sign_quad(-w / 2, w / 2, 0.0, h, -0.051, sign_index)
    if hi:
        for x in (-w / 2 + 0.08, w / 2 - 0.08):
            for z in (0.06, h - 0.06):
                p.box(x - 0.012, x + 0.012, -0.058, -0.05, z - 0.012, z + 0.012, mi(METAL, "steel"))
    return p.finish()


def blade_sign(name, hi, sign_index, w=1.2, h=0.4):
    """Hanging shop sign sticking out of a wall (both faces printed)."""
    p = Piece(name)
    m = mi(METAL, "black")
    p.box(-0.02, 0.02, -w - 0.15, 0.0, h + 0.08, h + 0.12, m)           # arm
    p.box(-0.1, 0.1, -0.03, 0.0, h - 0.05, h + 0.2, m, b(hi, 0.01))    # wall plate
    p.box(-0.02, 0.02, -w - 0.1, -0.1, 0.0, h, mi(METAL, "darkmetal"))
    # Printed faces on both sides: the sign quad builder faces -Y, so build
    # it flat and rotate each copy to face +-X.
    for ang in (math.pi / 2, -math.pi / 2):
        before = set(p.bm.faces)
        f = p.sign_quad(-w / 2, w / 2, 0.0, h, 0.0, sign_index)
        mx = Matrix.Translation((0, -w / 2 - 0.1, 0)) @ Matrix.Rotation(ang, 4, "Z") @ Matrix.Translation((0, -0.021, 0))
        bmesh.ops.transform(p.bm, matrix=mx, verts=list(f.verts))
    if hi:
        for y in (-0.35, -w + 0.15):
            p.cyl(0.006, h, h + 0.08, m, x=0.0, y=y, segs=4, caps=False)
    return p.finish()


def ac_unit(name, hi):
    """Wall AC unit / electrical cabinet (wall surface at y=0)."""
    p = Piece(name)
    p.box(-0.45, 0.45, -0.5, 0.0, 0.0, 0.65, mi(METAL, "paint_white"), b(hi, 0.025))
    if hi:
        p.box(-0.32, 0.32, -0.51, -0.5, 0.08, 0.56, mi(METAL, "black"))   # grille
        p.cyl(0.24, -0.53, -0.51, mi(METAL, "darkmetal"), x=0.0, y=0.32, axis="Y", segs=10)
        p.cyl(0.025, 0.0, 0.0001, mi(METAL, "darkmetal"))
        for x in (-0.38, 0.38):
            p.box(x - 0.03, x + 0.03, -0.55, 0.0, -0.06, 0.0, mi(METAL, "darkmetal"))
        p.cyl(0.025, -0.6, 0.0, mi(METAL, "darkmetal"), x=0.36, y=-0.04, segs=6, caps=False)
    return p.finish()


def lamp_wall(name, hi):
    """Wall lamp housing (bulb glow is a separate Godot mesh)."""
    p = Piece(name)
    p.box(-0.12, 0.12, -0.05, 0.0, -0.15, 0.15, mi(METAL, "darkmetal"), b(hi, 0.01))
    p.box(-0.04, 0.04, -0.4, -0.05, 0.05, 0.1, mi(METAL, "darkmetal"))
    p.box(-0.2, 0.2, -0.6, -0.2, 0.1, 0.16, mi(METAL, "darkmetal"), b(hi, 0.02))
    return p.finish()


# (name, builder, kwargs, has LOD1, bake setting: "ground" | "wall" | "free")
PIECES = [
    ("wall_yard", wall, dict(H=4.0, T=1.0, body=BRICK), True, "ground"),
    ("wall_yard_broken", wall, dict(H=4.0, T=1.0, body=BRICK, broken=True), True, "ground"),
    ("pillar_yard", pillar, dict(H=4.0, T=1.0, body=BRICK), True, "ground"),
    ("wall_town", wall, dict(H=3.2, T=1.0, body=BRICK), True, "ground"),
    ("wall_town_broken", wall, dict(H=3.2, T=1.0, body=BRICK, broken=True), True, "ground"),
    ("pillar_town", pillar, dict(H=3.2, T=1.0, body=BRICK), True, "ground"),
    ("wall_low", wall, dict(H=2.8, T=0.5, body=CONCRETE), True, "ground"),
    ("wall_low_broken", wall, dict(H=2.8, T=0.5, body=CONCRETE, broken=True), True, "ground"),
    ("pillar_low", pillar, dict(H=2.8, T=0.5, body=CONCRETE), True, "ground"),
    ("wh_wall", wh_wall, dict(), True, "ground"),
    ("wh_wall_window", wh_wall, dict(window=True), True, "ground"),
    ("wh_header", wh_wall, dict(H=2.0, L=8.0, base=False), False, "free"),
    ("wh_column", wh_column, dict(), False, "wall"),
    ("wh_door_frame", wh_door_frame, dict(), True, "ground"),
    ("truss", truss, dict(), True, "free"),
    ("roof_sheet", roof_sheet, dict(), False, "free"),
    ("shed", shed, dict(), True, "ground"),
    ("container", container, dict(), True, "ground"),
    ("barrier", barrier, dict(), False, "ground"),
    ("barrier_broken", barrier, dict(broken=True), False, "ground"),
    ("crate", crate, dict(), False, "ground"),
    ("dumpster", dumpster, dict(), True, "ground"),
    ("pipe_v", pipe_v, dict(), False, "wall"),
    ("pipe_h", pipe_h, dict(), False, "wall"),
    ("pipe_elbow", pipe_elbow, dict(), False, "wall"),
    ("sign_loading", sign_board, dict(sign_index=0, w=2.4, h=0.6), False, "wall"),
    ("sign_exit", sign_board, dict(sign_index=1, w=0.6, h=0.2), False, "wall"),
    ("sign_danger", sign_board, dict(sign_index=2, w=1.6, h=0.4), False, "wall"),
    ("sign_garage", sign_board, dict(sign_index=4, w=2.4, h=0.6), False, "wall"),
    ("sign_diner", blade_sign, dict(sign_index=5), False, "wall"),
    ("sign_hotel", blade_sign, dict(sign_index=6), False, "wall"),
    ("sign_pharmacy", sign_board, dict(sign_index=7, w=2.4, h=0.6), False, "wall"),
    ("ac_unit", ac_unit, dict(), False, "wall"),
    ("lamp_wall", lamp_wall, dict(), False, "wall"),
]


# --- Atlas -------------------------------------------------------------------------

def load_pixels(path):
    img = bpy.data.images.load(path)
    img.colorspace_settings.name = "Non-Color"  # copy the bytes as they are
    return img


def cell_pixels(src, w, h):
    """The source image scaled to w x h as a float array (h, w, 4)."""
    img = load_pixels(src)
    img.scale(w, h)
    a = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(a)
    bpy.data.images.remove(img)
    return a.reshape(h, w, 4)


def render_signs(w, h):
    """Renders the sign faces (text on coloured boards) with Cycles into an
    (h, w, 4) array: 2 columns x 4 rows."""
    scene = bpy.data.scenes.new("signs")
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 16
    scene.cycles.use_denoising = False
    scene.render.resolution_x = w
    scene.render.resolution_y = h
    scene.render.film_transparent = False
    scene.view_settings.view_transform = "Standard"
    scene.world = bpy.data.worlds.new("signs_world")
    scene.world.color = (0, 0, 0)
    cam_data = bpy.data.cameras.new("signs_cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 4.0   # 4 x 2 units visible (w:h = 2:1)
    cam = bpy.data.objects.new("signs_cam", cam_data)
    cam.location = (2.0, 1.0, 10.0)
    scene.collection.objects.link(cam)
    scene.camera = cam

    def emit(name, color):
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        nt = m.node_tree
        nt.nodes.clear()
        e = nt.nodes.new("ShaderNodeEmission")
        e.inputs["Color"].default_value = (*color, 1.0)
        o = nt.nodes.new("ShaderNodeOutputMaterial")
        nt.links.new(e.outputs[0], o.inputs[0])
        return m

    def rect(name, x0, y0, x1, y1, z, mat):
        me = bpy.data.meshes.new(name)
        me.from_pydata([(x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z)], [], [(0, 1, 2, 3)])
        ob = bpy.data.objects.new(name, me)
        ob.data.materials.append(mat)
        scene.collection.objects.link(ob)

    for i, (name, text, bg, fg, border) in enumerate(SIGNS):
        cx, cy = i % 2, i // 2
        x0, y1 = cx * 2.0, 2.0 - cy * 0.5
        y0, x1 = y1 - 0.5, x0 + 2.0
        rect("bg_" + name, x0, y0, x1, y1, 0.0, emit("bg_" + name, bg))
        if border:
            fgm = emit("bd_" + name, fg)
            t = 0.035
            for r in ((x0 + 0.05, y0 + 0.05, x1 - 0.05, y0 + 0.05 + t), (x0 + 0.05, y1 - 0.05 - t, x1 - 0.05, y1 - 0.05),
                      (x0 + 0.05, y0 + 0.05, x0 + 0.05 + t, y1 - 0.05), (x1 - 0.05 - t, y0 + 0.05, x1 - 0.05, y1 - 0.05)):
                rect("bd", *r, 0.01, fgm)
        cu = bpy.data.curves.new("txt_" + name, "FONT")
        cu.body = text
        cu.align_x = "CENTER"
        cu.align_y = "CENTER"
        cu.size = 0.3 if len(text) < 10 else (0.2 if len(text) < 14 else 0.16)
        cu.extrude = 0.0
        tob = bpy.data.objects.new("txt_" + name, cu)
        tob.location = ((x0 + x1) / 2, (y0 + y1) / 2, 0.02)
        tob.data.materials.append(emit("fg_" + name, fg))
        scene.collection.objects.link(tob)
        cu.space_character = 1.1
        # Exit signs read better bold-ish: slightly bigger.
        if name == "exit":
            cu.size = 0.34
    path = os.path.join(bpy.app.tempdir, "kit_signs.png")
    scene.render.filepath = path
    scene.render.image_settings.file_format = "PNG"
    bpy.context.window_manager  # noqa: keeps the context alive in background mode
    with bpy.context.temp_override(scene=scene):
        bpy.ops.render.render(write_still=True, scene=scene.name)
    img = bpy.data.images.load(path)
    img.colorspace_settings.name = "Non-Color"
    a = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(a)
    a = a.reshape(h, w, 4)
    bpy.data.scenes.remove(scene)
    # The render is in display (sRGB) space already, which is what a colour
    # texture holds. Weather it: multiply by the concrete texture as grime.
    grime = cell_pixels(os.path.join(TEX, "concrete_wall_008", "concrete_wall_008_diff_1k.jpg"), w, h)
    g = grime[:, :, :3].mean(axis=2, keepdims=True)
    g = np.clip(0.55 + g * 0.8, 0.0, 1.0)
    a[:, :, :3] *= g
    return a


def build_atlas():
    albedo = np.zeros((ATLAS, ATLAS, 4), dtype=np.float32)
    normal = np.zeros((ATLAS, ATLAS, 4), dtype=np.float32)
    albedo[:, :, 3] = 1.0
    normal[:, :, :] = (0.5, 0.5, 1.0, 1.0)
    for cell, (folder, x, y, w, h, _rep) in CELLS.items():
        px, py, pw, ph = int(x * ATLAS), int(y * ATLAS), int(w * ATLAS), int(h * ATLAS)
        if folder is None:
            albedo[py:py + ph, px:px + pw] = render_signs(pw, ph)
            continue
        d = os.path.join(TEX, folder)
        albedo[py:py + ph, px:px + pw] = cell_pixels(os.path.join(d, folder + "_diff_1k.jpg"), pw, ph)
        normal[py:py + ph, px:px + pw] = cell_pixels(os.path.join(d, folder + "_nor_gl_1k.jpg"), pw, ph)
    os.makedirs(OUT_TEX, exist_ok=True)
    save_image(albedo, os.path.join(OUT_TEX, "kit_albedo.jpg"), "JPEG")
    save_image(normal, os.path.join(OUT_TEX, "kit_normal.jpg"), "JPEG")


def save_image(arr, path, fmt, bw=False):
    h, w = arr.shape[:2]
    img = bpy.data.images.new(os.path.basename(path), w, h, alpha=False)
    img.colorspace_settings.name = "Non-Color"
    img.pixels.foreach_set(arr.astype(np.float32).ravel())
    img.filepath_raw = path
    img.file_format = fmt
    s = bpy.context.scene.render.image_settings
    s.file_format = fmt
    s.color_mode = "BW" if bw else "RGB"
    if fmt == "JPEG":
        s.quality = 90
    else:
        s.compression = 90
    img.save_render(path, scene=bpy.context.scene)
    bpy.data.images.remove(img)
    print("  wrote", os.path.relpath(path, ROOT))


# --- AO bake ---------------------------------------------------------------------------

def select_only(objs):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]


def unwrap_ao(objs, lod1):
    """Unique AO unwrap of all pieces packed into one 0-1 square. LOD1 copies
    get half the texel density (they're only seen from far away)."""
    for o in objs:
        o.data.uv_layers.active = o.data.uv_layers["ao"]
    select_only(objs)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=0.0, scale_to_bounds=False)
    bpy.ops.uv.average_islands_scale()
    bpy.ops.object.mode_set(mode="OBJECT")
    for o in objs:
        if o in lod1:
            for d in o.data.uv_layers["ao"].data:
                d.uv = d.uv * 0.5
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.select_all(action="SELECT")
    bpy.ops.uv.pack_islands(rotate=True, scale=True, margin=0.004)
    bpy.ops.object.mode_set(mode="OBJECT")


def bake_ao(objs, helpers):
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = AO_SAMPLES
    scene.world = scene.world or bpy.data.worlds.new("World")
    scene.world.light_settings.distance = 0.9
    img = bpy.data.images.new("kit_ao", ATLAS, ATLAS, alpha=False, float_buffer=False)
    img.colorspace_settings.name = "Non-Color"
    img.generated_color = (1, 1, 1, 1)
    mat = bpy.data.materials.new("bake")
    mat.use_nodes = True
    node = mat.node_tree.nodes.new("ShaderNodeTexImage")
    node.image = img
    mat.node_tree.nodes.active = node
    for o in objs:
        o.data.materials.clear()
        o.data.materials.append(mat)
        o.data.uv_layers.active = o.data.uv_layers["ao"]
    hm = bpy.data.materials.new("helper")
    for h in helpers:
        h.data.materials.append(hm)
    select_only(objs)
    bpy.ops.object.bake(type="AO", margin=4, margin_type="EXTEND", use_clear=True)
    a = np.empty(ATLAS * ATLAS * 4, dtype=np.float32)
    img.pixels.foreach_get(a)
    a = a.reshape(ATLAS, ATLAS, 4)
    ao = a[:, :, 0]
    # Soften the noise a little and keep it from going pitch black.
    k = np.array([1, 2, 1], dtype=np.float32) / 4
    for axis in (0, 1):
        ao = np.apply_along_axis(lambda m: np.convolve(np.pad(m, 1, mode="edge"), k, "valid"), axis, ao)
    ao = 0.12 + 0.88 * ao
    out = np.stack([ao, ao, ao, np.ones_like(ao)], axis=2)
    save_image(out, os.path.join(OUT_TEX, "kit_ao.png"), "PNG", bw=True)
    for o in objs:
        o.data.materials.clear()
        o.data.uv_layers.active = o.data.uv_layers["tile"]


def helper_plane(name, center, size, rot=None):
    me = bpy.data.meshes.new(name)
    sx, sy = size
    me.from_pydata([(-sx, -sy, 0), (sx, -sy, 0), (sx, sy, 0), (-sx, sy, 0)], [], [(0, 1, 2, 3)])
    ob = bpy.data.objects.new(name, me)
    ob.location = center
    if rot:
        ob.rotation_euler = rot
    bpy.context.scene.collection.objects.link(ob)
    return ob


# --- Main ----------------------------------------------------------------------------

def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    print("KIT: atlas")
    build_atlas()

    print("KIT: pieces")
    objs, lod1, helpers = [], [], []
    spacing = 32.0
    for i, (name, fn, kw, has_lod, bake) in enumerate(PIECES):
        for lod in ((0, 1) if has_lod else (0,)):
            ob = fn(name + ("_lod1" if lod else ""), lod == 0, **kw)
            # Spread the pieces out so they don't shade each other in the bake.
            ob.location = ((i % 8) * spacing, (i // 8) * spacing + lod * 200.0, 0.0)
            objs.append(ob)
            if lod:
                lod1.append(ob)
            dims = ob.dimensions
            if bake == "ground":
                helpers.append(helper_plane("ground_" + ob.name, ob.location, (dims.x / 2 + 2, dims.y / 2 + 2)))
            elif bake == "wall":
                c = ob.location + Vector((0, 0.0, dims.z / 2))
                helpers.append(helper_plane("wallbk_" + ob.name, c, (dims.x / 2 + 1, dims.z / 2 + 1),
                                            (math.pi / 2, 0, 0)))
            me = ob.data
            print("  %-22s %5d tris" % (ob.name, sum(len(p.vertices) - 2 for p in me.polygons)))

    print("KIT: AO unwrap + bake (Cycles, %d samples)" % AO_SAMPLES)
    unwrap_ao(objs, lod1)
    bake_ao(objs, helpers)

    for h in helpers:
        bpy.data.objects.remove(h)
    for o in objs:
        o.location = (0, 0, 0)
        o.data.uv_layers["tile"].active_render = True

    print("KIT: export")
    os.makedirs(os.path.dirname(OUT_GLB), exist_ok=True)
    select_only(objs)
    props = bpy.ops.export_scene.gltf.get_rna_type().properties.keys()
    kw = dict(filepath=OUT_GLB, export_format="GLB", use_selection=True, export_materials="NONE",
              export_yup=True, export_apply=True, export_tangents=True, export_normals=True,
              export_texcoords=True)
    if "export_vertex_color" in props:
        kw["export_vertex_color"] = "ACTIVE"
    if "export_all_vertex_colors" in props:
        kw["export_all_vertex_colors"] = False
    if "export_colors" in props:
        kw["export_colors"] = True
    bpy.ops.export_scene.gltf(**kw)
    print("  wrote", os.path.relpath(OUT_GLB, ROOT))
    print("KIT: done")


try:
    main()
except Exception:
    import traceback
    traceback.print_exc()
    sys.exit(1)
