extends RefCounted
## Places pieces of the modular level kit (assets/models/kit/kit.glb, made by
## tools/blender/build_kit.py) and merges them into a few meshes, for the map
## build scripts (build_level.gd, build_maps.gd).
##
## Every piece uses the same material (materials/kit.tres), so each merged
## chunk is one draw call. Pieces are grouped into CHUNK x CHUNK m cells so
## frustum culling and the LOD switch still work per area:
## - LOD0 (bevels, frames, pipes, signs) is drawn up to `lod_distance`,
##   LOD1 (the "<piece>_lod1" meshes; plain pieces without small parts) from
##   there on: Godot visibility ranges, a hard switch with a little hysteresis.
## - Small wall details (signs, pipes, AC units...) only exist in LOD0.
## The baked AO's UVs are moved to CUSTOM0 so UV2 stays free for lightmaps.
##
## Use:
##   var kit := Kit.new()
##   kit.add("wall_yard", Transform3D(...))
##   kit.build(parent, owner, "Kit", {"lod_distance": 26.0})

const KIT_GLB := "res://assets/models/kit/kit.glb"
const MATERIAL := "res://materials/kit.tres"
const CHUNK := 14.0
## Pieces that have no LOD1 mesh but must stay visible far away
## (otherwise a piece without LOD1 is only drawn up close).
const KEEP_FAR := ["roof_sheet", "wh_column", "wh_header", "barrier", "barrier_broken", "crate"]

var material: Material
var _pieces := {}      # name -> Array (surface arrays, in piece space)
var _chunks := {}      # key -> {"lod0": batch, "lod1": batch}


func _init() -> void:
	material = load(MATERIAL)
	var scene: Node3D = load(KIT_GLB).instantiate()
	for mi: MeshInstance3D in scene.find_children("*", "MeshInstance3D", true, false):
		_pieces[String(mi.name)] = [mi.mesh.surface_get_arrays(0), mi.transform]
	scene.free()


func has(piece: String) -> bool:
	return _pieces.has(piece)


## Adds a piece. `group` keeps pieces apart from others in the same area (for
## example walls that need different settings).
func add(piece: String, xf: Transform3D, tint := Color.WHITE, group := "") -> void:
	assert(_pieces.has(piece), "kit piece missing: " + piece)
	var key := "%s_%d_%d" % [group, floori(xf.origin.x / CHUNK), floori(xf.origin.z / CHUNK)]
	if not _chunks.has(key):
		_chunks[key] = {"lod0": _batch(), "lod1": _batch()}
	var c: Dictionary = _chunks[key]
	_append(c.lod0, piece, xf, tint)
	if _pieces.has(piece + "_lod1"):
		_append(c.lod1, piece + "_lod1", xf, tint)
	elif piece in KEEP_FAR:
		_append(c.lod1, piece, xf, tint)


## Creates the merged meshes under a new node `node_name` in `parent`.
## opts:
##   lod_distance  float, 0 = no LOD1 (only LOD0 meshes, always drawn)
##   lightmap      bool, GI static with lightmap UV2 (the yard)
##   shadows       bool (default true)
##   file_prefix   String: meshes are saved to res://level/generated/<prefix>_<chunk>.res
func build(parent: Node, owner_node: Node, node_name: String, opts: Dictionary) -> Node3D:
	var holder := Node3D.new()
	holder.name = node_name
	parent.add_child(holder)
	holder.owner = owner_node
	var lod_d: float = opts.get("lod_distance", 0.0)
	var keys := _chunks.keys()
	keys.sort()
	var tris := [0, 0]
	for key: String in keys:
		var c: Dictionary = _chunks[key]
		for lod in ([0, 1] if lod_d > 0.0 else [0]):
			var b: Dictionary = c["lod%d" % lod]
			if b.i.is_empty():
				continue
			var mesh := _commit(b, opts.get("lightmap", false))
			var path := "res://level/generated/%s%s_lod%d.res" % [opts.get("file_prefix", "kit"), key, lod]
			ResourceSaver.save(mesh, path, ResourceSaver.FLAG_COMPRESS)
			var mi := MeshInstance3D.new()
			mi.name = "Chunk%s_LOD%d" % [key, lod]
			mi.mesh = load(path)
			if opts.get("lightmap", false):
				mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
			if not opts.get("shadows", true):
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if lod_d > 0.0:
				if lod == 0:
					mi.visibility_range_end = lod_d
					mi.visibility_range_end_margin = 2.0
				else:
					mi.visibility_range_begin = lod_d
					mi.visibility_range_begin_margin = 2.0
			holder.add_child(mi)
			mi.owner = owner_node
			tris[lod] += b.i.size() / 3
	print("  kit %s: %d chunks, %d tris LOD0, %d tris LOD1" % [node_name, keys.size(), tris[0], tris[1]])
	_chunks.clear()
	return holder


func _batch() -> Dictionary:
	return {"v": PackedVector3Array(), "n": PackedVector3Array(), "t": PackedFloat32Array(),
		"c": PackedColorArray(), "uv": PackedVector2Array(), "ao": PackedFloat32Array(), "i": PackedInt32Array()}


func _append(b: Dictionary, piece: String, xf: Transform3D, tint: Color) -> void:
	var arr: Array = _pieces[piece][0]
	var full: Transform3D = xf * _pieces[piece][1]
	var nb := full.basis.inverse().transposed()
	var base: int = b.v.size()
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var t: PackedFloat32Array = arr[Mesh.ARRAY_TANGENT]
	var c: PackedColorArray = arr[Mesh.ARRAY_COLOR]
	var uv: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
	var uv2: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV2]
	for j in v.size():
		b.v.append(full * v[j])
		b.n.append((nb * n[j]).normalized())
		var tv := (full.basis * Vector3(t[j * 4], t[j * 4 + 1], t[j * 4 + 2])).normalized()
		b.t.append_array([tv.x, tv.y, tv.z, t[j * 4 + 3]])
		var col := c[j]
		# rgb holds the tint at half scale (8-bit colours), so tints up to 2 work.
		b.c.append(Color(tint.r * 0.5, tint.g * 0.5, tint.b * 0.5, col.a))
		b.uv.append(uv[j])
		b.ao.append_array([uv2[j].x, uv2[j].y])
	for j: int in arr[Mesh.ARRAY_INDEX]:
		b.i.append(base + j)


func _commit(b: Dictionary, lightmap: bool) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = b.v
	arrays[Mesh.ARRAY_NORMAL] = b.n
	arrays[Mesh.ARRAY_TANGENT] = b.t
	arrays[Mesh.ARRAY_COLOR] = b.c
	arrays[Mesh.ARRAY_TEX_UV] = b.uv
	arrays[Mesh.ARRAY_CUSTOM0] = b.ao
	arrays[Mesh.ARRAY_INDEX] = b.i
	var flags := Mesh.ARRAY_CUSTOM_RG_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	var im := ImporterMesh.new()
	im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, material, "", flags)
	if not lightmap:
		im.generate_lods(25.0, 60.0, [])
	var mesh := im.get_mesh()
	if lightmap:
		mesh = _unwrap_keep_ao(mesh, b)
	return mesh


## lightmap_unwrap() rebuilds the vertices without CUSTOM0, so the AO UVs are
## put back by matching each new vertex to the original one (same position,
## normal, UV and colour: unwrapping only splits vertices along seams).
func _unwrap_keep_ao(mesh: ArrayMesh, b: Dictionary) -> ArrayMesh:
	var ao_of := {}
	for j in b.v.size():
		ao_of[_vkey(b.v[j], b.n[j], b.uv[j], b.c[j])] = Vector2(b.ao[j * 2], b.ao[j * 2 + 1])
	mesh.lightmap_unwrap(Transform3D(), 0.2)
	var arr := mesh.surface_get_arrays(0)
	var ao := PackedFloat32Array()
	var missing := 0
	for j in arr[Mesh.ARRAY_VERTEX].size():
		var k := _vkey(arr[Mesh.ARRAY_VERTEX][j], arr[Mesh.ARRAY_NORMAL][j], arr[Mesh.ARRAY_TEX_UV][j], arr[Mesh.ARRAY_COLOR][j])
		var a: Vector2 = ao_of.get(k, Vector2(-1, -1))
		if a.x < 0.0:
			missing += 1
			a = Vector2.ZERO
		ao.append_array([a.x, a.y])
	if missing > 0:
		push_warning("kit: %d vertices lost their AO UV in the lightmap unwrap" % missing)
	arr[Mesh.ARRAY_CUSTOM0] = ao
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {},
			Mesh.ARRAY_CUSTOM_RG_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	out.surface_set_material(0, material)
	out.lightmap_size_hint = mesh.lightmap_size_hint
	return out


func _vkey(v: Vector3, n: Vector3, uv: Vector2, c: Color) -> String:
	# Rounded to ints (formatting floats would tell -0.0 from 0.0).
	return str([Vector3i((v * 1000.0).round()), Vector3i((n * 10.0).round()), Vector2i((uv * 1000.0).round()), roundi(c.a * 128.0)])


# --- Placement helpers -------------------------------------------------------------

## A wall on the ground from `a` to `b`: `segment` pieces (4 m, stretched to
## fit a whole number of them) with `pillar` pieces at every joint. Segment
## indices in `broken` use the "<segment>_broken" piece. ends: pillars at a/b.
func wall_run(a: Vector3, b: Vector3, segment: String, pillar: String, broken := [],
		tint := Color.WHITE, ends := true, seg_len := 4.3, group := "") -> void:
	var d := b - a
	var length := d.length()
	var dir := d / length
	var n := maxi(1, roundi(length / seg_len))
	var s := length / n
	var rot := Basis(Vector3.UP, atan2(-dir.z, dir.x))
	for i in n:
		var piece := segment + "_broken" if i in broken else segment
		add(piece, Transform3D(rot * Basis.from_scale(Vector3(s / 4.0, 1, 1)), a + dir * s * (i + 0.5)), tint, group)
	if pillar != "":
		for i in range(0 if ends else 1, n + 1 if ends else n):
			add(pillar, Transform3D(rot, a + dir * s * i), tint, group)


## A wall-mounted piece: `pos` on the wall surface, facing `facing` (the
## direction the wall faces), optionally scaled in piece space.
func mount(piece: String, pos: Vector3, facing: Vector3, tint := Color.WHITE, scale := Vector3.ONE, group := "") -> void:
	var rot := Basis(Vector3.UP, atan2(facing.x, facing.z))
	add(piece, Transform3D(rot * Basis.from_scale(scale), pos), tint, group)


## A vertical downpipe from the ground to `top` (1 m pipe pieces stretched).
func downpipe(pos: Vector3, facing: Vector3, top: float, group := "") -> void:
	mount("pipe_v", Vector3(pos.x, 0.0, pos.z), facing, Color.WHITE, Vector3(1, top, 1), group)
