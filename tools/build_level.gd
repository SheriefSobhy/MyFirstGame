extends SceneTree
## Builds the level's static detail and writes it into main.tscn:
## - converts the CSG boxes to MeshInstance3D + StaticBody3D with lightmap UV2
## - generates pallet / electric pole / fence / wire / rubble / grime meshes
## - merges the skyline buildings into ONE vertex-coloured mesh (1 draw call)
## - adds the LightmapGI node
## Safe to re-run: it deletes what it generated before and rebuilds it.
## Run: godot --headless --path . --script res://tools/build_level.gd
## After running it, run tools/rebake.bat to re-bake the lightmap and navmesh.

const GEN := "res://level/generated/"
const MAIN := "res://main.tscn"

const M_WOOD := preload("res://materials/wood.tres")
const M_POLE := preload("res://materials/pole_wood.tres")
const M_CERAMIC := preload("res://materials/ceramic.tres")
const M_METAL := preload("res://materials/metal_crate.tres")
const M_FENCE := preload("res://materials/fence_metal.tres")
const M_CHAIN := preload("res://materials/chainlink.tres")
const M_WIRE := preload("res://materials/wire.tres")
const M_RUBBLE := preload("res://materials/rubble.tres")
const M_SKYLINE := preload("res://materials/skyline.tres")
const M_PUDDLE := preload("res://materials/puddle.tres")

const TIRE_GLTF := "res://assets/models/polyhaven/old_tyre/old_tyre_1k.gltf"
const TRASH_GLTF := "res://assets/models/polyhaven/trashbag/trashbag_1k.gltf"
const BUILDINGS := "res://assets/models/quaternius/buildings/"
const ROCKS := ["Rock1", "Rock2", "Rock3", "Rock5"]

var done := false


func _process(_delta: float) -> bool:
	if done:
		return true
	done = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GEN))
	seed(42)
	var tire_scene := _make_tire_scene()
	var pallet_scene := _make_pallet_scene()

	var main: Node3D = load(MAIN).instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	# Not added to the tree: a running scene would change itself before being
	# saved (e.g. Timer clears `autostart` once it starts), breaking spawning.
	var level: Node3D = main.get_node("NavigationRegion3D/Level")
	_convert_csg(level, main)

	for path in ["NavigationRegion3D/Level/Clutter", "Detail", "Outside", "LightmapGI"]:
		var old := main.get_node_or_null(path)
		if old:
			old.get_parent().remove_child(old)
			old.free()

	var clutter := _add(level, Node3D.new(), "Clutter", main)
	_place_clutter(clutter, main, tire_scene, pallet_scene)
	var detail := _add(main, Node3D.new(), "Detail", main)
	main.move_child(detail, main.get_node("NavigationRegion3D").get_index() + 1)
	_place_grime(detail, main)
	_place_rubble_and_trash(detail, main)
	var outside := _add(main, Node3D.new(), "Outside", main)
	main.move_child(outside, detail.get_index() + 1)
	_build_skyline(outside, main)
	_build_poles(outside, main)
	_build_wall_fence(outside, main)


	var lm := LightmapGI.new()
	lm.quality = LightmapGI.BAKE_QUALITY_MEDIUM
	lm.bounces = 3
	lm.use_denoiser = true
	lm.max_texture_size = 2048
	lm.generate_probes_subdiv = LightmapGI.GENERATE_PROBES_SUBDIV_8
	# The Compatibility editor bakes the HDRI sky as black, so the sky light
	# is given as a colour matching the sky instead.
	lm.environment_mode = LightmapGI.ENVIRONMENT_MODE_CUSTOM_COLOR
	lm.environment_custom_color = Color(0.62, 0.7, 0.85)
	lm.environment_custom_energy = 0.9
	_add(main, lm, "LightmapGI", main)
	main.move_child(lm, main.get_node("Sun").get_index() + 1)

	var packed := PackedScene.new()
	var err := packed.pack(main)
	assert(err == OK)
	err = ResourceSaver.save(packed, MAIN)
	print("Saved main.tscn: ", error_string(err))
	main.free()
	quit()
	return true


func _add(parent: Node, child: Node, n: String, owner_node: Node) -> Node:
	child.name = n
	parent.add_child(child)
	child.owner = owner_node
	return child


func _save_mesh(mesh: Mesh, file: String) -> Mesh:
	var path := GEN + file
	ResourceSaver.save(mesh, path)
	mesh.take_over_path(path)
	return load(path)


# ---------------------------------------------------------------- CSG -> mesh

func _convert_csg(level: Node3D, main: Node) -> void:
	for csg in level.get_children():
		if not csg is CSGBox3D:
			continue
		var box := BoxMesh.new()
		box.size = csg.size
		box.add_uv2 = true
		box.material = csg.material
		var body := StaticBody3D.new()
		body.transform = csg.transform
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		var shape := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = csg.size
		shape.shape = bs
		var idx: int = csg.get_index()
		var n := String(csg.name)
		level.remove_child(csg)
		csg.free()
		_add(level, body, n, main)
		level.move_child(body, idx)
		_add(body, mi, "Mesh", main)
		_add(body, shape, "CollisionShape3D", main)


# ---------------------------------------------------------------- props

func _make_tire_scene() -> PackedScene:
	var body := StaticBody3D.new()
	body.name = "Tire"
	var model: Node3D = load(TIRE_GLTF).instantiate()
	model.name = "Model"
	model.rotation = Vector3(-PI / 2, 0, 0)  # the model stands upright; lay it flat
	model.position.y = 0.0828
	body.add_child(model)
	model.owner = body
	var shape := CollisionShape3D.new()
	shape.name = "CollisionShape3D"
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.3
	cyl.height = 0.165
	shape.shape = cyl
	shape.position.y = 0.0828
	body.add_child(shape)
	shape.owner = body
	var ps := PackedScene.new()
	ps.pack(body)
	ResourceSaver.save(ps, "res://props/tire.tscn")
	body.free()
	return load("res://props/tire.tscn")


func _box(st: SurfaceTool, size: Vector3, pos: Vector3) -> void:
	var b := BoxMesh.new()
	b.size = size
	st.append_from(b, 0, Transform3D(Basis(), pos))


func _make_pallet_scene() -> PackedScene:
	# 1.2 x 0.8 m pallet: 7 top boards, 3 stringers, 3 bottom boards.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 7:
		_box(st, Vector3(0.12, 0.022, 0.8), Vector3(-0.54 + i * 0.18, 0.133, 0))
	for z in [-0.35, 0.0, 0.35]:
		_box(st, Vector3(1.2, 0.09, 0.09), Vector3(0, 0.077, z))
	for x in [-0.54, 0.0, 0.54]:
		_box(st, Vector3(0.12, 0.022, 0.8), Vector3(x, 0.011, 0))
	st.generate_tangents()
	var mesh := st.commit()
	mesh.surface_set_material(0, M_WOOD)
	mesh.lightmap_unwrap(Transform3D(), 0.05)
	mesh = _save_mesh(mesh, "pallet.res")

	var body := StaticBody3D.new()
	body.name = "Pallet"
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	body.add_child(mi)
	mi.owner = body
	var shape := CollisionShape3D.new()
	shape.name = "CollisionShape3D"
	var bs := BoxShape3D.new()
	bs.size = Vector3(1.2, 0.144, 0.8)
	shape.shape = bs
	shape.position.y = 0.072
	body.add_child(shape)
	shape.owner = body
	var ps := PackedScene.new()
	ps.pack(body)
	ResourceSaver.save(ps, "res://props/pallet.tscn")
	body.free()
	return load("res://props/pallet.tscn")


func _inst(parent: Node, scene: PackedScene, n: String, pos: Vector3, rot_deg: Vector3, main: Node) -> Node3D:
	var node: Node3D = scene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	node.position = pos
	node.rotation_degrees = rot_deg
	_add(parent, node, n, main)
	return node


func _place_clutter(parent: Node3D, main: Node, tire: PackedScene, pallet: PackedScene) -> void:
	# Tire stacks (each tire is 0.165 m tall).
	var stacks := [[Vector3(10.9, 0, 10.9), 3], [Vector3(-11.1, 0, -5.5), 2], [Vector3(-2.3, 0, -7.3), 2], [Vector3(11.3, 0, 9.9), 1]]
	var k := 0
	for s in stacks:
		for i in int(s[1]):
			var off := Vector3(randf_range(-0.04, 0.04), i * 0.165, randf_range(-0.04, 0.04))
			_inst(parent, tire, "Tire%d" % k, s[0] + off, Vector3(0, randf() * 360, 0), main)
			k += 1
	# A loose tire and one leaning on the south wall.
	_inst(parent, tire, "Tire%d" % k, Vector3(6.8, 0, -7.6), Vector3(0, 30, 0), main)
	_inst(parent, tire, "TireLeaning", Vector3(-1.5, 0.0, 11.62), Vector3(-72, 0, 0), main)

	# Pallets: a stack in the fenced pen, a stack by the warehouse, a single one.
	for i in 4:
		_inst(parent, pallet, "PalletPen%d" % i, Vector3(9.0, i * 0.144, 11.0) + Vector3(randf_range(-0.05, 0.05), 0, randf_range(-0.05, 0.05)), Vector3(0, 90 + randf_range(-6, 6), 0), main)
	for i in 3:
		_inst(parent, pallet, "PalletYard%d" % i, Vector3(-4.0, i * 0.144, -5.6), Vector3(0, 12 + randf_range(-5, 5), 0), main)
	_inst(parent, pallet, "PalletSingle", Vector3(1.6, 0, 10.9), Vector3(0, 4, 0), main)
	_inst(parent, pallet, "PalletLeaning", Vector3(12.0 - 0.15, 0.0, -1.6), Vector3(0, 90, 78), main)

	# Chain-link pen in the south-east corner, with a gap to walk in.
	var pen := StaticBody3D.new()
	_add(parent, pen, "FencePen", main)
	# Layer 2: blocks the player and enemies but lets bullets fly through the mesh.
	pen.collision_layer = 2
	var segs := [[Vector3(7.0, 0, 12.0), Vector3(7.0, 0, 8.7)], [Vector3(8.7, 0, 7.5), Vector3(12.0, 0, 7.5)]]
	var mesh := _fence_mesh(segs, 2.2, 1.6, true)
	var mi := MeshInstance3D.new()
	mi.mesh = _save_mesh(mesh, "fence_pen.res")
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_add(pen, mi, "Mesh", main)
	var i := 0
	for s in segs:
		var a: Vector3 = s[0]
		var b: Vector3 = s[1]
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(0.08, 2.2, a.distance_to(b))
		cs.shape = bs
		cs.position = (a + b) * 0.5 + Vector3(0, 1.1, 0)
		cs.rotation.y = atan2(b.x - a.x, b.z - a.z)
		_add(pen, cs, "Shape%d" % i, main)
		i += 1


# ---------------------------------------------------------------- fences

# Posts + top rail (metal surface) and chain-link quads (second surface).
func _fence_mesh(segs: Array, height: float, post_step: float, bottom_rail: bool) -> ArrayMesh:
	var metal := SurfaceTool.new()
	metal.begin(Mesh.PRIMITIVE_TRIANGLES)
	var chain := SurfaceTool.new()
	chain.begin(Mesh.PRIMITIVE_TRIANGLES)
	var post := CylinderMesh.new()
	post.top_radius = 0.03
	post.bottom_radius = 0.03
	post.height = height
	post.radial_segments = 6
	post.rings = 1
	var tile := 0.32  # metres per chain-link texture repeat
	for s in segs:
		var a: Vector3 = s[0]
		var b: Vector3 = s[1]
		var length := a.distance_to(b)
		var n := maxi(1, ceili(length / post_step))
		for p in n + 1:
			var pos := a.lerp(b, float(p) / n)
			metal.append_from(post, 0, Transform3D(Basis(), pos + Vector3(0, height * 0.5, 0)))
		var rail := CylinderMesh.new()
		rail.top_radius = 0.02
		rail.bottom_radius = 0.02
		rail.height = length
		rail.radial_segments = 6
		rail.rings = 1
		var dir := (b - a).normalized()
		var basis := Basis(Quaternion(Vector3.UP, dir))
		for y in ([height - 0.03, 0.08] if bottom_rail else [height - 0.03]):
			metal.append_from(rail, 0, Transform3D(basis, (a + b) * 0.5 + Vector3(0, y, 0)))
		# Chain-link quad (double-sided through the material's cull_disabled).
		var nrm := dir.cross(Vector3.UP).normalized()
		var corners := [a + Vector3(0, 0.05, 0), b + Vector3(0, 0.05, 0), b + Vector3(0, height - 0.03, 0), a + Vector3(0, height - 0.03, 0)]
		var uvs := [Vector2(0, height / tile), Vector2(length / tile, height / tile), Vector2(length / tile, 0), Vector2(0, 0)]
		for idx in [0, 1, 2, 0, 2, 3]:
			chain.set_normal(nrm)
			chain.set_uv(uvs[idx])
			chain.add_vertex(corners[idx])
	var mesh := metal.commit()
	mesh.surface_set_material(0, M_FENCE)
	chain.commit(mesh)
	mesh.surface_set_material(1, M_CHAIN)
	return mesh


func _build_wall_fence(parent: Node3D, main: Node) -> void:
	# Chain-link topping along the top of the perimeter walls (y = 4).
	var h := 4.0
	var c := 12.5
	var segs := [
		[Vector3(-c, h, -c), Vector3(c, h, -c)], [Vector3(c, h, -c), Vector3(c, h, c)],
		[Vector3(c, h, c), Vector3(-c, h, c)], [Vector3(-c, h, c), Vector3(-c, h, -c)],
	]
	var mi := MeshInstance3D.new()
	mi.mesh = _save_mesh(_fence_mesh(segs, 1.3, 3.2, false), "fence_walltop.res")
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_add(parent, mi, "WallTopFence", main)


# ---------------------------------------------------------------- grime

func _quad_mesh(items: Array, y: float, file: String, mat: Material) -> MeshInstance3D:
	# items: [x, z, size, strength, (optional) stretch]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var layer := 0
	for it in items:
		var center := Vector3(it[0], y + layer * 0.0015, it[1])
		layer = (layer + 1) % 4
		var half: float = it[2] * 0.5
		var stretch: float = it[4] if it.size() > 4 else 1.0
		var basis := Basis(Vector3.UP, randf() * TAU)
		var c := [Vector3(-half * stretch, 0, -half), Vector3(half * stretch, 0, -half), Vector3(half * stretch, 0, half), Vector3(-half * stretch, 0, half)]
		var uv := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
		for idx in [0, 1, 2, 0, 2, 3]:
			st.set_color(Color(1, 1, 1, it[3]))
			st.set_normal(Vector3.UP)
			st.set_uv(uv[idx])
			st.add_vertex(center + basis * c[idx])
	var mesh := st.commit()
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = _save_mesh(mesh, file)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	return mi


func _place_grime(parent: Node3D, main: Node) -> void:
	var grime := _add(parent, Node3D.new(), "Grime", main)
	var cracks := [[0.5, 1.5, 4.0, 1.0], [-3.0, -2.5, 3.0, 0.9], [6.5, 6.0, 3.2, 0.9], [-8.0, 9.0, 3.5, 1.0],
		[8.5, -9.5, 3.0, 0.8], [-1.0, -10.0, 2.6, 0.8], [10.0, 1.5, 2.8, 0.9], [-10.0, 0.5, 2.5, 0.8]]
	var oil := [[3.4, -1.6, 2.0, 0.95], [-5.5, -4.2, 1.6, 0.9], [9.6, 9.6, 2.2, 0.9], [-9.0, 7.0, 1.4, 0.85],
		[1.0, -6.6, 1.8, 0.9], [-1.6, 3.6, 1.0, 0.7], [6.2, -0.8, 1.2, 0.8]]
	var stains := []
	for i in 22:
		stains.append([randf_range(-11.5, 11.5), randf_range(-11.5, 11.5), randf_range(1.5, 3.5), randf_range(0.5, 1.0), randf_range(0.8, 1.6)])
	_add(grime, _quad_mesh(stains, 0.006, "grime_stains.res", preload("res://materials/decal_stain.tres")), "Stains", main)
	_add(grime, _quad_mesh(oil, 0.012, "grime_oil.res", preload("res://materials/decal_oil.tres")), "Oil", main)
	_add(grime, _quad_mesh(cracks, 0.018, "grime_cracks.res", preload("res://materials/decal_cracks.tres")), "Cracks", main)
	var puddles := [[-1.5, 5.6, 2.6, 1.0, 1.4], [7.6, 1.4, 2.0, 1.0, 1.2], [-0.8, -4.8, 1.8, 0.9, 1.0], [-10.0, 10.4, 1.9, 1.0, 1.3], [9.8, -3.2, 1.4, 0.9, 1.0]]
	var pm := _quad_mesh(puddles, 0.024, "puddles.res", M_PUDDLE)
	_add(grime, pm, "Puddles", main)


func _place_rubble_and_trash(parent: Node3D, main: Node) -> void:
	# Concrete chunks: Quaternius rocks re-textured as concrete, merged into one mesh.
	var rocks: Array[Mesh] = []
	var rock_xf: Array[Transform3D] = []
	for r in ROCKS:
		var inst: Node3D = load("res://assets/models/quaternius/props/%s.glb" % r).instantiate()
		root.add_child(inst)
		var mi: MeshInstance3D = inst.find_children("*", "MeshInstance3D", true, false)[0]
		rocks.append(mi.mesh)
		rock_xf.append(mi.global_transform)
		inst.free()
	var piles := [[Vector3(-2.6, 0, -9.2), 6], [Vector3(-11.4, 0, 1.2), 5], [Vector3(11.5, 0, -1.9), 4], [Vector3(3.6, 0, 11.4), 4], [Vector3(-7.4, 0, -11.6), 3], [Vector3(6.4, 0, -11.5), 4]]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for p in piles:
		for i in int(p[1]):
			var k := randi() % rocks.size()
			var s := randf_range(0.12, 0.38) if i > 0 else randf_range(0.35, 0.5)
			var b := Basis(Vector3.UP, randf() * TAU).rotated(Vector3.RIGHT, randf_range(-0.3, 0.3)).scaled(Vector3.ONE * s)
			var pos: Vector3 = p[0] + Vector3(randf_range(-0.7, 0.7), -0.02, randf_range(-0.7, 0.7))
			st.append_from(rocks[k], 0, Transform3D(b, pos) * rock_xf[k])
	st.generate_normals()
	var mesh := st.commit()
	mesh.surface_set_material(0, M_RUBBLE)
	mesh.lightmap_unwrap(Transform3D(), 0.1)
	var rubble := MeshInstance3D.new()
	rubble.mesh = _save_mesh(mesh, "rubble.res")
	rubble.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	_add(parent, rubble, "Rubble", main)

	var trash := _add(parent, Node3D.new(), "TrashBags", main)
	var bags := [Vector3(-11.4, 0, 6.3), Vector3(-11.0, 0, 6.9), Vector3(11.5, 0, 6.1), Vector3(1.2, 0.144, 10.8), Vector3(-3.2, 0, -6.2), Vector3(11.4, 0, -8.4)]
	var i := 0
	for p in bags:
		var bag: Node3D = load(TRASH_GLTF).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
		bag.position = p
		bag.rotation.y = randf() * TAU
		bag.scale = Vector3.ONE * randf_range(0.85, 1.15)
		_add(trash, bag, "Bag%d" % i, main)
		i += 1


# ---------------------------------------------------------------- outside

func _build_skyline(parent: Node3D, main: Node) -> void:
	# [model, x, z, scale]. Each building faces the yard. They're merged into
	# one mesh per side (N/E/S/W) with the material colours baked into vertex
	# colours: 1 draw call per side, sides behind the camera are culled, and
	# generated LODs simplify the far ones.
	var spots := [
		["Building3_Big", -28, -46, 3.6], ["6Story_Stack_Mat", -8, -54, 3.4], ["4Story_Mat", 16, -50, 3.8],
		["Building2_Small", 48, -12, 3.6], ["6Story_Stack_Mat", 54, 14, 3.0], ["Building3_Big", 40, 36, 3.2],
		["Building4", 6, 54, 3.6], ["3Story_Slim_Mat", -18, 48, 4.2],
		["Building3_Small", -52, 4, 3.7], ["4Story_Mat", -46, -26, 3.4], ["3Story_Slim_Mat", 36, -56, 4.6],
	]
	var sides := {}
	for s in spots:
		var pos := Vector3(s[1], 0, s[2])
		var side := ("N" if pos.z < 0 else "S") if absf(pos.z) >= absf(pos.x) else ("E" if pos.x > 0 else "W")
		if not sides.has(side):
			sides[side] = [PackedVector3Array(), PackedVector3Array(), PackedColorArray(), PackedInt32Array()]
		var buf: Array = sides[side]
		var inst: Node3D = load(BUILDINGS + s[0] + ".glb").instantiate()
		root.add_child(inst)
		var to_center := -pos.normalized()
		var place := Transform3D(Basis(Vector3.UP, atan2(to_center.x, to_center.z)).scaled(Vector3.ONE * s[3]), pos)
		for mi: MeshInstance3D in inst.find_children("*", "MeshInstance3D", true, false):
			var xf := place * mi.global_transform
			var nb := xf.basis.inverse().transposed()
			for surf in mi.mesh.get_surface_count():
				var arr := mi.mesh.surface_get_arrays(surf)
				var mat := mi.get_active_material(surf)
				var col := Color(0.7, 0.7, 0.7)
				if mat is StandardMaterial3D:
					col = mat.albedo_color
					if mat.albedo_texture:
						push_warning("Skyline: %s has a texture; using its colour only" % s[0])
				var base: int = buf[0].size()
				var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
				for j in v.size():
					buf[0].append(xf * v[j])
					buf[1].append((nb * n[j]).normalized())
					buf[2].append(col)
				var idx = arr[Mesh.ARRAY_INDEX]
				if idx:
					for j in idx:
						buf[3].append(base + j)
				else:
					for j in v.size():
						buf[3].append(base + j)
		inst.free()
	var holder := _add(parent, Node3D.new(), "Skyline", main)
	var total := 0
	for side in sides:
		var buf: Array = sides[side]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = buf[0]
		arrays[Mesh.ARRAY_NORMAL] = buf[1]
		arrays[Mesh.ARRAY_COLOR] = buf[2]
		arrays[Mesh.ARRAY_INDEX] = buf[3]
		var im := ImporterMesh.new()
		im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, M_SKYLINE)
		im.generate_lods(25.0, 60.0, [])
		var mi := MeshInstance3D.new()
		mi.mesh = _save_mesh(im.get_mesh(), "skyline_%s.res" % side)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		_add(holder, mi, "Skyline" + side, main)
		total += buf[3].size() / 3
	print("Skyline: ", total, " tris in ", sides.size(), " meshes")


func _build_poles(parent: Node3D, main: Node) -> void:
	# Wooden electricity poles outside the north and east walls, with sagging wires.
	var poles: Array[Transform3D] = []
	for x in [-30.0, -18.0, -6.0, 6.0, 18.0]:
		poles.append(Transform3D(Basis(Vector3.UP, PI / 2), Vector3(x, 0, -17.0)))
	for z in [-5.0, 7.0, 19.0, 31.0]:
		poles.append(Transform3D(Basis(), Vector3(18.0, 0, z)))
	var arm_y := 8.3
	var insulators := [Vector3(-0.85, arm_y + 0.12, 0), Vector3(0.0, arm_y + 0.12, 0), Vector3(0.85, arm_y + 0.12, 0)]

	var wood := SurfaceTool.new()
	wood.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ceramic := SurfaceTool.new()
	ceramic.begin(Mesh.PRIMITIVE_TRIANGLES)
	var metal := SurfaceTool.new()
	metal.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.11
	trunk.bottom_radius = 0.15
	trunk.height = 9.0
	trunk.radial_segments = 8
	trunk.rings = 1
	var arm := BoxMesh.new()
	arm.size = Vector3(2.0, 0.12, 0.12)
	var ins := CylinderMesh.new()
	ins.top_radius = 0.04
	ins.bottom_radius = 0.06
	ins.height = 0.18
	ins.radial_segments = 6
	ins.rings = 1
	var can := CylinderMesh.new()
	can.top_radius = 0.25
	can.bottom_radius = 0.25
	can.height = 0.75
	can.radial_segments = 10
	can.rings = 1
	var i := 0
	for p in poles:
		var tilt := p * Transform3D(Basis(Vector3.FORWARD, randf_range(-0.025, 0.025)), Vector3.ZERO)
		poles[i] = tilt
		wood.append_from(trunk, 0, tilt * Transform3D(Basis(), Vector3(0, 4.5, 0)))
		wood.append_from(arm, 0, tilt * Transform3D(Basis(), Vector3(0, arm_y, 0)))
		for v in insulators:
			ceramic.append_from(ins, 0, tilt * Transform3D(Basis(), v))
		if i % 3 == 1:
			metal.append_from(can, 0, tilt * Transform3D(Basis(), Vector3(0, 6.6, 0.38)))
		i += 1
	var mesh := wood.commit()
	mesh.surface_set_material(0, M_POLE)
	ceramic.commit(mesh)
	mesh.surface_set_material(1, M_CERAMIC)
	metal.commit(mesh)
	mesh.surface_set_material(2, M_METAL)
	var mi := MeshInstance3D.new()
	mi.mesh = _save_mesh(mesh, "poles.res")
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_add(parent, mi, "ElectricPoles", main)

	# Wires: thin triangular tubes hanging in a parabola between insulators.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var spans := []
	for j in 4:
		spans.append([poles[j], poles[j + 1]])
	spans.append([poles[4], poles[5]])
	for j in range(5, 8):
		spans.append([poles[j], poles[j + 1]])
	for span in spans:
		for v in insulators:
			var a: Vector3 = span[0] * (v + Vector3(0, 0.1, 0))
			var b: Vector3 = span[1] * (v + Vector3(0, 0.1, 0))
			_wire(st, a, b, 0.35 + randf() * 0.15)
	st.generate_normals()
	var wires := st.commit()
	wires.surface_set_material(0, M_WIRE)
	var wmi := MeshInstance3D.new()
	wmi.mesh = _save_mesh(wires, "wires.res")
	wmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	wmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_add(parent, wmi, "Wires", main)


func _wire(st: SurfaceTool, a: Vector3, b: Vector3, sag: float) -> void:
	var segs := 14
	var r := 0.028
	var dir := (b - a).normalized()
	var side := dir.cross(Vector3.UP).normalized()
	var up := side.cross(dir).normalized()
	var ring := [up * r, (side * 0.866 - up * 0.5) * r, (-side * 0.866 - up * 0.5) * r]
	for s in segs:
		var t0 := float(s) / segs
		var t1 := float(s + 1) / segs
		var p0 := a.lerp(b, t0) - Vector3(0, sag * 4.0 * t0 * (1.0 - t0), 0)
		var p1 := a.lerp(b, t1) - Vector3(0, sag * 4.0 * t1 * (1.0 - t1), 0)
		for k in 3:
			var o0: Vector3 = ring[k]
			var o1: Vector3 = ring[(k + 1) % 3]
			st.add_vertex(p0 + o0)
			st.add_vertex(p1 + o0)
			st.add_vertex(p1 + o1)
			st.add_vertex(p0 + o0)
			st.add_vertex(p1 + o1)
			st.add_vertex(p0 + o1)
