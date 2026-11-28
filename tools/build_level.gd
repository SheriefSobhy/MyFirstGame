extends SceneTree
## Builds the level's static detail and writes it into main.tscn:
## - converts the CSG boxes to MeshInstance3D + StaticBody3D with lightmap UV2
## - generates pallet / electric pole / fence / wire / rubble / grime meshes
## - merges the skyline buildings into ONE vertex-coloured mesh (1 draw call)
## - replaces the box walls, shed, containers, barriers and metal crates with
##   pieces of the Blender level kit (tools/kit_builder.gd); their box
##   colliders stay
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
const Kit := preload("res://tools/kit_builder.gd")

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

	# Generated last time (and the yard's first north/east/west walls, now
	# built with openings by _build_expansion).
	for path in ["NavigationRegion3D/Level/Clutter", "NavigationRegion3D/Level/Expansion", "Detail", "Outside",
			"LightmapGI", "ExpansionLights", "Roofs", "Occluders", "Zones",
			"NavigationRegion3D/Level/WallNorth", "NavigationRegion3D/Level/WallEast", "NavigationRegion3D/Level/WallWest"]:
		var old := main.get_node_or_null(path)
		if old:
			old.get_parent().remove_child(old)
			old.free()
	# Roof colliders stay outside the navmesh region (nothing walks up there).
	_add(main, Node3D.new(), "Roofs", main)

	var clutter := _add(level, Node3D.new(), "Clutter", main)
	_place_clutter(clutter, main, tire_scene, pallet_scene)
	var detail := _add(main, Node3D.new(), "Detail", main)
	main.move_child(detail, main.get_node("NavigationRegion3D").get_index() + 1)
	_place_grime(detail, main)
	_place_rubble_and_trash(detail, main)
	_build_kit(level, detail, main)
	var outside := _add(main, Node3D.new(), "Outside", main)
	main.move_child(outside, detail.get_index() + 1)
	_build_skyline(outside, main)
	_build_poles(outside, main)
	_build_wall_fence(outside, main)


	var lm := LightmapGI.new()
	lm.quality = LightmapGI.BAKE_QUALITY_HIGH
	lm.bounces = 6
	lm.bounce_indirect_energy = 1.25
	lm.use_denoiser = true
	lm.denoiser_strength = 0.12
	lm.max_texture_size = 2048
	# The map is ~2.3x the old yard: a lower texel density keeps the lightmap
	# about the old size (~3.5 MB instead of ~7).
	lm.texel_scale = 0.7
	lm.generate_probes_subdiv = LightmapGI.GENERATE_PROBES_SUBDIV_8
	# The Compatibility editor bakes the HDRI sky as black, so the sky light
	# is given as a colour matching the sky instead.
	lm.environment_mode = LightmapGI.ENVIRONMENT_MODE_CUSTOM_COLOR
	lm.environment_custom_color = Color(0.62, 0.7, 0.85)
	lm.environment_custom_energy = 0.9
	# Keep pointing at the yard's lightmap file: rebake.bat re-bakes it in
	# place (a LightmapGI without one makes the editor ask where to save).
	if ResourceLoader.exists("res://main.lmbake"):
		lm.light_data = load("res://main.lmbake")
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
	# Chain-link topping along the top of the brick walls (y = 4), with the
	# gate / gap openings (not where the storage cladding sits on the wall).
	var h := 4.0
	var c := 12.5
	var ln := LOT_N - 0.5
	var lw := LOT_W - 0.5
	var le := LOT_E + 0.5
	var segs := [
		[Vector3(-c, h, -c), Vector3(GATE.x, h, -c)], [Vector3(GATE.y, h, -c), Vector3(c, h, -c)],
		[Vector3(c, h, 6.5), Vector3(c, h, c)], [Vector3(c, h, c), Vector3(-c, h, c)],
		[Vector3(-c, h, c), Vector3(-c, h, ALLEY_GAP.y)], [Vector3(-c, h, ALLEY_GAP.x), Vector3(-c, h, -c)],
		[Vector3(lw, h, ln), Vector3(le, h, ln)], [Vector3(le, h, ln), Vector3(le, h, -13.0)],
		[Vector3(lw, h, ALLEY_S + 0.5), Vector3(lw, h, ln)], [Vector3(-c - 0.5, h, ALLEY_S + 0.5), Vector3(lw, h, ALLEY_S + 0.5)],
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
	# Wooden electricity poles outside the north and east walls (past the back
	# lot and the storage building), with sagging wires from pole to pole.
	var poles: Array[Transform3D] = []
	for x in [-32.0, -20.0, -8.0, 4.0, 16.0, 28.0]:
		poles.append(Transform3D(Basis(Vector3.UP, PI / 2), Vector3(x, 0, -28.5)))
	for z in [-16.0, -4.0, 8.0, 20.0]:
		poles.append(Transform3D(Basis(), Vector3(32.0, 0, z)))
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
	for j in poles.size() - 1:
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


# ---------------------------------------------------------------- level kit

## Bodies whose box mesh is replaced by a kit piece: [piece, size of the box,
## tint]. The box collider stays; the piece is placed at the box's bottom centre.
const KIT_BODIES := {
	"Warehouse": ["shed", Vector3(8, 6, 5), Color(0.95, 0.88, 0.8)],
	"ContainerRed": ["container", Vector3(6.1, 2.6, 2.44), Color(1.25, 0.55, 0.42)],
	"ContainerBlue": ["container", Vector3(6.1, 2.6, 2.44), Color(0.55, 0.78, 1.15)],
	"BarrierA": ["barrier", Vector3(3, 1, 0.5), Color.WHITE],
	"BarrierB": ["barrier_broken", Vector3(3, 1, 0.5), Color.WHITE],
	"MetalCrate1": ["crate", Vector3(1.2, 1.2, 1.2), Color.WHITE],
	"MetalCrate2": ["crate", Vector3(1.2, 1.2, 1.2), Color(0.85, 0.95, 0.8)],
	"MetalCrate3": ["crate", Vector3(1.2, 1.2, 1.2), Color.WHITE],
	"MetalCrate4": ["crate", Vector3(1.2, 1.2, 1.2), Color(0.85, 0.95, 0.8)],
	"MetalCrate5": ["crate", Vector3(1.2, 1.2, 1.2), Color.WHITE],
}
## The kit pieces' own sizes (piece space) for the bodies above.
const PIECE_SIZE := {"shed": Vector3(8, 6, 5), "container": Vector3(6.1, 2.6, 2.44),
	"barrier": Vector3(3, 1, 0.6), "barrier_broken": Vector3(3, 1, 0.6), "crate": Vector3(1.2, 1.2, 1.2)}
const WALL_BODIES := ["WallSouth"]  # the other three: _build_expansion (with openings)


func _build_kit(level: Node3D, detail: Node3D, main: Node) -> void:
	var kit := Kit.new()
	for n: String in KIT_BODIES.keys() + WALL_BODIES:
		var body: Node3D = level.get_node(n)
		var mesh := body.get_node_or_null("Mesh")
		if mesh:
			body.remove_child(mesh)
			mesh.free()
	for n: String in KIT_BODIES:
		var body: Node3D = level.get_node(n)
		var spec: Array = KIT_BODIES[n]
		var size: Vector3 = spec[1]
		var fit: Vector3 = size / PIECE_SIZE[spec[0]]
		var xf := body.transform * Transform3D(Basis.from_scale(fit), Vector3(0, -size.y / 2, 0))
		kit.add(spec[0], xf, spec[2])
	# The south wall (1 m thick, 4 m tall, on z = 12.5); the other three are
	# built with their openings by _build_expansion.
	var c := 12.5
	kit.wall_run(Vector3(-c, 0, c), Vector3(c, 0, c), "wall_yard", "pillar_yard")
	# Wall details on the inner faces.
	kit.mount("sign_danger", Vector3(c - 0.5, 2.3, 5.0), Vector3.LEFT)
	kit.mount("ac_unit", Vector3(-c + 0.5, 2.0, -4.8), Vector3.RIGHT)
	kit.mount("lamp_wall", Vector3(4.0, 3.2, c - 0.5), Vector3.FORWARD)
	kit.mount("pipe_h", Vector3(-6.0, 3.3, c - 0.5), Vector3.FORWARD, Color.WHITE, Vector3(9.0, 1, 1))
	kit.downpipe(Vector3(-1.4, 0, c - 0.5), Vector3.FORWARD, 3.3)
	_build_expansion(level, detail, main, kit)
	# LOD1 beyond YARD_LOD_DISTANCE now that the map is bigger.
	kit.build(detail, main, "Kit", {"lightmap": true, "file_prefix": "yard_kit", "lod_distance": YARD_LOD_DISTANCE})


# ---------------------------------------------------------------- expansion
# The yard's surroundings, about twice the playable area, from kit pieces
# and CC0 props (all generated here, under the nodes below; safe to re-run):
# - Storage building (east, x 13..27.5, z -12.5..6): 7 m clad walls on the
#   yard's brick wall, a roof (outside the navmesh region), pallet racks and
#   a forklift (close quarters); a door from the yard (west) and an 8 m
#   loading door to the back lot (north). Its lamps are bake-only.
# - Back lot (north, x -16..28, z -24..-13): trucks and containers, a long
#   east-west sight line, and the blockhouse: a solid concrete block whose
#   flat roof (BH_H m, high ground) is reached by stairs (a wedge collider
#   under the steps; the navmesh has one cell of climb for it, bake_navmesh.gd).
# - Side alley (west, x -16..-13, z -13..4): from the back lot to the yard.
# Walls between the zones block the long views (with box occluders for the
# occlusion culling). "Zones" (main.gd): zombies spawn near the player's zone.

const M_FLOOR := preload("res://materials/concrete_floor.tres")
const M_STAIRS := preload("res://materials/concrete_wall.tres")
const M_VCOLOR := preload("res://materials/map_vertex_color.tres")
const M_GLOW := preload("res://materials/map_lamp_glow.tres")
const TRUCK_GLB := "res://assets/models/map_sources/kenney/truck.glb"
const YARD_LOD_DISTANCE := 26.0
const LOT_N := -24.0            # inner face of the back lot's north wall
const LOT_W := -16.0            # inner face of the lot / alley west wall
const LOT_E := 28.0             # inner face of the lot's east wall (the building's east face)
const ALLEY_S := 4.0            # inner face of the alley's south end wall
const GATE := Vector2(1.5, 5.5)         # x: the gate in the yard's north wall
const ALLEY_GAP := Vector2(-2.6, 0.4)   # z: the gap in the yard's west wall
const ST_DOOR := Vector2(-0.8, 2.0)     # z: the storage door in the yard's east wall
const ST_X := Vector2(13.0, 27.5)       # storage interior
const ST_Z := Vector2(-12.5, 6.0)
const ST_H := 7.0                        # storage wall height (roof on top)
const ST_LOAD := Vector2(16.5, 24.5)    # x: its loading door (8 x 5 m) to the back lot
const BH_X := Vector2(-11.0, -3.0)      # the blockhouse (solid; its roof is walkable)
const BH_Z := Vector2(-24.0, -20.0)
const BH_H := 2.8
const STAIR_Z := Vector2(-20.0, -17.0)  # stairs along its south face, 3 m wide
const STAIR_FOOT := -3.0                # x: the bottom step
const STAIR_TOP := -9.0                 # x: the top (a landing from here to BH_X.x)
const STEPS := 15
const RACK_DEPTH := 1.1
const RACK_HEIGHT := 4.3
## [name, Rect2 over x/z, the zones next to it] (main.gd _near_player).
## The first that contains a point is its zone.
const ZONES := [
	["storage", Rect2(12.5, -13.0, 15.5, 19.5), ["yard", "backlot"]],
	["backlot", Rect2(-16.5, -24.5, 45.0, 11.5), ["yard", "storage", "alley"]],
	["alley", Rect2(-16.5, -13.0, 4.0, 17.5), ["yard", "backlot"]],
	["yard", Rect2(-12.5, -12.5, 25.0, 25.0), ["storage", "backlot", "alley"]],
]
## Spawn points: [name, position]. Each zone has a few, away from its doors.
const SPAWNS := [
	["SpawnNW", Vector3(-2.0, 0, -10.5)], ["SpawnNE", Vector3(10.0, 0, -10.0)], ["SpawnN", Vector3(8.0, 0, -11.0)],
	["SpawnW", Vector3(-10.5, 0, -4.8)], ["SpawnE", Vector3(10.5, 0, 0.5)],
	["SpawnStoreN", Vector3(26.0, 0, -11.0)], ["SpawnStoreS", Vector3(25.5, 0, 4.8)], ["SpawnStoreW", Vector3(14.5, 0, -11.0)],
	["SpawnLotW", Vector3(-14.0, 0, -21.0)], ["SpawnLotMid", Vector3(7.0, 0, -22.6)], ["SpawnLotE", Vector3(26.5, 0, -14.6)],
	["SpawnLotGate", Vector3(-0.5, 0, -16.0)],
	["SpawnAlleyN", Vector3(-14.5, 0, -10.0)], ["SpawnAlleyS", Vector3(-14.5, 0, 1.0)],
]

var _rng := RandomNumberGenerator.new()


func _blocker(parent: Node, main: Node, n: String, size: Vector3, center: Vector3, yaw_deg := 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)), center)
	_add(parent, body, n, main)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	_add(body, cs, "CollisionShape3D", main)
	return body


func _placed(pos: Vector3, yaw_deg: float, scale := 1.0) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)).scaled(Vector3.ONE * scale), pos)


# Merged vertex-coloured meshes (as in build_maps.gd).
func _vbatch() -> Dictionary:
	return {"v": PackedVector3Array(), "n": PackedVector3Array(), "c": PackedColorArray(), "i": PackedInt32Array()}


func _vbatch_arrays(b: Dictionary, arr: Array, xf: Transform3D, color: Color) -> void:
	var nb := xf.basis.inverse().transposed()
	var base: int = b.v.size()
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	for j in v.size():
		b.v.append(xf * v[j])
		b.n.append((nb * n[j]).normalized())
		b.c.append(color)
	var idx = arr[Mesh.ARRAY_INDEX]
	if idx:
		for j in idx:
			b.i.append(base + j)
	else:
		for j in v.size():
			b.i.append(base + j)


func _vbox(b: Dictionary, size: Vector3, xf: Transform3D, color: Color) -> void:
	var m := BoxMesh.new()
	m.size = size
	_vbatch_arrays(b, m.get_mesh_arrays(), xf, color)


func _vcyl(b: Dictionary, radius: float, height: float, xf: Transform3D, color: Color, segs := 10) -> void:
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = height
	m.radial_segments = segs
	m.rings = 1
	_vbatch_arrays(b, m.get_mesh_arrays(), xf, color)


## Adds a model (its material colours times `tint`); returns its world box.
func _vmodel(b: Dictionary, path: String, xf: Transform3D, tint := Color.WHITE) -> AABB:
	var inst: Node3D = load(path).instantiate()
	root.add_child(inst)
	var box := AABB()
	var first := true
	for mi: MeshInstance3D in inst.find_children("*", "MeshInstance3D", true, false):
		var mx := xf * mi.global_transform
		for s in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(s)
			var col := Color(0.7, 0.7, 0.7)
			if mat is StandardMaterial3D:
				col = (mat as StandardMaterial3D).albedo_color
			_vbatch_arrays(b, mi.mesh.surface_get_arrays(s), mx, col * tint)
		var wb: AABB = mx * mi.get_aabb()
		box = wb if first else box.merge(wb)
		first = false
	inst.free()
	return box


## The batch as one mesh: lit by the lightmap probes (with LODs), or baked
## into the lightmap (`baked`: lightmap UVs, no LODs), with `mat` instead of
## the vertex colour material if given.
func _vmesh(b: Dictionary, parent: Node, main: Node, n: String, file: String, baked := false, mat: Material = null) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = b.v
	arrays[Mesh.ARRAY_NORMAL] = b.n
	arrays[Mesh.ARRAY_COLOR] = b.c
	arrays[Mesh.ARRAY_INDEX] = b.i
	var mesh: ArrayMesh
	if baked:
		mesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, mat if mat else M_VCOLOR)
		mesh.lightmap_unwrap(Transform3D(), 0.2)
	else:
		var im := ImporterMesh.new()
		im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, mat if mat else M_VCOLOR)
		im.generate_lods(25.0, 60.0, [])
		mesh = im.get_mesh()
	var path := GEN + file + ".res"
	ResourceSaver.save(mesh, path, ResourceSaver.FLAG_COMPRESS)
	var mi := MeshInstance3D.new()
	mi.mesh = load(path)
	mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC if baked else GeometryInstance3D.GI_MODE_DYNAMIC
	_add(parent, mi, n, main)
	print("  %s: %d tris" % [file, b.i.size() / 3])
	return mi


## Lightmapped floor tiles over a rectangle (visual only).
func _floor(parent: Node, main: Node, prefix: String, from: Vector2, to: Vector2, tile: float, mat: Material) -> void:
	var nx := maxi(1, ceili((to.x - from.x) / tile - 0.01))
	var nz := maxi(1, ceili((to.y - from.y) / tile - 0.01))
	var sx := (to.x - from.x) / nx
	var sz := (to.y - from.y) / nz
	for i in nx:
		for j in nz:
			var pm := PlaneMesh.new()
			pm.size = Vector2(sx, sz)
			pm.material = mat
			pm.add_uv2 = true
			var mi := MeshInstance3D.new()
			mi.mesh = pm
			mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.position = Vector3(from.x + sx * (i + 0.5), 0.0, from.y + sz * (j + 0.5))
			_add(parent, mi, "%s%d_%d" % [prefix, i, j], main)


## A copy of a level surface material with some parameters changed (saved).
func _surface_copy(base: Material, file: String, params: Dictionary) -> Material:
	var m: ShaderMaterial = base.duplicate()
	for k: String in params:
		m.set_shader_parameter(k, params[k])
	var path := "res://materials/%s.tres" % file
	ResourceSaver.save(m, path)
	return load(path)


## A brick wall from a to b on the ground, centred on the line: a box
## collider and kit segments, with pillars at the ends asked for.
func _brick(level: Node, main: Node, kit: Kit, n: String, a: Vector3, b: Vector3, pillar_a: bool, pillar_b: bool,
		broken := []) -> void:
	var l := a.distance_to(b)
	var along_x := absf(b.x - a.x) > absf(b.z - a.z)
	_blocker(level, main, n, Vector3(l + 1.0, 4.0, 1.0) if along_x else Vector3(1.0, 4.0, l + 1.0),
			(a + b) * 0.5 + Vector3(0, 2.0, 0))
	kit.wall_run(a, b, "wall_yard", "pillar_yard", broken, Color.WHITE, false)
	var rot := Basis(Vector3.UP, atan2(-(b - a).z, (b - a).x))
	if pillar_a:
		kit.add("pillar_yard", Transform3D(rot, a))
	if pillar_b:
		kit.add("pillar_yard", Transform3D(rot, b))


## Storage wall from a to b: 4 m clad segments (windows on every other one).
func _wh_run(kit: Kit, a: Vector3, b: Vector3, tint: Color, windows := true) -> void:
	var d := b - a
	var n := maxi(1, roundi(d.length() / 4.0))
	var s := d.length() / n
	var dir := d.normalized()
	var rot := Basis(Vector3.UP, atan2(-dir.z, dir.x))
	for i in n:
		var piece := "wh_wall_window" if windows and i % 2 == 1 else "wh_wall"
		kit.add(piece, Transform3D(rot * Basis.from_scale(Vector3(s / 4.0, 1, 1)), a + dir * s * (i + 0.5)), tint)


func _build_expansion(level: Node3D, detail: Node3D, main: Node, kit: Kit) -> void:
	_rng.seed = 2026
	var ex := _add(level, Node3D.new(), "Expansion", main)
	var ex_detail := _add(detail, Node3D.new(), "Expansion", main)
	var lights := _add(main, Node3D.new(), "ExpansionLights", main)
	main.move_child(lights, main.get_node("Sun").get_index() + 1)
	var props := _vbatch()      # vertex-coloured, lit by the probes
	var fixtures := _vbatch()   # lamp housings, rails

	# Ground: one collider under everything, floor tiles in the new areas.
	_blocker(ex, main, "FloorExt", Vector3(47.0, 1.0, 39.0), Vector3(6.0, -0.5, -6.0))
	var m_lot := _surface_copy(M_FLOOR, "yard_lot_floor", {"edge_dirt_start": 0.0, "tint": Color(0.86, 0.85, 0.83)})
	var m_store := _surface_copy(M_FLOOR, "yard_storage_floor", {"edge_dirt_start": 0.0,
			"tint": Color(0.8, 0.8, 0.82), "macro_strength": 0.2})
	_floor(ex_detail, main, "LotFloor", Vector2(LOT_W - 0.5, LOT_N - 0.5), Vector2(LOT_E + 0.5, -13.0), 11.5, m_lot)
	_floor(ex_detail, main, "AlleyFloor", Vector2(LOT_W - 0.5, -13.0), Vector2(-13.0, ALLEY_S + 0.5), 8.5, m_lot)
	_floor(ex_detail, main, "StoreFloor", Vector2(13.0, -13.0), Vector2(28.0, 6.5), 7.5, m_store)

	# Walls: the yard's own walls get their openings (gate, alley gap,
	# storage door); the outer walls go round the new zones.
	var c := 12.5
	_brick(ex, main, kit, "WallNorthA", Vector3(-c, 0, -c), Vector3(GATE.x, 0, -c), true, true)
	_brick(ex, main, kit, "WallNorthB", Vector3(GATE.y, 0, -c), Vector3(c, 0, -c), true, true)
	_brick(ex, main, kit, "WallWestA", Vector3(-c, 0, -c), Vector3(-c, 0, ALLEY_GAP.x), false, true)
	_brick(ex, main, kit, "WallWestB", Vector3(-c, 0, ALLEY_GAP.y), Vector3(-c, 0, c), true, false)
	_brick(ex, main, kit, "WallEastA", Vector3(c, 0, -c), Vector3(c, 0, ST_DOOR.x), false, true)
	_brick(ex, main, kit, "WallEastB", Vector3(c, 0, ST_DOOR.y), Vector3(c, 0, c), true, false)
	var ln := LOT_N - 0.5
	var lw := LOT_W - 0.5
	var le := LOT_E + 0.5
	_brick(ex, main, kit, "LotWallN", Vector3(lw, 0, ln), Vector3(le, 0, ln), true, true, [3, 8])
	_brick(ex, main, kit, "LotWallW", Vector3(lw, 0, ln), Vector3(lw, 0, ALLEY_S + 0.5), false, false, [5])
	_brick(ex, main, kit, "LotWallE", Vector3(le, 0, ln), Vector3(le, 0, -13.0), false, true)
	_brick(ex, main, kit, "AlleyWallS", Vector3(lw, 0, ALLEY_S + 0.5), Vector3(-c - 0.5, 0, ALLEY_S + 0.5), true, false)

	_build_storage(ex, ex_detail, lights, main, kit, props, fixtures)
	_build_back_lot(ex, ex_detail, lights, main, kit, props, fixtures)
	_build_alley(ex, ex_detail, lights, main, kit)
	_vmesh(props, ex_detail, main, "Props", "yard_exp_props")
	_vmesh(fixtures, ex_detail, main, "Fixtures", "yard_exp_fixtures")
	_place_exp_grime(ex_detail, main)
	_build_occluders(main)
	_build_zones(main)
	_nav_blocks(level, ex, main)


## The yard's navmesh has one cell of climb (for the stairs), so a lone tyre
## or pallet (0.14-0.17 m) would be walkable on it. Each prop lower than
## NAV_BLOCK_UNDER gets a taller box that only the navmesh baker sees
## (physics layer NAV_BLOCK_LAYER: the player, enemies and bullets don't
## collide with it, the cover search skips it).
const NAV_BLOCK_UNDER := 0.3
const NAV_BLOCK_HEIGHT := 0.35
const NAV_BLOCK_LAYER := 1 << 19


func _nav_blocks(level: Node3D, ex: Node3D, main: Node) -> void:
	var holder := _add(ex, Node3D.new(), "NavBlocks", main)
	var k := 0
	for body: StaticBody3D in level.find_children("*", "StaticBody3D", true, false):
		for cs: CollisionShape3D in body.find_children("*", "CollisionShape3D", false, false):
			var size: Vector3
			if cs.shape is BoxShape3D:
				size = (cs.shape as BoxShape3D).size
			elif cs.shape is CylinderShape3D:
				var c: CylinderShape3D = cs.shape
				size = Vector3(c.radius * 2.0, c.height, c.radius * 2.0)
			else:
				continue
			var xf: Transform3D = _xf_in(level, cs)
			var bottom := xf.origin.y - size.y * 0.5 * absf(xf.basis.y.y)
			var top := xf.origin.y + size.y * 0.5 * absf(xf.basis.y.y)
			if bottom > 0.05 or bottom < -0.05 or top >= NAV_BLOCK_UNDER or absf(xf.basis.y.normalized().y) < 0.95:
				continue  # a floor, off the ground, tall enough, or tilted (leaning)
			var b := _blocker(holder, main, "NavBlock%d" % k, Vector3(size.x, NAV_BLOCK_HEIGHT, size.z),
					Vector3(xf.origin.x, NAV_BLOCK_HEIGHT * 0.5, xf.origin.z), rad_to_deg(xf.basis.get_euler().y))
			b.collision_layer = NAV_BLOCK_LAYER
			b.collision_mask = 0
			k += 1
	print("  nav blocks under low props: %d" % k)


## `n`'s transform relative to `ancestor` (the nodes aren't in the tree).
func _xf_in(ancestor: Node, n: Node3D) -> Transform3D:
	var xf := n.transform
	var p := n.get_parent()
	while p != ancestor and p is Node3D:
		xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf


# --- Storage building --------------------------------------------------------------

func _build_storage(ex: Node3D, detail: Node3D, lights: Node3D, main: Node, kit: Kit, props: Dictionary, fixtures: Dictionary) -> void:
	var clad := Color(0.95, 0.9, 0.82)
	var t := 0.25
	var zn := ST_Z.x - t     # north wall line
	var xe := ST_X.y + t     # east wall line
	var zs := ST_Z.y + t     # south wall line
	# Colliders: the north wall either side of the loading door + its header,
	# the east and south walls, the cladding on top of the yard's brick wall.
	_blocker(ex, main, "StoreWallN1", Vector3(ST_LOAD.x - ST_X.x, ST_H, 0.5), Vector3((ST_X.x + ST_LOAD.x) / 2, ST_H / 2, zn))
	_blocker(ex, main, "StoreWallN2", Vector3(LOT_E - ST_LOAD.y, ST_H, 0.5), Vector3((ST_LOAD.y + LOT_E) / 2, ST_H / 2, zn))
	_blocker(ex, main, "StoreDoorHeader", Vector3(ST_LOAD.y - ST_LOAD.x, 2.0, 0.5), Vector3((ST_LOAD.x + ST_LOAD.y) / 2, ST_H - 1.0, zn))
	_blocker(ex, main, "StoreWallE", Vector3(0.5, ST_H, 19.5), Vector3(xe, ST_H / 2, -3.25))
	_blocker(ex, main, "StoreWallS", Vector3(15.0, ST_H, 0.5), Vector3(20.5, ST_H / 2, zs))
	_blocker(ex, main, "StoreCladW", Vector3(0.5, ST_H - 4.0, 19.5), Vector3(12.75, (ST_H + 4.0) / 2, -3.25))
	# Kit: clad walls with windows, the loading door frame and header.
	_wh_run(kit, Vector3(ST_X.x, 0, zn), Vector3(ST_LOAD.x, 0, zn), clad, false)
	kit.add("wh_door_frame", _placed(Vector3((ST_LOAD.x + ST_LOAD.y) / 2, 0, zn), 0.0))
	kit.add("wh_header", _placed(Vector3((ST_LOAD.x + ST_LOAD.y) / 2, ST_H - 2.0, zn), 0.0), clad)
	_wh_run(kit, Vector3(ST_LOAD.y, 0, zn), Vector3(LOT_E, 0, zn), clad, false)
	_wh_run(kit, Vector3(xe, 0, -13.0), Vector3(xe, 0, 6.5), clad)
	_wh_run(kit, Vector3(LOT_E, 0, zs), Vector3(ST_X.x, 0, zs), clad)
	for i in 3:  # cladding from the top of the brick wall (4 m) to the roof
		kit.add("wh_header", Transform3D(Basis(Vector3.UP, PI / 2) * Basis.from_scale(Vector3(6.5 / 8.0, (ST_H - 4.0) / 2.0, 1)),
				Vector3(12.75, 4.0, -13.0 + 6.5 * (i + 0.5))), clad)
	# Columns inside, trusses and roof sheets (the roof collider is outside
	# the navmesh region, like the warehouse map's).
	for x in [15.0, 26.0]:
		kit.mount("wh_column", Vector3(x, 0, ST_Z.x), Vector3.BACK)
	for x in [17.0, 21.0, 25.0]:
		kit.mount("wh_column", Vector3(x, 0, ST_Z.y), Vector3.FORWARD)
	for z in [-8.0, -3.0, 2.0]:
		kit.mount("wh_column", Vector3(ST_X.y, 0, z), Vector3.LEFT)
	for x in [15.0, 19.0, 23.0, 26.5]:
		kit.add("truss", Transform3D(Basis.from_scale(Vector3(1, 1, 19.5 / 27.0)), Vector3(x, ST_H, -3.25)))
	for i in 4:
		for j in 5:
			var sx := 15.75 / 4.0
			var sz := 20.0 / 5.0
			kit.add("roof_sheet", Transform3D(Basis.from_scale(Vector3(sx / 4.0, 1, sz / 4.0)),
					Vector3(12.5 + sx * (i + 0.5), ST_H + 0.3, -13.25 + sz * (j + 0.5))), Color(0.7, 0.75, 0.8))
	_blocker(main.get_node("Roofs"), main, "StorageRoof", Vector3(15.75, 0.3, 20.0), Vector3(20.375, ST_H + 0.15, -3.25))
	# Signs, pipes and lamps outside (yard and back lot) and inside.
	kit.mount("sign_loading", Vector3((ST_LOAD.x + ST_LOAD.y) / 2, 6.0, zn - t), Vector3.FORWARD)
	kit.mount("lamp_wall", Vector3(ST_LOAD.x - 1.2, 5.2, zn - t), Vector3.FORWARD)
	kit.mount("lamp_wall", Vector3(12.0, 4.6, (ST_DOOR.x + ST_DOOR.y) / 2), Vector3.LEFT)
	kit.mount("sign_exit", Vector3(ST_X.x, 4.5, (ST_DOOR.x + ST_DOOR.y) / 2), Vector3.RIGHT)
	kit.mount("pipe_h", Vector3(20.0, 5.6, ST_Z.y), Vector3.FORWARD, Color.WHITE, Vector3(13.0, 1, 1))
	kit.downpipe(Vector3(26.8, 0, ST_Z.y), Vector3.FORWARD, 5.6)
	kit.mount("ac_unit", Vector3(ST_X.y, 1.5, -10.5), Vector3.LEFT, Color(0.8, 0.8, 0.75))
	_glow(detail, main, "StoreDoorBulb", Vector3(ST_LOAD.x - 1.2, 5.0, zn - t - 0.45))

	# Pallet racks: two rows with a cross aisle, one in front of the south wall.
	var racks := [[-9.0, 14.5, 19.5], [-9.0, 22.0, 26.8], [-4.5, 16.0, 26.8], [3.0, 16.0, 22.0]]
	for i in racks.size():
		var r: Array = racks[i]
		_rack(props, r[1], r[2], r[0])
		_blocker(ex, main, "Rack%d" % i, Vector3(r[2] - r[1], RACK_HEIGHT, RACK_DEPTH), Vector3((r[1] + r[2]) / 2, RACK_HEIGHT / 2, r[0]))
	# A forklift in the main aisle, metal crates, drums, a pallet stack.
	var fl := Vector3(19.6, 0, -1.2)
	_forklift(props, _placed(fl, 75.0))
	_blocker(ex, main, "Forklift", Vector3(1.25, 2.2, 3.0), fl + Basis(Vector3.UP, deg_to_rad(75.0)) * Vector3(0, 1.1, -0.3), 75.0)
	var k := 0
	for cr: Array in [[Vector3(24.8, 0, -1.6), 8.0], [Vector3(25.6, 0, -0.2), -12.0], [Vector3(25.2, 1.2, -0.9), 30.0],
			[Vector3(14.6, 0, 4.9), 0.0], [Vector3(23.6, 0, 4.9), 5.0]]:
		kit.add("crate", _placed(cr[0], cr[1]), Color(0.85, 0.95, 0.8) if cr[0].x > 20.0 else Color.WHITE)
		_blocker(ex, main, "StoreCrate%d" % k, Vector3(1.2, 1.2, 1.2), cr[0] + Vector3(0, 0.6, 0), cr[1])
		k += 1
	var clutter := [
		["res://props/barrel_rust.tscn", Vector3(14.1, 0, -6.7), 0.0], ["res://props/barrel_rust.tscn", Vector3(14.8, 0, -7.2), 0.0],
		["res://props/barrel_red.tscn", Vector3(26.7, 0, 5.2), 0.0], ["res://props/wood_crate.tscn", Vector3(16.8, 0, 1.7), 20.0],
		["res://props/military_crate.tscn", Vector3(23.0, 0, -2.6), 90.0], ["res://props/jerrycan.tscn", Vector3(18.0, 0, 1.4), 40.0],
		["res://props/pallet.tscn", Vector3(26.2, 0, -6.8), 90.0], ["res://props/pallet.tscn", Vector3(26.2, 0.144, -6.8), 84.0],
		["res://props/pallet.tscn", Vector3(26.2, 0.288, -6.8), 93.0],
	]
	for i in clutter.size():
		var cl: Array = clutter[i]
		_inst(ex, load(cl[0]), "StoreProp%d" % i, cl[1], Vector3(0, cl[2], 0), main)
	# Ceiling lamps: housings + glowing tubes; the light is baked into the
	# lightmap only (no run-time cost at any quality).
	var lamps := [Vector3(17.0, 0, -6.8), Vector3(24.0, 0, -6.8), Vector3(16.5, 0, -0.8), Vector3(23.5, 0, -0.8), Vector3(19.0, 0, 4.6)]
	for i in lamps.size():
		var p: Vector3 = lamps[i]
		_vbox(fixtures, Vector3(1.4, 0.12, 0.45), _placed(p + Vector3(0, 6.15, 0), 0.0), Color(0.25, 0.25, 0.27))
		_vbox(fixtures, Vector3(0.03, 0.8, 0.03), _placed(p + Vector3(0, 6.6, 0), 0.0), Color(0.1, 0.1, 0.1))
		var tube := MeshInstance3D.new()
		var tm := BoxMesh.new()
		tm.size = Vector3(1.25, 0.05, 0.3)
		tm.material = M_GLOW
		tube.mesh = tm
		tube.position = p + Vector3(0, 6.07, 0)
		tube.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_add(detail, tube, "StoreLampTube%d" % i, main)
		_baked_lamp(lights, main, "StoreLamp%d" % i, p + Vector3(0, 5.8, 0), Color(1.0, 0.86, 0.62), 2.6, 11.0)


# One rack segment from x0 to x1 at row z (as in build_maps.gd).
func _rack(b: Dictionary, x0: float, x1: float, z: float) -> void:
	var blue := Color(0.12, 0.24, 0.55)
	var orange := Color(0.95, 0.42, 0.08)
	var wood := Color(0.55, 0.4, 0.25)
	var bays := maxi(1, roundi((x1 - x0) / 3.0))
	var bay := (x1 - x0) / bays
	var d := RACK_DEPTH * 0.5
	for i in bays + 1:
		var x := x0 + i * bay
		for dz in [-d + 0.04, d - 0.04]:
			_vbox(b, Vector3(0.08, RACK_HEIGHT, 0.08), _placed(Vector3(x, RACK_HEIGHT / 2, z + dz), 0.0), blue)
		for y in [0.6, 2.0, 3.4]:
			_vbox(b, Vector3(0.05, 0.05, RACK_DEPTH - 0.1), _placed(Vector3(x, y, z), 0.0), blue)
	for y: float in [0.12, 1.42, 2.82]:
		if y > 0.5:
			for dz in [-d + 0.04, d - 0.04]:
				_vbox(b, Vector3(x1 - x0, 0.12, 0.06), _placed(Vector3((x0 + x1) / 2, y, z + dz), 0.0), orange)
		for i in bays:
			if _rng.randf() < 0.18:
				continue
			for p in 2:
				var px := x0 + bay * i + bay * (0.27 + 0.46 * p)
				var base := Vector3(px, y + 0.06, z)
				_vbox(b, Vector3(1.1, 0.14, RACK_DEPTH - 0.15), _placed(base + Vector3(0, 0.07, 0), 0.0), wood)
				for s in _rng.randi_range(1, 3):
					var tint := Color(0.85, 0.7, 0.5) * _rng.randf_range(0.8, 1.1)
					var bh := _rng.randf_range(0.35, 0.5)
					_vbox(b, Vector3(_rng.randf_range(0.85, 1.05), bh, RACK_DEPTH - _rng.randf_range(0.2, 0.35)),
							_placed(base + Vector3(0, 0.14 + bh * (s + 0.5), 0), _rng.randf_range(-4, 4)), tint)


# A forklift from boxes and cylinders, ~1.2 x 2.2 x 3 m, forks facing -Z (as in build_maps.gd).
func _forklift(b: Dictionary, xf: Transform3D) -> void:
	var yellow := Color(0.95, 0.68, 0.08)
	var dark := Color(0.12, 0.12, 0.13)
	var steel := Color(0.45, 0.45, 0.47)
	var p := func(pos: Vector3) -> Transform3D:
		return xf * _placed(pos, 0.0)
	_vbox(b, Vector3(1.15, 0.75, 1.9), p.call(Vector3(0, 0.6, 0.15)), yellow)
	_vbox(b, Vector3(1.15, 0.6, 0.45), p.call(Vector3(0, 0.95, 1.0)), dark)
	_vbox(b, Vector3(0.55, 0.12, 0.5), p.call(Vector3(0, 1.05, 0.35)), dark)
	_vbox(b, Vector3(0.5, 0.45, 0.1), p.call(Vector3(0, 1.3, 0.6)), dark)
	for x in [-0.52, 0.52]:
		for z in [-0.55, 0.85]:
			_vbox(b, Vector3(0.06, 1.3, 0.06), p.call(Vector3(x, 1.6, z)), dark)
	_vbox(b, Vector3(1.15, 0.06, 1.5), p.call(Vector3(0, 2.25, 0.15)), dark)
	_vbox(b, Vector3(0.3, 0.3, 0.15), p.call(Vector3(0, 1.25, -0.45)), dark)
	for x in [-0.4, 0.4]:
		_vbox(b, Vector3(0.1, 2.3, 0.12), p.call(Vector3(x, 1.15, -0.95)), steel)
	_vbox(b, Vector3(0.9, 0.5, 0.08), p.call(Vector3(0, 0.45, -1.05)), steel)
	for x in [-0.3, 0.3]:
		_vbox(b, Vector3(0.12, 0.05, 1.1), p.call(Vector3(x, 0.12, -1.6)), steel)
	var wheel := Basis(Vector3.BACK, PI / 2.0)
	for w in [Vector3(-0.6, 0.28, -0.55), Vector3(0.6, 0.28, -0.55), Vector3(-0.6, 0.24, 0.85), Vector3(0.6, 0.24, 0.85)]:
		_vcyl(b, 0.28 if w.z < 0 else 0.24, 0.25, xf * Transform3D(wheel, w), dark, 10)


func _glow(parent: Node, main: Node, n: String, pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.16
	s.height = 0.26
	s.radial_segments = 8
	s.rings = 4
	s.material = M_GLOW
	mi.mesh = s
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add(parent, mi, n, main)


## A lamp that only exists in the lightmap (its direct and bounce light baked).
func _baked_lamp(parent: Node, main: Node, n: String, pos: Vector3, color: Color, energy: float, rng: float) -> void:
	var l := OmniLight3D.new()
	l.position = pos
	l.light_color = color
	l.light_energy = energy
	l.omni_range = rng
	l.omni_attenuation = 1.2
	l.shadow_enabled = false
	l.light_bake_mode = Light3D.BAKE_STATIC
	_add(parent, l, n, main)


# --- Back lot ----------------------------------------------------------------------

func _build_back_lot(ex: Node3D, detail: Node3D, lights: Node3D, main: Node, kit: Kit, props: Dictionary, fixtures: Dictionary) -> void:
	# The blockhouse: a solid concrete block against the north wall; its flat
	# roof is the high ground over the lot (and over the wall into the yard).
	var bh_c := Vector3((BH_X.x + BH_X.y) / 2, BH_H / 2, (BH_Z.x + BH_Z.y) / 2)
	var bh_size := Vector3(BH_X.y - BH_X.x, BH_H, BH_Z.y - BH_Z.x)
	_blocker(ex, main, "Blockhouse", bh_size, bh_c)
	var t := 0.25
	kit.wall_run(Vector3(BH_X.x, 0, BH_Z.y - t), Vector3(BH_X.y, 0, BH_Z.y - t), "wall_low", "pillar_low", [], Color.WHITE, false, 4.0)
	kit.wall_run(Vector3(BH_X.y - t, 0, BH_Z.y), Vector3(BH_X.y - t, 0, BH_Z.x), "wall_low", "pillar_low", [], Color.WHITE, false, 4.0)
	kit.wall_run(Vector3(BH_X.x + t, 0, BH_Z.x), Vector3(BH_X.x + t, 0, BH_Z.y), "wall_low", "pillar_low", [], Color.WHITE, false, 4.0)
	kit.add("pillar_low", _placed(Vector3(BH_X.y - t, 0, BH_Z.y - t), 0.0))
	kit.add("roof_sheet", Transform3D(Basis.from_scale(Vector3(bh_size.x / 4.0, 1, bh_size.z / 4.0)),
			Vector3(bh_c.x, BH_H + 0.02, bh_c.z)), Color(1.1, 1.08, 1.0))
	kit.mount("sign_danger", Vector3(BH_X.y, 1.9, -22.6), Vector3.RIGHT)
	kit.mount("ac_unit", Vector3(BH_X.y, 1.2, -21.0), Vector3.RIGHT, Color(0.8, 0.8, 0.75))
	kit.mount("lamp_wall", Vector3(BH_X.x, 2.2, -22.0), Vector3.LEFT)
	kit.downpipe(Vector3(BH_X.y, 0, BH_Z.x + 0.4), Vector3.RIGHT, BH_H - 0.2)
	_glow(detail, main, "BlockhouseBulb", Vector3(BH_X.x - 0.45, 2.0, -22.0))
	_baked_lamp(lights, main, "BlockhouseLamp", Vector3(BH_X.x - 0.8, 2.0, -22.0), Color(1.0, 0.72, 0.45), 1.6, 7.0)
	# Jersey barriers on the roof: parapet and cover (not where the stairs arrive).
	var k := 0
	for p: Array in [[Vector3(-5.6, BH_H, BH_Z.y - 0.35), 0.0, "barrier_broken"],
			[Vector3(BH_X.y - 0.35, BH_H, -22.5), 90.0, "barrier"]]:
		kit.add(p[2], _placed(p[0], p[1]))
		_blocker(ex, main, "RoofBarrier%d" % k, Vector3(3.0, 1.0, 0.6), p[0] + Vector3(0, 0.5, 0), p[1])
		k += 1

	# The stairs: a solid concrete flight along the south face up to a landing
	# that joins the roof. Collision is a smooth wedge (enemies and the player
	# walk up it); each step's top is drawn half a step around it.
	var stairs := StaticBody3D.new()
	_add(ex, stairs, "Stairs", main)
	var wedge := CollisionShape3D.new()
	var cps := ConvexPolygonShape3D.new()
	cps.points = PackedVector3Array([
		Vector3(STAIR_FOOT, 0, STAIR_Z.x), Vector3(STAIR_FOOT, 0, STAIR_Z.y),
		Vector3(STAIR_TOP, 0, STAIR_Z.x), Vector3(STAIR_TOP, 0, STAIR_Z.y),
		Vector3(STAIR_TOP, BH_H, STAIR_Z.x), Vector3(STAIR_TOP, BH_H, STAIR_Z.y)])
	wedge.shape = cps
	_add(stairs, wedge, "CollisionShape3D", main)
	_blocker(ex, main, "StairLanding", Vector3(STAIR_TOP - BH_X.x, BH_H, STAIR_Z.y - STAIR_Z.x),
			Vector3((BH_X.x + STAIR_TOP) / 2, BH_H / 2, (STAIR_Z.x + STAIR_Z.y) / 2))
	var steps := _vbatch()
	var run := (STAIR_FOOT - STAIR_TOP) / STEPS
	var rise := BH_H / STEPS
	var w := STAIR_Z.y - STAIR_Z.x
	var zc := (STAIR_Z.x + STAIR_Z.y) / 2
	for i in range(1, STEPS + 1):
		var top := (i - 0.5) * rise
		_vbox(steps, Vector3(run, top, w), _placed(Vector3(STAIR_FOOT - (i - 0.5) * run, top / 2, zc), 0.0), Color.WHITE)
	_vbox(steps, Vector3(STAIR_TOP - BH_X.x, BH_H, w), _placed(Vector3((BH_X.x + STAIR_TOP) / 2, BH_H / 2, zc), 0.0), Color.WHITE)
	_vmesh(steps, detail, main, "Stairs", "yard_stairs", true, M_STAIRS)
	# Hand rails along the open side and round the landing (looks only).
	var steel := Color(0.3, 0.31, 0.33)
	var rail_z := STAIR_Z.y - 0.06
	var slope := atan2(BH_H, STAIR_FOOT - STAIR_TOP)
	for i in 5:
		var x := STAIR_FOOT - 0.3 - i * (STAIR_FOOT - STAIR_TOP - 0.6) / 4.0
		var y := (STAIR_FOOT - x) * BH_H / (STAIR_FOOT - STAIR_TOP)
		_vbox(fixtures, Vector3(0.05, 1.0, 0.05), _placed(Vector3(x, y + 0.5, rail_z), 0.0), steel)
	var rail_len := (STAIR_FOOT - STAIR_TOP - 0.6) / cos(slope)
	_vbox(fixtures, Vector3(rail_len, 0.05, 0.05), Transform3D(Basis(Vector3.BACK, -slope),
			Vector3((STAIR_FOOT + STAIR_TOP) / 2, BH_H / 2 + 1.0, rail_z)), steel)
	_vbox(fixtures, Vector3(STAIR_TOP - BH_X.x, 0.05, 0.05), _placed(Vector3((BH_X.x + STAIR_TOP) / 2, BH_H + 1.0, rail_z), 0.0), steel)
	_vbox(fixtures, Vector3(0.05, 0.05, w), _placed(Vector3(BH_X.x + 0.06, BH_H + 1.0, zc), 0.0), steel)
	for p: Vector3 in [Vector3(BH_X.x + 0.06, 0, rail_z), Vector3(STAIR_TOP, 0, rail_z), Vector3(BH_X.x + 0.06, 0, STAIR_Z.x + 0.1)]:
		_vbox(fixtures, Vector3(0.05, 1.0, 0.05), _placed(p + Vector3(0, BH_H + 0.5, 0), 0.0), steel)

	# Trucks: one parked along the lot, one backed up to the loading door.
	for tr: Array in [["Truck1", Vector3(10.5, 0, -19.4), 90.0], ["Truck2", Vector3(20.5, 0, -19.6), 180.0]]:
		var box := _vmodel(props, TRUCK_GLB, _placed(tr[1], tr[2], 1.6), Color(0.85, 0.82, 0.78) if tr[0] == "Truck1" else Color(0.7, 0.78, 0.9))
		_blocker(ex, main, tr[0], box.size - Vector3(0.1, 0, 0.1), box.get_center())
		print("  %s box %s" % [tr[0], box])
	# Containers: a stack of two against the north wall, one by the gate side
	# of the lane, one at the east end.
	var conts := [
		["ContainerLot1", Vector3(1.6, 0, LOT_N + 1.27), 0.0, Color(0.55, 0.78, 1.15)],
		["ContainerLot2", Vector3(1.75, 2.6, LOT_N + 1.3), 3.0, Color(1.25, 0.55, 0.42)],
		["ContainerLot4", Vector3(25.4, 0, -19.0), 90.0, Color(1.25, 0.95, 0.45)],
	]
	for ct: Array in conts:
		kit.add("container", _placed(ct[1], ct[2]), ct[3])
		_blocker(ex, main, ct[0], Vector3(6.1, 2.6, 2.44), ct[1] + Vector3(0, 1.3, 0), ct[2])
	# Jersey barriers and metal crates in the long lane (low cover).
	k = 0
	for br: Array in [[Vector3(5.2, 0, -15.3), 8.0, "barrier"], [Vector3(15.5, 0, -15.0), -6.0, "barrier_broken"],
			[Vector3(-1.0, 0, -15.0), 0.0, "barrier"]]:
		kit.add(br[2], _placed(br[0], br[1]))
		_blocker(ex, main, "LotBarrier%d" % k, Vector3(3.0, 1.0, 0.6), br[0] + Vector3(0, 0.5, 0), br[1])
		k += 1
	k = 0
	for cr: Array in [[Vector3(3.2, 0, -18.0), 15.0], [Vector3(4.4, 0, -18.3), -5.0], [Vector3(14.3, 0, -22.7), 0.0],
			[Vector3(14.3, 1.2, -22.7), 20.0], [Vector3(27.2, 0, -23.2), 10.0]]:
		kit.add("crate", _placed(cr[0], cr[1]), Color(0.85, 0.95, 0.8))
		_blocker(ex, main, "LotCrate%d" % k, Vector3(1.2, 1.2, 1.2), cr[0] + Vector3(0, 0.6, 0), cr[1])
		k += 1
	kit.add("dumpster", _placed(Vector3(-14.6, 0, -23.2), 0.0), Color(0.7, 0.8, 1.2))
	_blocker(ex, main, "LotDumpster", Vector3(1.9, 1.3, 1.1), Vector3(-14.6, 0.65, -23.2))
	var clutter := [
		["res://props/barrel_red.tscn", Vector3(8.4, 0, -14.0), 0.0], ["res://props/barrel_red.tscn", Vector3(-9.2, 0, -14.1), 0.0],
		["res://props/barrel_rust.tscn", Vector3(17.6, 0, -23.1), 0.0], ["res://props/barrel_rust.tscn", Vector3(18.3, 0, -23.4), 40.0],
		["res://props/barrel_rust.tscn", Vector3(-2.2, 0, -23.2), 0.0], ["res://props/wood_crate.tscn", Vector3(27.0, 0, -23.0), 10.0],
		["res://props/military_crate.tscn", Vector3(-14.4, 0, -19.6), 80.0], ["res://props/pallet.tscn", Vector3(27.2, 0, -20.5), 90.0],
		["res://props/pallet.tscn", Vector3(27.2, 0.144, -20.5), 95.0], ["res://props/tire.tscn", Vector3(12.6, 0, -14.0), 0.0],
		["res://props/tire.tscn", Vector3(12.6, 0.165, -14.0), 40.0], ["res://props/jerrycan.tscn", Vector3(22.8, 0, -16.0), 60.0],
	]
	for i in clutter.size():
		var cl: Array = clutter[i]
		_inst(ex, load(cl[0]), "LotProp%d" % i, cl[1], Vector3(0, cl[2], 0), main)
	var bags := [Vector3(-13.6, 0, -23.3), Vector3(-13.1, 0, -22.9), Vector3(27.1, 0, -16.5), Vector3(-1.2, 0, -21.0)]
	for i in bags.size():
		var bag: Node3D = load(TRASH_GLTF).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
		bag.position = bags[i]
		bag.rotation.y = _rng.randf() * TAU
		_add(detail, bag, "LotBag%d" % i, main)
	# Wall details on the lot side.
	kit.mount("sign_danger", Vector3(-6.0, 2.4, -13.0), Vector3.FORWARD)
	kit.mount("pipe_h", Vector3(8.0, 3.3, LOT_N), Vector3.BACK, Color.WHITE, Vector3(10.0, 1, 1))
	kit.downpipe(Vector3(12.8, 0, LOT_N), Vector3.BACK, 3.3)
	kit.mount("lamp_wall", Vector3(GATE.x - 1.0, 3.2, -13.0), Vector3.FORWARD)
	_glow(detail, main, "GateBulb", Vector3(GATE.x - 1.0, 3.0, -13.45))
	_baked_lamp(lights, main, "GateLamp", Vector3(GATE.x - 1.0, 3.0, -13.8), Color(1.0, 0.72, 0.45), 1.6, 8.0)


# --- Side alley --------------------------------------------------------------------

func _build_alley(ex: Node3D, detail: Node3D, lights: Node3D, main: Node, kit: Kit) -> void:
	# The dead end south of the gap into the yard: a dumpster and rubbish.
	kit.add("dumpster", _placed(Vector3(-14.7, 0, 3.2), 0.0), Color(0.8, 0.9, 0.8))
	_blocker(ex, main, "AlleyDumpster", Vector3(1.9, 1.3, 1.1), Vector3(-14.7, 0.65, 3.2))
	var bags := [Vector3(-13.4, 0, 3.4), Vector3(-13.5, 0, 2.6), Vector3(-15.5, 0, 1.6)]
	for i in bags.size():
		var bag: Node3D = load(TRASH_GLTF).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
		bag.position = bags[i]
		bag.rotation.y = _rng.randf() * TAU
		_add(detail, bag, "AlleyBag%d" % i, main)
	_inst(ex, load("res://props/barrel_rust.tscn"), "AlleyBarrel0", Vector3(-15.55, 0, -6.5), Vector3.ZERO, main)
	_inst(ex, load("res://props/barrel_rust.tscn"), "AlleyBarrel1", Vector3(-15.5, 0, -11.8), Vector3(0, 30, 0), main)
	_inst(ex, load("res://props/pallet.tscn"), "AlleyPallet", Vector3(LOT_W + 0.15, 0.0, -4.0), Vector3(0, 90, 78), main)
	# Pipes, an AC unit and a lamp on the walls.
	kit.mount("pipe_h", Vector3(LOT_W, 3.0, -4.5), Vector3.RIGHT, Color.WHITE, Vector3(16.0, 1, 1))
	kit.downpipe(Vector3(LOT_W, 0, -12.4), Vector3.RIGHT, 3.0)
	kit.mount("ac_unit", Vector3(-13.0, 2.0, -8.0), Vector3.LEFT, Color(0.8, 0.8, 0.75))
	kit.mount("lamp_wall", Vector3(LOT_W, 2.8, -1.1), Vector3.RIGHT)
	_glow(detail, main, "AlleyBulb", Vector3(LOT_W + 0.45, 2.6, -1.1))
	_baked_lamp(lights, main, "AlleyLamp", Vector3(LOT_W + 0.9, 2.6, -1.1), Color(1.0, 0.72, 0.45), 1.4, 7.0)


# --- Grime, occluders, zones -------------------------------------------------------

func _place_exp_grime(parent: Node3D, main: Node) -> void:
	var stains := []
	for i in 26:
		stains.append([_rng.randf_range(LOT_W, LOT_E), _rng.randf_range(LOT_N, -13.5), _rng.randf_range(1.5, 3.5),
				_rng.randf_range(0.5, 1.0), _rng.randf_range(0.8, 1.6)])
	for i in 6:
		stains.append([_rng.randf_range(-15.5, -13.5), _rng.randf_range(-12.5, 3.5), _rng.randf_range(1.2, 2.2), _rng.randf_range(0.6, 1.0), 1.0])
	for i in 8:
		stains.append([_rng.randf_range(14.0, 27.0), _rng.randf_range(-12.0, 5.5), _rng.randf_range(1.2, 2.6), _rng.randf_range(0.4, 0.8), 1.3])
	var oil := [[9.5, -15.8, 2.2, 0.95], [20.4, -16.5, 1.8, 0.9], [-6.5, -16.0, 1.4, 0.85], [19.0, -0.6, 2.0, 0.9],
		[22.5, -6.7, 1.4, 0.8], [-14.6, -1.0, 1.2, 0.8]]
	var cracks := [[0.0, -17.0, 3.5, 1.0], [16.0, -20.0, 3.0, 0.9], [-12.0, -20.5, 2.8, 0.9], [-14.5, -7.0, 2.2, 0.8], [25.0, -21.0, 2.6, 0.8]]
	var g := _add(parent, Node3D.new(), "Grime", main)
	_add(g, _quad_mesh(stains, 0.006, "yard_exp_stains.res", preload("res://materials/decal_stain.tres")), "Stains", main)
	_add(g, _quad_mesh(oil, 0.012, "yard_exp_oil.res", preload("res://materials/decal_oil.tres")), "Oil", main)
	_add(g, _quad_mesh(cracks, 0.018, "yard_exp_cracks.res", preload("res://materials/decal_cracks.tres")), "Cracks", main)
	_add(g, _quad_mesh([[6.0, -21.6, 2.4, 1.0, 1.4], [-9.0, -15.4, 1.8, 1.0, 1.1]], 0.024, "yard_exp_puddles.res", M_PUDDLE), "Puddles", main)


## Box occluders for the occlusion culling: the walls between the zones, the
## storage building and the big blocks (a phone draws less of the map).
func _build_occluders(main: Node) -> void:
	var holder := _add(main, Node3D.new(), "Occluders", main)
	var boxes := [
		["YardN_A", Vector3(14.5, 4.0, 0.8), Vector3(-5.75, 2.0, -12.5)], ["YardN_B", Vector3(7.5, 4.0, 0.8), Vector3(9.25, 2.0, -12.5)],
		["YardW_A", Vector3(0.8, 4.0, 10.4), Vector3(-12.5, 2.0, -7.8)], ["YardW_B", Vector3(0.8, 4.0, 12.6), Vector3(-12.5, 2.0, 6.7)],
		["YardE_A", Vector3(0.8, ST_H, 12.2), Vector3(12.75, ST_H / 2, -6.9)], ["YardE_B", Vector3(0.8, ST_H, 4.5), Vector3(12.75, ST_H / 2, 4.25)],
		["YardE_C", Vector3(0.8, 4.0, 6.0), Vector3(12.5, 2.0, 9.5)], ["YardS", Vector3(26.0, 4.0, 0.8), Vector3(0, 2.0, 12.5)],
		["StoreN1", Vector3(3.5, ST_H, 0.4), Vector3(14.75, ST_H / 2, -12.75)], ["StoreN2", Vector3(3.5, ST_H, 0.4), Vector3(26.25, ST_H / 2, -12.75)],
		["StoreHeader", Vector3(8.0, 2.0, 0.4), Vector3(20.5, ST_H - 1.0, -12.75)],
		["StoreE", Vector3(0.4, ST_H, 19.5), Vector3(27.75, ST_H / 2, -3.25)], ["StoreS", Vector3(15.0, ST_H, 0.4), Vector3(20.5, ST_H / 2, 6.25)],
		["StoreRoof", Vector3(15.5, 0.3, 19.5), Vector3(20.25, ST_H + 0.15, -3.25)],
		["LotN", Vector3(45.0, 4.0, 0.8), Vector3(6.0, 2.0, -24.5)], ["LotW", Vector3(0.8, 4.0, 29.0), Vector3(-16.5, 2.0, -10.0)],
		["LotE", Vector3(0.8, 4.0, 11.5), Vector3(28.5, 2.0, -18.75)],
		["Blockhouse", Vector3(7.6, 2.6, 3.6), Vector3(-7.0, 1.3, -22.0)],
		["Containers", Vector3(5.8, 5.0, 2.2), Vector3(1.6, 2.5, LOT_N + 1.27)],
		["Shed", Vector3(7.6, 5.6, 4.6), Vector3(-7.0, 2.8, -9.0)],
	]
	for b: Array in boxes:
		var oi := OccluderInstance3D.new()
		var occ := BoxOccluder3D.new()
		occ.size = b[1]
		oi.occluder = occ
		oi.position = b[2]
		_add(holder, oi, "Occ" + b[0], main)


## The zones (main.gd: zombies spawn near the player's zone), the spawn
## points (every one must connect to the player start) and 2 more ammo boxes.
func _build_zones(main: Node) -> void:
	var zones := _add(main, Node3D.new(), "Zones", main)
	for z: Array in ZONES:
		var n := Node3D.new()
		n.set_meta("rect", z[1])
		n.set_meta("near", PackedStringArray(z[2]))
		_add(zones, n, z[0], main)
	var sp: Node = main.get_node("SpawnPoints")
	for old in sp.get_children():
		sp.remove_child(old)
		old.free()
	for s: Array in SPAWNS:
		var m := Marker3D.new()
		m.position = s[1] + Vector3(0, 0.1, 0)
		_add(sp, m, s[0], main)
	var pickups: Node = main.get_node("Pickups")
	var scene: PackedScene = load("res://pickup.tscn")
	for p: Array in [["AmmoBox4", Vector3(21.5, 0, 0.6)], ["AmmoBox5", Vector3(-12.5, 0, -15.2)]]:
		if pickups.get_node_or_null(p[0]) == null:
			var node: Node3D = scene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
			node.position = p[1]
			_add(pickups, node, p[0], main)
