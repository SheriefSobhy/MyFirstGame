extends SceneTree
## Builds the two extra maps, maps/town.tscn and maps/warehouse.tscn, from
## code, and bakes their navmeshes (maps/<id>_navmesh.res).
## Each map is a full game scene running main.gd, with the same nodes as
## main.tscn (Player, HUD, Enemies, SpawnPoints, SpawnTimer, Pickups, Sun...).
## Run: godot --headless --path . --script res://tools/build_maps.gd
## Safe to re-run: it overwrites everything it made before.
##
## Kept light for phones:
## - Models (houses, cars, street lights, shelves, forklifts) are merged into
##   a few vertex-coloured meshes, one draw call each.
## - Floors are split into tiles so each lamp only re-lights nearby tiles.
## - No lightmaps: a few real-time lamps, and the extra ones are in the
##   "optional_lights" group, which Low quality switches off (main.gd).
## - Collisions are plain boxes.
## The source models live in assets/models/map_sources/ (not exported).

const GEN := "res://level/generated/"
const SRC := "res://assets/models/map_sources/"
const M_VCOLOR_PATH := "res://materials/map_vertex_color.tres"

var done := false
var m_vcolor: StandardMaterial3D
var m_glow: StandardMaterial3D


func _process(_delta: float) -> bool:
	if done:
		return true
	done = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GEN))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://maps"))
	seed(7)
	_make_shared_materials()
	_save_map(_build_town(), "town")
	_save_map(_build_warehouse(), "warehouse")
	print("BUILD_MAPS: done")
	quit()
	return true


# --- Shared ------------------------------------------------------------------

func _make_shared_materials() -> void:
	m_vcolor = StandardMaterial3D.new()
	m_vcolor.vertex_color_use_as_albedo = true
	m_vcolor.vertex_color_is_srgb = true
	m_vcolor.roughness = 0.85
	ResourceSaver.save(m_vcolor, M_VCOLOR_PATH)
	m_vcolor = load(M_VCOLOR_PATH)
	m_glow = StandardMaterial3D.new()
	m_glow.albedo_color = Color(1.0, 0.85, 0.6)
	m_glow.emission_enabled = true
	m_glow.emission = Color(1.0, 0.8, 0.5)
	m_glow.emission_energy_multiplier = 4.0
	ResourceSaver.save(m_glow, "res://materials/map_lamp_glow.tres")
	m_glow = load("res://materials/map_lamp_glow.tres")


## A copy of one of the yard's surface materials with some parameters changed,
## saved as its own file.
func _surface(base: String, file: String, params: Dictionary) -> Material:
	var m: ShaderMaterial = load(base).duplicate()
	for k: String in params:
		m.set_shader_parameter(k, params[k])
	var path := "res://materials/%s.tres" % file
	ResourceSaver.save(m, path)
	return load(path)


func _add(parent: Node, child: Node, n: String, owner_node: Node) -> Node:
	child.name = n
	parent.add_child(child)
	child.owner = owner_node
	return child


## The game nodes every map needs, around an empty level.
func _new_map(map_id: String, music_path: String, env: Environment) -> Node3D:
	var root := Node3D.new()
	root.name = "Main"
	root.set_script(load("res://main.gd"))
	root.set("map_id", map_id)
	root.set("music", load(music_path))
	var we := WorldEnvironment.new()
	we.environment = env
	_add(root, we, "WorldEnvironment", root)
	var nav := NavigationRegion3D.new()
	_add(root, nav, "NavigationRegion3D", root)
	_add(nav, Node3D.new(), "Level", root)
	_add(root, Node3D.new(), "Detail", root)
	_add(root, Node3D.new(), "Lights", root)
	return root


func _finish_map(root: Node3D, player_pos: Vector3, player_yaw: float, spawns: Array, pickups: Array) -> void:
	var player: Node3D = load("res://player.tscn").instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	_add(root, player, "Player", root)
	player.transform = Transform3D(Basis(Vector3.UP, player_yaw), player_pos)
	_add(root, Node3D.new(), "Enemies", root)
	var sp := _add(root, Node3D.new(), "SpawnPoints", root)
	for i in spawns.size():
		var m := Marker3D.new()
		m.position = spawns[i] + Vector3(0, 0.1, 0)
		_add(sp, m, "Spawn%d" % (i + 1), root)
	var timer := Timer.new()
	timer.wait_time = 3.0
	timer.autostart = true
	_add(root, timer, "SpawnTimer", root)
	var wind := AudioStreamPlayer.new()
	wind.stream = load("res://assets/sounds/wind_loop.ogg")
	wind.volume_db = -14.0
	_add(root, wind, "Wind", root)
	var hud: Node = load("res://hud.tscn").instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	_add(root, hud, "HUD", root)
	var holder := _add(root, Node3D.new(), "Pickups", root)
	var pickup_scene: PackedScene = load("res://pickup.tscn")
	for p: Array in pickups:
		# [name, position, weapon slot or -1 for an ammo box]
		var node: Node3D = pickup_scene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
		_add(holder, node, p[0], root)
		node.position = p[1]
		if p[2] >= 0:
			node.set("kind", 0)
			node.set("weapon_index", p[2])


func _sun(root: Node3D, rot_deg: Vector3, color: Color, energy: float) -> DirectionalLight3D:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = rot_deg
	sun.light_color = color
	sun.light_energy = energy
	sun.shadow_enabled = true
	sun.shadow_blur = 1.5
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 30.0
	_add(root, sun, "Sun", root)
	root.move_child(sun, 1)
	return sun


## A solid box: mesh + collision. Rotated by yaw (degrees).
func _solid(parent: Node, root: Node, n: String, size: Vector3, center: Vector3, mat: Material, yaw := 0.0, shadow := true) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(yaw)), center)
	_add(parent, body, n, root)
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	box.material = mat
	mi.mesh = box
	if not shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add(body, mi, "Mesh", root)
	_collider(body, root, size, Vector3.ZERO)
	return body


## Collision only (the looks come from a merged mesh).
func _blocker(parent: Node, root: Node, n: String, size: Vector3, center: Vector3, yaw := 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(yaw)), center)
	_add(parent, body, n, root)
	_collider(body, root, size, Vector3.ZERO)
	return body


func _collider(body: Node, root: Node, size: Vector3, offset: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = offset
	_add(body, cs, "CollisionShape3D", root)


## Flat floor tiles over a rectangle (visual only), `tile` metres each.
func _floor_tiles(parent: Node, root: Node, prefix: String, from: Vector2, to: Vector2, tile: Vector2, mat: Material, y := 0.0) -> void:
	var nx := ceili((to.x - from.x) / tile.x - 0.01)
	var nz := ceili((to.y - from.y) / tile.y - 0.01)
	var sx := (to.x - from.x) / nx
	var sz := (to.y - from.y) / nz
	for i in nx:
		for j in nz:
			var mi := MeshInstance3D.new()
			var pm := PlaneMesh.new()
			pm.size = Vector2(sx, sz)
			pm.material = mat
			mi.mesh = pm
			mi.position = Vector3(from.x + sx * (i + 0.5), y, from.y + sz * (j + 0.5))
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_add(parent, mi, "%s%d_%d" % [prefix, i, j], root)


func _prop(parent: Node, root: Node, scene: String, n: String, pos: Vector3, yaw := 0.0) -> Node3D:
	var node: Node3D = load(scene).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	_add(parent, node, n, root)
	node.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(yaw)), pos)
	return node


func _omni(parent: Node, root: Node, n: String, pos: Vector3, color: Color, energy: float, rng: float, optional := false) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.position = pos
	l.light_color = color
	l.light_energy = energy
	l.omni_range = rng
	l.omni_attenuation = 1.2
	l.shadow_enabled = false
	_add(parent, l, n, root)
	if optional:
		l.add_to_group("optional_lights", true)
	return l


# --- Merged vertex-coloured meshes -----------------------------------------------

func _batch() -> Dictionary:
	return {"v": PackedVector3Array(), "n": PackedVector3Array(), "c": PackedColorArray(), "i": PackedInt32Array()}


func _batch_arrays(b: Dictionary, arr: Array, xf: Transform3D, color: Color) -> void:
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


## Adds a model (its material colours times `tint`) and returns its box in world space.
func _batch_model(b: Dictionary, path: String, xf: Transform3D, tint := Color.WHITE) -> AABB:
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
			_batch_arrays(b, mi.mesh.surface_get_arrays(s), mx, col * tint)
		var wb: AABB = mx * mi.get_aabb()
		box = wb if first else box.merge(wb)
		first = false
	inst.free()
	return box


func _batch_box(b: Dictionary, size: Vector3, xf: Transform3D, color: Color) -> void:
	var m := BoxMesh.new()
	m.size = size
	_batch_arrays(b, m.get_mesh_arrays(), xf, color)


func _batch_cyl(b: Dictionary, radius: float, height: float, xf: Transform3D, color: Color, segs := 10) -> void:
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = height
	m.radial_segments = segs
	m.rings = 1
	_batch_arrays(b, m.get_mesh_arrays(), xf, color)


func _batch_mesh(b: Dictionary, parent: Node, root: Node, n: String, file: String, shadow := true, lods := true) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = b.v
	arrays[Mesh.ARRAY_NORMAL] = b.n
	arrays[Mesh.ARRAY_COLOR] = b.c
	arrays[Mesh.ARRAY_INDEX] = b.i
	var im := ImporterMesh.new()
	im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, m_vcolor)
	if lods:
		im.generate_lods(25.0, 60.0, [])
	var mesh := im.get_mesh()
	var path := GEN + file + ".res"
	ResourceSaver.save(mesh, path, ResourceSaver.FLAG_COMPRESS)
	var mi := MeshInstance3D.new()
	mi.mesh = load(path)
	if not shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add(parent, mi, n, root)
	print("  %s: %d tris" % [file, b.i.size() / 3])
	return mi


func _place(pos: Vector3, yaw_deg: float, scale := 1.0) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)).scaled(Vector3.ONE * scale), pos)


# --- Map 2: Abandoned Town ----------------------------------------------------

const HOUSES := ["1Story_GableRoof_Mat", "2Story_Mat", "1Story_Mat", "2Story_Balcony_Mat", "2Story_GableRoof_Mat"]
const HOUSE_TINTS := [
	Color(1.25, 1.05, 0.85), Color(0.95, 0.75, 0.7), Color(1.1, 1.1, 1.05), Color(0.85, 0.95, 1.0),
	Color(1.2, 0.95, 0.75), Color(0.9, 0.85, 0.8),
]
const CARS := ["sedan", "suv", "van", "police", "truck", "taxi", "hatchbackSports"]
const HOUSE_SCALE := 3.3
const LAMP_SCALE := 4.4
const TOWN_EDGE := 23.0


func _build_town() -> Node3D:
	print("Town:")
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.16, 0.17, 0.36)
	sky_mat.sky_horizon_color = Color(0.98, 0.56, 0.36)
	sky_mat.sky_curve = 0.12
	sky_mat.ground_horizon_color = Color(0.55, 0.36, 0.32)
	sky_mat.ground_bottom_color = Color(0.1, 0.08, 0.1)
	sky_mat.sun_angle_max = 8.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.55
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 6.0
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.08
	env.fog_enabled = true
	env.fog_light_color = Color(0.62, 0.42, 0.42)
	env.fog_density = 0.012
	env.fog_sky_affect = 0.15
	env.fog_sun_scatter = 0.4

	var root := _new_map("town", "res://assets/music/town_empty_city.ogg", env)
	# Low evening sun from the west, warm and orange.
	_sun(root, Vector3(-11.0, -72.0, 0.0), Color(1.0, 0.56, 0.32), 1.25)
	var level: Node3D = root.get_node("NavigationRegion3D/Level")
	var detail: Node3D = root.get_node("Detail")
	var lights: Node3D = root.get_node("Lights")

	var m_asphalt := _surface("res://materials/concrete_floor.tres", "town_asphalt", {
		"tint": Color(0.42, 0.42, 0.45), "macro_tint": Color(0.7, 0.7, 0.75), "macro_strength": 0.25,
		"edge_dirt_start": 21.5, "edge_dirt_end": 23.0, "uv_scale": 0.3})
	var m_pavement := _surface("res://materials/concrete_wall.tres", "town_pavement", {
		"tint": Color(0.95, 0.9, 0.85), "uv_scale": 0.35, "dirt_strength": 0.0})
	var m_wall := _surface("res://materials/brick_wall.tres", "town_wall", {"tint": Color(0.85, 0.8, 0.8)})
	var m_barrier: Material = load("res://materials/concrete_wall.tres")
	var m_metal: Material = load("res://materials/metal_crate.tres")

	# Ground: one collider, asphalt tiles, and pavement/lots in the four corners.
	_blocker(level, root, "Floor", Vector3(50, 1, 50), Vector3(0, -0.5, 0))
	_floor_tiles(detail, root, "Road", Vector2(-TOWN_EDGE, -TOWN_EDGE), Vector2(TOWN_EDGE, TOWN_EDGE), Vector2(11.5, 11.5), m_asphalt)
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			var a := Vector2(4.0 * sx, 4.0 * sz)
			var c := Vector2(TOWN_EDGE * sx, TOWN_EDGE * sz)
			_floor_tiles(detail, root, "Lot%d%d" % [sx + 1, sz + 1], Vector2(minf(a.x, c.x), minf(a.y, c.y)),
					Vector2(maxf(a.x, c.x), maxf(a.y, c.y)), Vector2(9.5, 9.5), m_pavement, 0.012)
	_road_markings(detail, root)

	# Perimeter walls, high enough to hide that the world ends.
	for w in [["WallN", Vector3(48, 3.2, 1), Vector3(0, 1.6, -TOWN_EDGE - 0.5)],
			["WallS", Vector3(48, 3.2, 1), Vector3(0, 1.6, TOWN_EDGE + 0.5)],
			["WallW", Vector3(1, 3.2, 48), Vector3(-TOWN_EDGE - 0.5, 1.6, 0)],
			["WallE", Vector3(1, 3.2, 48), Vector3(TOWN_EDGE + 0.5, 1.6, 0)]]:
		_solid(level, root, w[0], w[1], w[2], m_wall)

	# Houses: three per block, facing the streets, with an alley between two of
	# them that leads to the back gardens (where some enemies spawn).
	var k := 0
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			var b := _batch()
			var spots := [
				[Vector3(10.3 * sx, 0, 11.0 * sz), 0.0 if sz < 0 else 180.0],
				[Vector3(19.4 * sx, 0, 11.0 * sz), 0.0 if sz < 0 else 180.0],
				[Vector3(11.0 * sx, 0, 19.4 * sz), 90.0 if sx < 0 else -90.0],
			]
			for s: Array in spots:
				var model: String = HOUSES[k % HOUSES.size()]
				var box := _batch_model(b, SRC + "quaternius/%s.glb" % model, _place(s[0], s[1], HOUSE_SCALE), HOUSE_TINTS[k % HOUSE_TINTS.size()])
				_blocker(level, root, "House%d" % k, Vector3(box.size.x - 0.2, box.size.y, box.size.z - 0.2), box.get_center())
				k += 1
			_batch_mesh(b, detail, root, "Houses%d%d" % [sx + 1, sz + 1], "town_houses_%d%d" % [sx + 1, sz + 1])

	# Cars: parked, abandoned across lanes, and piled up at the road ends.
	var cars := [
		[Vector3(-8.5, 0, 2.6), 90.0], [Vector3(9.0, 0, -2.5), 272.0], [Vector3(15.0, 0, 2.3), 80.0],
		[Vector3(2.5, 0, -9.0), 2.0], [Vector3(-2.6, 0, 12.0), 175.0], [Vector3(-1.2, 0, -16.5), 35.0],
		[Vector3(-15.5, 0, -1.8), 118.0],
		# Road-end blockades.
		[Vector3(21.2, 0, -1.7), 4.0], [Vector3(21.0, 0, 1.6), 172.0],
		[Vector3(1.4, 0, -21.2), 88.0], [Vector3(-1.6, 0, 21.0), 95.0],
	]
	var cb := _batch()
	for i in cars.size():
		var c: Array = cars[i]
		var box := _batch_model(cb, SRC + "kenney/%s.glb" % CARS[i % CARS.size()], _place(c[0], c[1]),
				Color(0.75, 0.72, 0.7) if i % 3 == 0 else Color(0.9, 0.88, 0.85))
		_blocker(level, root, "Car%d" % i, Vector3(1.5, 1.3, 2.8), Vector3(c[0].x, 0.65, c[0].z), c[1])
	_batch_mesh(cb, detail, root, "Cars", "town_cars")

	# Concrete barriers at the west end of the main street.
	for i in 4:
		_solid(level, root, "Barrier%d" % i, Vector3(0.6, 1.0, 2.2), Vector3(-21.5, 0.5, -3.3 + i * 2.2), m_barrier, randf_range(-8, 8))

	# Street lights (4 lit at the crossing, 2 more that Low quality turns off),
	# a stop sign and a traffic light, merged into one mesh.
	var sb := _batch()
	var lamps := [
		[Vector3(5.3, 0, 5.3), false], [Vector3(-5.3, 0, 5.3), false], [Vector3(5.3, 0, -5.3), false],
		[Vector3(-5.3, 0, -5.3), false], [Vector3(15.0, 0, -5.3), true], [Vector3(-15.0, 0, 5.3), true],
	]
	for i in lamps.size():
		var p: Vector3 = lamps[i][0]
		_batch_model(sb, SRC + "quaternius/Streetlight_Single.glb", _place(p, 0.0, LAMP_SCALE), Color(0.6, 0.6, 0.62))
		_blocker(level, root, "LampPost%d" % i, Vector3(0.35, 4.8, 0.35), p + Vector3(0, 2.4, 0))
		_glow_bulb(detail, root, "Bulb%d" % i, p + Vector3(0, 4.7, 0))
		_omni(lights, root, "Lamp%d" % i, p + Vector3(0, 4.3, 0), Color(1.0, 0.7, 0.4), 2.2, 10.0, lamps[i][1])
	_batch_model(sb, SRC + "quaternius/Sign_Stop.glb", _place(Vector3(4.6, 0, -6.6), 180.0, LAMP_SCALE))
	_batch_model(sb, SRC + "quaternius/TrafficLight.glb", _place(Vector3(-6.4, 0, 4.6), 90.0, LAMP_SCALE))
	_batch_mesh(sb, detail, root, "StreetFurniture", "town_street")

	# Cover and clutter: dumpsters, barrels, crates, tyres, pallets.
	_solid(level, root, "Dumpster1", Vector3(1.9, 1.3, 1.1), Vector3(-9.0, 0.65, -5.6), m_metal, 3.0)
	_solid(level, root, "Dumpster2", Vector3(1.9, 1.3, 1.1), Vector3(13.5, 0.65, 5.6), m_metal, -4.0)
	var clutter := [
		["res://props/barrel_rust.tscn", Vector3(6.2, 0, 8.6), 0.0], ["res://props/barrel_rust.tscn", Vector3(7.0, 0, 9.3), 40.0],
		["res://props/barrel_red.tscn", Vector3(-6.5, 0, -10.5), 0.0], ["res://props/wood_crate.tscn", Vector3(-12.0, 0, 5.2), 15.0],
		["res://props/wood_crate.tscn", Vector3(10.5, 0, -5.4), -10.0], ["res://props/military_crate.tscn", Vector3(-4.8, 0, 16.0), 80.0],
		["res://props/tire.tscn", Vector3(4.8, 0, 14.5), 0.0], ["res://props/tire.tscn", Vector3(-17.5, 0, -5.0), 0.0],
		["res://props/pallet.tscn", Vector3(16.5, 0, -5.6), 20.0], ["res://props/jerrycan.tscn", Vector3(8.6, 0, -3.6), 30.0],
		["res://props/barrel_rust.tscn", Vector3(18.0, 0, 4.6), 0.0], ["res://props/wood_crate.tscn", Vector3(-6.0, 0, -15.0), 0.0],
	]
	for i in clutter.size():
		var c: Array = clutter[i]
		_prop(level, root, c[0], "Clutter%d" % i, c[1], c[2])
	# The yard's distant city skyline also surrounds the town.
	for side in ["N", "E", "S", "W"]:
		var mi := MeshInstance3D.new()
		mi.mesh = load("res://level/generated/skyline_%s.res" % side)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_add(detail, mi, "Skyline" + side, root)

	var spawns := [
		Vector3(18.5, 0, 0), Vector3(-19.0, 0, 0), Vector3(0, 0, -18.5), Vector3(0, 0, 18.5),
		Vector3(19.5, 0, 19.5), Vector3(-19.5, 0, 19.5), Vector3(19.5, 0, -19.5), Vector3(-19.5, 0, -19.5),
	]
	var pickups := [
		["RiflePickup", Vector3(5.6, 0, -2.0), 1], ["ShotgunPickup", Vector3(-11.5, 0, 2.6), 2],
		["SniperPickup", Vector3(12.0, 0, 5.4), 3],
		["AmmoBox1", Vector3(-5.6, 0, 9.0), -1], ["AmmoBox2", Vector3(8.0, 0, -5.4), -1], ["AmmoBox3", Vector3(-9.0, 0, -2.4), -1],
	]
	_finish_map(root, Vector3(0, 0, 7.0), 0.0, spawns, pickups)
	return root


func _glow_bulb(parent: Node, root: Node, n: String, pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.18
	s.height = 0.3
	s.radial_segments = 8
	s.rings = 4
	s.material = m_glow
	mi.mesh = s
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add(parent, mi, n, root)


# Dashed centre lines and stop lines: one mesh of white quads.
func _road_markings(parent: Node, root: Node) -> void:
	var b := _batch()
	var white := Color(0.85, 0.83, 0.78)
	for t in range(-22, 23, 3):
		if absf(t) < 6.0:
			continue
		_batch_box(b, Vector3(1.6, 0.01, 0.15), _place(Vector3(t, 0.008, 0), 0.0), white)
		_batch_box(b, Vector3(0.15, 0.01, 1.6), _place(Vector3(0, 0.008, t), 0.0), white)
	for s in [-1, 1]:
		_batch_box(b, Vector3(0.35, 0.01, 3.6), _place(Vector3(4.6 * s, 0.008, 2.0 * s), 0.0), white)
		_batch_box(b, Vector3(3.6, 0.01, 0.35), _place(Vector3(-2.0 * s, 0.008, 4.6 * s), 0.0), white)
	var mi := _batch_mesh(b, parent, root, "RoadMarkings", "town_markings", false, false)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


# --- Map 3: Warehouse Night ---------------------------------------------------

const WH_W := -16.0     # west wall (inside face)
const WH_E := 8.0       # east wall, with the loading door
const WH_Z := 13.0      # north/south walls at +-WH_Z
const WH_H := 7.0       # wall height (roof on top)
const DOOR_HALF := 4.0  # loading door: z -4..4
const YARD_E := 22.0    # east edge of the outdoor loading yard
const RACK_ROWS := [-10.2, -6.0, 6.0, 10.2]
const RACK_SEGMENTS := [Vector2(-14.5, -8.5), Vector2(-7.0, -1.0)]
const RACK_DEPTH := 1.1
const RACK_HEIGHT := 4.3


func _build_warehouse() -> Node3D:
	print("Warehouse:")
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.01, 0.015, 0.04)
	sky_mat.sky_horizon_color = Color(0.06, 0.07, 0.12)
	sky_mat.ground_horizon_color = Color(0.04, 0.04, 0.06)
	sky_mat.ground_bottom_color = Color(0.0, 0.0, 0.0)
	sky_mat.sun_angle_max = 1.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.32, 0.36, 0.5)
	env.ambient_light_energy = 0.35
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 4.0
	env.glow_enabled = true
	env.glow_intensity = 0.7
	env.glow_bloom = 0.1
	env.fog_enabled = true
	env.fog_light_color = Color(0.07, 0.08, 0.12)
	env.fog_density = 0.02
	env.fog_sky_affect = 0.5

	var root := _new_map("warehouse", "res://assets/music/warehouse_insistent.ogg", env)
	# Moonlight: cold and dim. The roof keeps it out of the warehouse.
	_sun(root, Vector3(-38.0, 35.0, 0.0), Color(0.55, 0.65, 1.0), 0.35)
	var level: Node3D = root.get_node("NavigationRegion3D/Level")
	var detail: Node3D = root.get_node("Detail")
	var lights: Node3D = root.get_node("Lights")

	var m_floor := _surface("res://materials/concrete_floor.tres", "wh_floor", {
		"tint": Color(0.75, 0.75, 0.78), "edge_dirt_start": 11.0, "edge_dirt_end": 13.0, "uv_scale": 0.3})
	var m_yard := _surface("res://materials/concrete_floor.tres", "wh_yard", {
		"tint": Color(0.45, 0.45, 0.5), "edge_dirt_start": 12.0, "edge_dirt_end": 14.0})
	var m_wall := _surface("res://materials/container_red.tres", "wh_wall", {
		"tint": Color(0.6, 0.66, 0.72), "macro_tint": Color(0.7, 0.72, 0.75)})
	var m_concrete: Material = load("res://materials/concrete_wall.tres")
	var m_roof: Material = load("res://materials/metal_crate.tres")
	var m_cont: Material = load("res://materials/container_blue.tres")

	_blocker(level, root, "Floor", Vector3(42, 1, 30), Vector3(3, -0.5, 0))
	_floor_tiles(detail, root, "Floor", Vector2(WH_W, -WH_Z), Vector2(WH_E, WH_Z), Vector2(6.0, 6.5), m_floor)
	_floor_tiles(detail, root, "Yard", Vector2(WH_E, -WH_Z - 1), Vector2(YARD_E, WH_Z + 1), Vector2(7.0, 7.0), m_yard)

	# Warehouse walls and roof (the roof is outside the navmesh region, so
	# nothing tries to walk on top of it).
	var wall_len := WH_E - WH_W + 1.0
	var mid_x := (WH_W + WH_E) * 0.5
	_solid(level, root, "WallW", Vector3(0.5, WH_H, 2 * WH_Z + 1), Vector3(WH_W - 0.25, WH_H / 2, 0), m_wall)
	_solid(level, root, "WallN", Vector3(wall_len, WH_H, 0.5), Vector3(mid_x, WH_H / 2, -WH_Z - 0.25), m_wall)
	_solid(level, root, "WallS", Vector3(wall_len, WH_H, 0.5), Vector3(mid_x, WH_H / 2, WH_Z + 0.25), m_wall)
	var side := WH_Z - DOOR_HALF
	_solid(level, root, "WallE1", Vector3(0.5, WH_H, side + 0.5), Vector3(WH_E + 0.25, WH_H / 2, -DOOR_HALF - (side + 0.5) / 2), m_wall)
	_solid(level, root, "WallE2", Vector3(0.5, WH_H, side + 0.5), Vector3(WH_E + 0.25, WH_H / 2, DOOR_HALF + (side + 0.5) / 2), m_wall)
	_solid(level, root, "DoorHeader", Vector3(0.5, 2.0, 2 * DOOR_HALF), Vector3(WH_E + 0.25, WH_H - 1.0, 0), m_wall)
	_solid(root, root, "Roof", Vector3(wall_len + 0.5, 0.3, 2 * WH_Z + 1.5), Vector3(mid_x, WH_H + 0.15, 0), m_roof)
	# Loading yard walls.
	var yard_len := YARD_E - WH_E + 1.0
	_solid(level, root, "YardWallN", Vector3(yard_len, 2.8, 0.5), Vector3((WH_E + YARD_E) / 2 + 0.5, 1.4, -WH_Z - 0.75), m_concrete)
	_solid(level, root, "YardWallS", Vector3(yard_len, 2.8, 0.5), Vector3((WH_E + YARD_E) / 2 + 0.5, 1.4, WH_Z + 0.75), m_concrete)
	_solid(level, root, "YardWallE", Vector3(0.5, 2.8, 2 * WH_Z + 2), Vector3(YARD_E + 0.75, 1.4, 0), m_concrete)

	# Pallet racks: steel frames with pallets and boxes, one merged mesh.
	var rb := _batch()
	var k := 0
	for z: float in RACK_ROWS:
		for seg: Vector2 in RACK_SEGMENTS:
			_build_rack(rb, seg.x, seg.y, z)
			_blocker(level, root, "Rack%d" % k, Vector3(seg.y - seg.x, RACK_HEIGHT, RACK_DEPTH),
					Vector3((seg.x + seg.y) / 2, RACK_HEIGHT / 2, z))
			k += 1
	_batch_mesh(rb, detail, root, "Racks", "wh_racks")

	# Forklifts (and a parked truck outside), one merged mesh.
	var fb := _batch()
	var forklifts := [[Vector3(-3.5, 0, 2.6), 32.0], [Vector3(3.2, 0, -8.3), -100.0], [Vector3(-11.6, 0, -1.0), 90.0]]
	for i in forklifts.size():
		var f: Array = forklifts[i]
		_build_forklift(fb, _place(f[0], f[1]))
		_blocker(level, root, "Forklift%d" % i, Vector3(1.25, 2.2, 3.0), f[0] + Basis(Vector3.UP, deg_to_rad(f[1])) * Vector3(0, 1.1, -0.3), f[1])
	var truck := _batch_model(fb, SRC + "kenney/truck.glb", _place(Vector3(15.0, 0, 7.5), 90.0, 1.6), Color(0.8, 0.8, 0.85))
	_blocker(level, root, "Truck", truck.size - Vector3(0.1, 0, 0.1), truck.get_center())
	_batch_mesh(fb, detail, root, "Vehicles", "wh_vehicles")

	# Shipping container and clutter outside; crates and barrels inside.
	_solid(level, root, "Container", Vector3(6.0, 2.6, 2.45), Vector3(16.5, 1.3, -10.2), m_cont)
	var clutter := [
		["res://props/wood_crate.tscn", Vector3(-8.8, 0, -2.6), 10.0], ["res://props/wood_crate.tscn", Vector3(-8.0, 0, -3.5), -5.0],
		["res://props/military_crate.tscn", Vector3(-5.0, 0, 3.8), 90.0], ["res://props/barrel_rust.tscn", Vector3(2.6, 0, 4.2), 0.0],
		["res://props/barrel_red.tscn", Vector3(3.3, 0, 4.9), 0.0], ["res://props/pallet.tscn", Vector3(5.5, 0, -3.5), 15.0],
		["res://props/pallet.tscn", Vector3(-14.8, 0, 3.0), 90.0], ["res://props/military_crate.tscn", Vector3(-1.0, 0, -11.6), 0.0],
		["res://props/barrel_rust.tscn", Vector3(12.5, 0, -6.0), 0.0], ["res://props/barrel_rust.tscn", Vector3(13.2, 0, -5.3), 0.0],
		["res://props/wood_crate.tscn", Vector3(19.5, 0, 6.0), 30.0], ["res://props/tire.tscn", Vector3(11.0, 0, 11.0), 0.0],
		["res://props/jerrycan.tscn", Vector3(10.4, 0, 3.6), 70.0], ["res://props/wood_crate.tscn", Vector3(-12.5, 0, 11.6), 0.0],
	]
	for i in clutter.size():
		var c: Array = clutter[i]
		_prop(level, root, c[0], "Clutter%d" % i, c[1], c[2])

	# Lamps: ceiling lights over the main aisle (always on) and over the rack
	# aisles (Low quality turns those off), a floodlight in the yard.
	var fixtures := _batch()
	var lamps := [
		[Vector3(-12.0, 0, 0), false], [Vector3(-4.5, 0, 0), false], [Vector3(3.0, 0, 0), false],
		[Vector3(-7.75, 0, -8.1), true], [Vector3(-7.75, 0, 8.1), true],
	]
	for i in lamps.size():
		var p: Vector3 = lamps[i][0]
		_batch_box(fixtures, Vector3(1.4, 0.12, 0.45), _place(p + Vector3(0, 6.15, 0), 0.0), Color(0.25, 0.25, 0.27))
		_batch_box(fixtures, Vector3(0.03, 0.8, 0.03), _place(p + Vector3(0, 6.6, 0), 0.0), Color(0.1, 0.1, 0.1))
		var tube := MeshInstance3D.new()
		var tm := BoxMesh.new()
		tm.size = Vector3(1.25, 0.05, 0.3)
		tm.material = m_glow
		tube.mesh = tm
		tube.position = p + Vector3(0, 6.07, 0)
		tube.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_add(detail, tube, "LampTube%d" % i, root)
		_omni(lights, root, "Lamp%d" % i, p + Vector3(0, 5.8, 0), Color(1.0, 0.86, 0.62), 2.4, 11.0, lamps[i][1])
	# Floodlight pole in the yard, aimed at the loading door.
	var pole := Vector3(20.6, 0, 0.8)
	_batch_cyl(fixtures, 0.1, 6.0, _place(pole + Vector3(0, 3.0, 0), 0.0), Color(0.3, 0.3, 0.32))
	_batch_box(fixtures, Vector3(0.6, 0.45, 0.5), _place(pole + Vector3(-0.3, 6.0, 0), 0.0), Color(0.2, 0.2, 0.22))
	_blocker(level, root, "FloodPole", Vector3(0.35, 6.0, 0.35), pole + Vector3(0, 3.0, 0))
	_batch_mesh(fixtures, detail, root, "LampFixtures", "wh_fixtures", true, false)
	var spot := SpotLight3D.new()
	spot.position = pole + Vector3(-0.6, 5.9, 0)
	spot.light_color = Color(0.85, 0.9, 1.0)
	spot.light_energy = 4.0
	spot.spot_range = 24.0
	spot.spot_angle = 38.0
	spot.shadow_enabled = false
	spot.transform = Transform3D(Basis.looking_at(Vector3(9.0, 0.0, 0.0) - spot.position, Vector3.UP), spot.position)
	_add(lights, spot, "Floodlight", root)
	var flood_glow := MeshInstance3D.new()
	var fq := BoxMesh.new()
	fq.size = Vector3(0.06, 0.35, 0.4)
	fq.material = m_glow
	flood_glow.mesh = fq
	flood_glow.position = pole + Vector3(-0.62, 6.0, 0)
	_add(detail, flood_glow, "FloodGlow", root)
	# A wall lamp over the door outside.
	_glow_bulb(detail, root, "DoorLampBulb", Vector3(WH_E + 0.6, 5.6, 0))
	_omni(lights, root, "DoorLamp", Vector3(WH_E + 1.0, 5.3, 0), Color(1.0, 0.7, 0.45), 1.6, 8.0, true)

	var spawns := [
		Vector3(20.5, 0, -11.5), Vector3(20.5, 0, 11.5), Vector3(18.5, 0, 3.2),
		Vector3(-15.0, 0, 0.0), Vector3(-15.0, 0, -11.8), Vector3(-15.0, 0, 11.8),
		Vector3(-15.2, 0, -8.1), Vector3(-15.2, 0, 8.1),
	]
	var pickups := [
		["RiflePickup", Vector3(-1.5, 0, -3.0), 1], ["ShotgunPickup", Vector3(-12.0, 0, -8.1), 2],
		["SniperPickup", Vector3(16.0, 0, 2.0), 3],
		["AmmoBox1", Vector3(0.5, 0, 8.1), -1], ["AmmoBox2", Vector3(-7.75, 0, -2.0), -1], ["AmmoBox3", Vector3(12.0, 0, -3.5), -1],
	]
	_finish_map(root, Vector3(5.0, 0, 0.5), PI / 2.0, spawns, pickups)
	return root


# One rack segment from x0 to x1 at row z: uprights every ~3 m, three beam
# levels, and pallets with boxes on most shelves.
func _build_rack(b: Dictionary, x0: float, x1: float, z: float) -> void:
	var blue := Color(0.12, 0.24, 0.55)
	var orange := Color(0.95, 0.42, 0.08)
	var wood := Color(0.55, 0.4, 0.25)
	var bays := maxi(1, roundi((x1 - x0) / 3.0))
	var bay := (x1 - x0) / bays
	var d := RACK_DEPTH * 0.5
	for i in bays + 1:
		var x := x0 + i * bay
		for dz in [-d + 0.04, d - 0.04]:
			_batch_box(b, Vector3(0.08, RACK_HEIGHT, 0.08), _place(Vector3(x, RACK_HEIGHT / 2, z + dz), 0.0), blue)
		for y in [0.6, 2.0, 3.4]:
			_batch_box(b, Vector3(0.05, 0.05, RACK_DEPTH - 0.1), _place(Vector3(x, y, z), 0.0), blue)
	var levels := [0.12, 1.42, 2.82]
	for y: float in levels:
		if y > 0.5:
			for dz in [-d + 0.04, d - 0.04]:
				_batch_box(b, Vector3(x1 - x0, 0.12, 0.06), _place(Vector3((x0 + x1) / 2, y, z + dz), 0.0), orange)
		for i in bays:
			if randf() < 0.18:
				continue
			for p in 2:
				var px := x0 + bay * i + bay * (0.27 + 0.46 * p)
				var base := Vector3(px, y + 0.06, z)
				_batch_box(b, Vector3(1.1, 0.14, RACK_DEPTH - 0.15), _place(base + Vector3(0, 0.07, 0), 0.0), wood)
				var stack := randi_range(1, 3)
				for s in stack:
					var tint := Color(0.85, 0.7, 0.5) * randf_range(0.8, 1.1)
					var bh := randf_range(0.35, 0.5)
					_batch_box(b, Vector3(randf_range(0.85, 1.05), bh, RACK_DEPTH - randf_range(0.2, 0.35)),
							_place(base + Vector3(0, 0.14 + bh * (s + 0.5), 0), randf_range(-4, 4)), tint)


# A simple forklift from boxes and cylinders, ~1.2 x 2.2 x 3 m; forks face -Z.
func _build_forklift(b: Dictionary, xf: Transform3D) -> void:
	var yellow := Color(0.95, 0.68, 0.08)
	var dark := Color(0.12, 0.12, 0.13)
	var steel := Color(0.45, 0.45, 0.47)
	var p := func(pos: Vector3) -> Transform3D:
		return xf * _place(pos, 0.0)
	_batch_box(b, Vector3(1.15, 0.75, 1.9), p.call(Vector3(0, 0.6, 0.15)), yellow)          # body
	_batch_box(b, Vector3(1.15, 0.6, 0.45), p.call(Vector3(0, 0.95, 1.0)), dark)            # counterweight
	_batch_box(b, Vector3(0.55, 0.12, 0.5), p.call(Vector3(0, 1.05, 0.35)), dark)           # seat
	_batch_box(b, Vector3(0.5, 0.45, 0.1), p.call(Vector3(0, 1.3, 0.6)), dark)              # backrest
	for x in [-0.52, 0.52]:
		for z in [-0.55, 0.85]:
			_batch_box(b, Vector3(0.06, 1.3, 0.06), p.call(Vector3(x, 1.6, z)), dark)       # guard posts
	_batch_box(b, Vector3(1.15, 0.06, 1.5), p.call(Vector3(0, 2.25, 0.15)), dark)           # overhead guard
	_batch_box(b, Vector3(0.3, 0.3, 0.15), p.call(Vector3(0, 1.25, -0.45)), dark)           # steering
	for x in [-0.4, 0.4]:
		_batch_box(b, Vector3(0.1, 2.3, 0.12), p.call(Vector3(x, 1.15, -0.95)), steel)      # mast
	_batch_box(b, Vector3(0.9, 0.5, 0.08), p.call(Vector3(0, 0.45, -1.05)), steel)          # carriage
	for x in [-0.3, 0.3]:
		_batch_box(b, Vector3(0.12, 0.05, 1.1), p.call(Vector3(x, 0.12, -1.6)), steel)      # forks
	var wheel := Basis(Vector3.BACK, PI / 2.0)
	for w in [Vector3(-0.6, 0.28, -0.55), Vector3(0.6, 0.28, -0.55), Vector3(-0.6, 0.24, 0.85), Vector3(0.6, 0.24, 0.85)]:
		_batch_cyl(b, 0.28 if w.z < 0 else 0.24, 0.25, xf * Transform3D(wheel, w), dark, 10)


# --- Saving ----------------------------------------------------------------------

## Saves the map, bakes its navmesh from the collision boxes under
## NavigationRegion3D, then saves the map again with the navmesh in it.
func _save_map(map_root: Node3D, id: String) -> void:
	var scene_path := "res://maps/%s.tscn" % id
	var nav_path := "res://maps/%s_navmesh.res" % id
	var ps := PackedScene.new()
	ps.pack(map_root)
	ResourceSaver.save(ps, scene_path)

	# Bake in a copy that is in the tree (only the navigation region, so
	# the game itself doesn't start).
	var copy: Node3D = load(scene_path).instantiate()
	var region: NavigationRegion3D = copy.get_node("NavigationRegion3D")
	copy.remove_child(region)
	copy.free()
	root.add_child(region)
	var yard: NavigationMesh = load("res://level_navmesh.res")
	var nm := NavigationMesh.new()
	for p in ["cell_size", "cell_height", "agent_radius", "agent_height", "agent_max_climb", "agent_max_slope",
			"geometry_parsed_geometry_type", "geometry_collision_mask", "region_min_size", "edge_max_error"]:
		nm.set(p, yard.get(p))
	region.navigation_mesh = nm
	region.bake_navigation_mesh(false)
	ResourceSaver.save(nm, nav_path)
	print("  navmesh: %d polygons" % nm.get_polygon_count())
	region.free()

	map_root.get_node("NavigationRegion3D").navigation_mesh = load(nav_path)
	ps = PackedScene.new()
	ps.pack(map_root)
	ResourceSaver.save(ps, scene_path)
	map_root.free()
	print("  saved ", scene_path)
