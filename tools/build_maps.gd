extends SceneTree
## Builds the extra maps, maps/town.tscn, maps/warehouse.tscn and the
## Training Arena maps/training.tscn, from code, and does a first bake of
## their navmeshes (maps/<id>_navmesh.res); run tools/bake_navmesh.gd
## afterwards for the final ones (tools/rebake.bat also bakes the training
## lightmap). `-- --only <id>` builds just one of them.
## Each map is a full game scene running main.gd, with the same nodes as
## main.tscn (Player, HUD, Enemies, SpawnPoints, SpawnTimer, Pickups, Sun...).
## Run: godot --headless --path . --script res://tools/build_maps.gd
## Safe to re-run: it overwrites everything it made before.
##
## Kept light for phones:
## - Models (houses, cars, street lights, shelves, forklifts) are merged into
##   a few vertex-coloured meshes, one draw call each.
## - Floors are split into tiles so each lamp only re-lights nearby tiles.
## - Baked light (LightmapGI, tools/rebake.bat): houses, floors and kit chunks
##   are lightmapped (low-res, indirect light only); cars, racks and props are
##   lit by the probes. A few real-time lamps; the extra ones are BAKE_STATIC.
## - Collisions are plain boxes.
## - Walls, roof, barriers, dumpsters, container, signs and pipes are pieces of
##   the Blender level kit (tools/kit_builder.gd, tools/blender/build_kit.py).
## The source models live in assets/models/map_sources/ (not exported).

const Kit := preload("res://tools/kit_builder.gd")
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
	# `-- --only training` rebuilds just that map (the others stay untouched).
	var args := OS.get_cmdline_user_args()
	var only := args[args.find("--only") + 1] if args.find("--only") >= 0 and args.find("--only") + 1 < args.size() else ""
	if only in ["", "town"]:
		_save_map(_build_town(), "town")
	if only in ["", "warehouse"]:
		_save_map(_build_warehouse(), "warehouse")
	if only in ["", "training"]:
		_save_map(_build_training(), "training")
	print("BUILD_MAPS: done. Now run tools/bake_navmesh.gd for the final navmeshes")
	print("  (Brute/Boss navmeshes, unreachable islands removed).")
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
func _new_map(map_id: String, music_path: String, env: Environment, script := "res://main.gd") -> Node3D:
	var root := Node3D.new()
	root.name = "Main"
	root.set_script(load(script))
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
			pm.add_uv2 = true  # lightmap UVs (town, warehouse)
			mi.mesh = pm
			mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
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
		# Extra lamps only exist in the lightmap: no real-time cost at any quality.
		l.light_bake_mode = Light3D.BAKE_STATIC
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
	# Not baked (small or many parts): lit by the lightmap probes instead.
	mi.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
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
## Lightmap texel size (m) of the town and warehouse meshes: low-res bounce light
## is enough and keeps the lightmaps small for phones.
const BAKE_TEXEL := 0.5
## Kit pieces switch to their plain LOD1 meshes (and wall details disappear)
## beyond this distance (visibility ranges, see tools/kit_builder.gd).
const TOWN_LOD_DISTANCE := 24.0
const WAREHOUSE_LOD_DISTANCE := 22.0
## How far each house's front wall sits behind the front of its box (porches,
## roofs and balconies stick out further), so wall details sit on the wall.
const HOUSE_FRONT_INSET := {}


func _build_town() -> Node3D:
	print("Town:")
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.13, 0.16, 0.3)
	sky_mat.sky_horizon_color = Color(0.78, 0.55, 0.45)
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
	var sun := _sun(root, Vector3(-11.0, -72.0, 0.0), Color(1.0, 0.64, 0.42), 1.15)
	sun.light_angular_distance = 1.5  # soft baked shadows
	var level: Node3D = root.get_node("NavigationRegion3D/Level")
	var detail: Node3D = root.get_node("Detail")
	var lights: Node3D = root.get_node("Lights")

	var m_asphalt := _surface("res://materials/concrete_floor.tres", "town_asphalt", {
		"tint": Color(0.42, 0.42, 0.45), "macro_tint": Color(0.7, 0.7, 0.75), "macro_strength": 0.25,
		"edge_dirt_start": 21.5, "edge_dirt_end": 23.0, "uv_scale": 0.3})
	var m_pavement := _surface("res://materials/concrete_wall.tres", "town_pavement", {
		"tint": Color(0.95, 0.9, 0.85), "uv_scale": 0.35, "dirt_strength": 0.0})

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

	# Perimeter walls, high enough to hide that the world ends: box colliders,
	# and kit brick wall segments with pillars (a few of them broken).
	var kit := Kit.new()
	for w in [["WallN", Vector3(48, 3.2, 1), Vector3(0, 1.6, -TOWN_EDGE - 0.5)],
			["WallS", Vector3(48, 3.2, 1), Vector3(0, 1.6, TOWN_EDGE + 0.5)],
			["WallW", Vector3(1, 3.2, 48), Vector3(-TOWN_EDGE - 0.5, 1.6, 0)],
			["WallE", Vector3(1, 3.2, 48), Vector3(TOWN_EDGE + 0.5, 1.6, 0)]]:
		_blocker(level, root, w[0], w[1], w[2])
	var e := TOWN_EDGE + 0.5
	kit.wall_run(Vector3(-e, 0, -e), Vector3(e, 0, -e), "wall_town", "pillar_town", [2, 8])
	kit.wall_run(Vector3(-e, 0, e), Vector3(e, 0, e), "wall_town", "pillar_town", [4])
	kit.wall_run(Vector3(e, 0, -e), Vector3(e, 0, e), "wall_town", "pillar_town", [7], Color.WHITE, false)
	kit.wall_run(Vector3(-e, 0, -e), Vector3(-e, 0, e), "wall_town", "pillar_town", [1, 9], Color.WHITE, false)

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
				_house_details(kit, model, box, s[1], k)
				k += 1
			_lm_batch_mesh(b, detail, root, "Houses%d%d" % [sx + 1, sz + 1], "town_houses_%d%d" % [sx + 1, sz + 1], BAKE_TEXEL)

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
		var yaw := randf_range(-8, 8)
		var at := Vector3(-21.5, 0.0, -3.3 + i * 2.2)
		_blocker(level, root, "Barrier%d" % i, Vector3(0.6, 1.0, 2.2), at + Vector3(0, 0.5, 0), yaw)
		kit.add("barrier_broken" if i == 2 else "barrier",
				Transform3D(Basis(Vector3.UP, deg_to_rad(yaw + 90.0)) * Basis.from_scale(Vector3(2.2 / 3.0, 1, 1)), at))

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
	for d: Array in [["Dumpster1", Vector3(-9.0, 0, -5.6), 3.0], ["Dumpster2", Vector3(13.5, 0, 5.6), -4.0]]:
		_blocker(level, root, d[0], Vector3(1.9, 1.3, 1.1), d[1] + Vector3(0, 0.65, 0), d[2])
		kit.add("dumpster", _place(d[1], d[2]), Color(0.8, 0.9, 0.8) if d[0] == "Dumpster1" else Color(0.7, 0.8, 1.2))
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
	kit.build(detail, root, "Kit", {"lod_distance": TOWN_LOD_DISTANCE, "file_prefix": "town_kit", "lightmap": true})

	var spawns := [
		Vector3(18.5, 0, 0), Vector3(-19.0, 0, 0), Vector3(0, 0, -18.5), Vector3(0, 0, 18.5),
		Vector3(19.5, 0, 19.5), Vector3(-19.5, 0, 19.5), Vector3(19.5, 0, -19.5), Vector3(-19.5, 0, -19.5),
	]
	var pickups := [
		["RiflePickup", Vector3(5.6, 0, -2.0), 1], ["ShotgunPickup", Vector3(-11.5, 0, 2.6), 2],
		["SniperPickup", Vector3(12.0, 0, 5.4), 3],
		["AmmoBox1", Vector3(-5.6, 0, 9.0), -1], ["AmmoBox2", Vector3(8.0, 0, -5.4), -1], ["AmmoBox3", Vector3(-9.0, 0, -2.4), -1],
	]
	_add_lightmap(root, sun, Color(0.36, 0.42, 0.58), 0.8)
	_finish_map(root, Vector3(0, 0, 7.0), 0.0, spawns, pickups)
	return root


## Kit details on a house's street side: a shop sign on some, downpipes at
## the front corners, an AC unit on others. `box` is the house's world box,
## `yaw` its rotation (its front faces +Z rotated by yaw).
func _house_details(kit: Kit, model: String, box: AABB, yaw: float, k: int) -> void:
	var front := Basis(Vector3.UP, deg_to_rad(yaw)) * Vector3.BACK
	front = front.round()
	var side := front.cross(Vector3.UP)
	var half := (box.size * 0.5).dot(front.abs())
	var width := (box.size * 0.5).dot(side.abs())
	var inset: float = HOUSE_FRONT_INSET.get(model, 0.0)
	var face := box.get_center() + front * (half - inset)
	face.y = 0.0
	var two_story := model.begins_with("2Story")
	# Downpipes at both front corners, up to the eaves.
	for s in [-1.0, 1.0]:
		kit.downpipe(face + side * s * (width - 0.35), front, 5.6 if two_story else 2.9)
	match k % 4:
		0:
			kit.mount(["sign_garage", "sign_pharmacy"][(k / 4) % 2], face + Vector3(0, 2.75, 0), front)
		1:
			kit.mount(["sign_diner", "sign_hotel"][(k / 4) % 2], face + side * (width * 0.45) + Vector3(0, 2.6, 0), front)
		2:
			kit.mount("ac_unit", face - side * (width * 0.4) + Vector3(0, 2.2, 0), front)
		3:
			kit.mount("lamp_wall", face + side * 1.2 + Vector3(0, 2.4, 0), front)


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
	var sun := _sun(root, Vector3(-38.0, 35.0, 0.0), Color(0.55, 0.65, 1.0), 0.35)
	sun.light_angular_distance = 1.0
	var level: Node3D = root.get_node("NavigationRegion3D/Level")
	var detail: Node3D = root.get_node("Detail")
	var lights: Node3D = root.get_node("Lights")

	var m_floor := _surface("res://materials/concrete_floor.tres", "wh_floor", {
		"tint": Color(0.75, 0.75, 0.78), "edge_dirt_start": 11.0, "edge_dirt_end": 13.0, "uv_scale": 0.3})
	var m_yard := _surface("res://materials/concrete_floor.tres", "wh_yard", {
		"tint": Color(0.45, 0.45, 0.5), "edge_dirt_start": 12.0, "edge_dirt_end": 14.0})

	_blocker(level, root, "Floor", Vector3(42, 1, 30), Vector3(3, -0.5, 0))
	_floor_tiles(detail, root, "Floor", Vector2(WH_W, -WH_Z), Vector2(WH_E, WH_Z), Vector2(6.0, 6.5), m_floor)
	_floor_tiles(detail, root, "Yard", Vector2(WH_E, -WH_Z - 1), Vector2(YARD_E, WH_Z + 1), Vector2(7.0, 7.0), m_yard)

	# Warehouse walls and roof (the roof is outside the navmesh region, so
	# nothing tries to walk on top of it).
	var wall_len := WH_E - WH_W + 1.0
	var mid_x := (WH_W + WH_E) * 0.5
	_blocker(level, root, "WallW", Vector3(0.5, WH_H, 2 * WH_Z + 1), Vector3(WH_W - 0.25, WH_H / 2, 0))
	_blocker(level, root, "WallN", Vector3(wall_len, WH_H, 0.5), Vector3(mid_x, WH_H / 2, -WH_Z - 0.25))
	_blocker(level, root, "WallS", Vector3(wall_len, WH_H, 0.5), Vector3(mid_x, WH_H / 2, WH_Z + 0.25))
	var side := WH_Z - DOOR_HALF
	_blocker(level, root, "WallE1", Vector3(0.5, WH_H, side + 0.5), Vector3(WH_E + 0.25, WH_H / 2, -DOOR_HALF - (side + 0.5) / 2))
	_blocker(level, root, "WallE2", Vector3(0.5, WH_H, side + 0.5), Vector3(WH_E + 0.25, WH_H / 2, DOOR_HALF + (side + 0.5) / 2))
	_blocker(level, root, "DoorHeader", Vector3(0.5, 2.0, 2 * DOOR_HALF), Vector3(WH_E + 0.25, WH_H - 1.0, 0))
	_blocker(root, root, "Roof", Vector3(wall_len + 0.5, 0.3, 2 * WH_Z + 1.5), Vector3(mid_x, WH_H + 0.15, 0))
	# Loading yard walls.
	var yard_len := YARD_E - WH_E + 1.0
	_blocker(level, root, "YardWallN", Vector3(yard_len, 2.8, 0.5), Vector3((WH_E + YARD_E) / 2 + 0.5, 1.4, -WH_Z - 0.75))
	_blocker(level, root, "YardWallS", Vector3(yard_len, 2.8, 0.5), Vector3((WH_E + YARD_E) / 2 + 0.5, 1.4, WH_Z + 0.75))
	_blocker(level, root, "YardWallE", Vector3(0.5, 2.8, 2 * WH_Z + 2), Vector3(YARD_E + 0.75, 1.4, 0))
	var kit := Kit.new()
	_warehouse_kit(kit)

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
	_blocker(level, root, "Container", Vector3(6.0, 2.6, 2.45), Vector3(16.5, 1.3, -10.2))
	kit.add("container", Transform3D(Basis.from_scale(Vector3(6.0 / 6.1, 1, 1)), Vector3(16.5, 0, -10.2)), Color(0.5, 0.75, 1.2))
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
	# A wall lamp over the door outside (its housing is in the kit).
	_glow_bulb(detail, root, "DoorLampBulb", Vector3(WH_E + 0.5 + 0.45, 5.52, 0))
	_omni(lights, root, "DoorLamp", Vector3(WH_E + 1.0, 5.3, 0), Color(1.0, 0.7, 0.45), 1.6, 8.0, true)
	kit.build(detail, root, "Kit", {"lod_distance": WAREHOUSE_LOD_DISTANCE, "file_prefix": "warehouse_kit", "lightmap": true})

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
	_add_lightmap(root, sun, Color(0.12, 0.16, 0.3), 0.6)
	_finish_map(root, Vector3(5.0, 0, 0.5), PI / 2.0, spawns, pickups)
	return root


## The warehouse shell from kit pieces: clad walls (with high windows), steel
## columns, the loading door frame and header, roof sheets on trusses, the
## yard's concrete walls, pipes, signs and lamps.
func _warehouse_kit(kit: Kit) -> void:
	var clad := Color(0.78, 0.88, 1.0)
	var t := 0.25  # half the wall thickness
	# North and south walls (x from WH_W-0.5 to WH_E+0.5), west wall.
	for z in [-WH_Z - t, WH_Z + t]:
		_wh_wall_run(kit, Vector3(WH_W - 0.5, 0, z), Vector3(WH_E + 0.5, 0, z), clad)
	_wh_wall_run(kit, Vector3(WH_W - t, 0, -WH_Z - 0.5), Vector3(WH_W - t, 0, WH_Z + 0.5), clad)
	# East wall either side of the loading door, the door frame and header.
	for s in [-1.0, 1.0]:
		_wh_wall_run(kit, Vector3(WH_E + t, 0, s * (WH_Z + 0.5)), Vector3(WH_E + t, 0, s * DOOR_HALF), clad, false)
	kit.add("wh_door_frame", _place(Vector3(WH_E + t, 0, 0), 90.0))
	kit.add("wh_header", _place(Vector3(WH_E + t, WH_H - 2.0, 0), 90.0), clad)
	# Steel columns on the inside, every 4 m along the long walls.
	var x := WH_W + 4.0
	while x < WH_E - 1.0:
		kit.mount("wh_column", Vector3(x, 0, -WH_Z), Vector3.BACK)
		kit.mount("wh_column", Vector3(x, 0, WH_Z), Vector3.FORWARD)
		x += 4.0
	for z in [-6.0, 6.0]:
		kit.mount("wh_column", Vector3(WH_W, 0, z), Vector3.RIGHT)
	# Roof: corrugated sheets on top, trusses under them.
	var x0 := WH_W - 0.75
	var x1 := WH_E + 0.75
	var nz := 7
	var nx := 7
	for i in nx:
		for j in nz:
			var sx := (x1 - x0) / nx
			var sz := (2 * WH_Z + 1.5) / nz
			kit.add("roof_sheet", Transform3D(Basis.from_scale(Vector3(sx / 4.0, 1, sz / 4.0)),
					Vector3(x0 + sx * (i + 0.5), WH_H + 0.3, -WH_Z - 0.75 + sz * (j + 0.5))), Color(0.7, 0.75, 0.8))
	x = WH_W + 2.0
	while x < WH_E:
		kit.add("truss", _place(Vector3(x, WH_H, 0), 0.0))
		x += 4.0
	# Pipes along the inside of the north wall, with drops to the floor.
	kit.mount("pipe_h", Vector3(-4.0, 5.6, -WH_Z), Vector3.BACK, Color.WHITE, Vector3(22.0, 1, 1))
	for px in [-14.6, 6.6]:
		kit.downpipe(Vector3(px, 0, -WH_Z), Vector3.BACK, 5.6)
	kit.mount("ac_unit", Vector3(-2.0, 1.4, WH_Z), Vector3.FORWARD, Color(0.8, 0.8, 0.75))
	# Signs: over the door outside and inside, and on the yard wall.
	kit.mount("sign_loading", Vector3(WH_E + 2 * t, 5.25, -2.6), Vector3.RIGHT)
	kit.mount("lamp_wall", Vector3(WH_E + 2 * t, 5.6, 0), Vector3.RIGHT)
	kit.mount("sign_exit", Vector3(WH_E, 5.2, 0), Vector3.LEFT)
	kit.mount("sign_exit", Vector3(WH_W, 2.6, 0), Vector3.RIGHT)
	kit.mount("sign_danger", Vector3(YARD_E + 0.5, 1.7, -5.0), Vector3.LEFT)
	# Downpipes on the outside corners by the yard.
	for s in [-1.0, 1.0]:
		kit.downpipe(Vector3(WH_E + 2 * t, 0, s * (WH_Z - 0.4)), Vector3.RIGHT, WH_H - 0.3)
	# Loading yard walls: concrete, a couple of broken segments.
	var yz := WH_Z + 0.75
	var ye := YARD_E + 0.75
	kit.wall_run(Vector3(WH_E + 0.5, 0, -yz), Vector3(ye, 0, -yz), "wall_low", "pillar_low", [1])
	kit.wall_run(Vector3(WH_E + 0.5, 0, yz), Vector3(ye, 0, yz), "wall_low", "pillar_low", [])
	kit.wall_run(Vector3(ye, 0, -yz), Vector3(ye, 0, yz), "wall_low", "pillar_low", [4], Color.WHITE, false)


## Warehouse wall from a to b: 4 m clad segments, every other one with windows.
func _wh_wall_run(kit: Kit, a: Vector3, b: Vector3, tint: Color, windows := true) -> void:
	var d := b - a
	var n := maxi(1, roundi(d.length() / 4.0))
	var s := d.length() / n
	var dir := d.normalized()
	var rot := Basis(Vector3.UP, atan2(-dir.z, dir.x))
	for i in n:
		var piece := "wh_wall_window" if windows and i % 2 == 1 else "wh_wall"
		kit.add(piece, Transform3D(rot * Basis.from_scale(Vector3(s / 4.0, 1, 1)), a + dir * s * (i + 0.5)), tint)


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


# --- Training Arena -----------------------------------------------------------------
# A shooting range: a roofed shooting hall (the weapon rack on its back wall)
# and an open range downrange (-Z) to a sand berm past the 100 m targets.
# Lanes across the range: static targets on the left, pop-ups and moving
# targets in the middle, the dummies on the right. The firing line is z = 0.
# Lit by the sun plus a baked lightmap (maps/training.lmbake, rebake.bat):
# the hall lamps are bake-only lights, so nothing but the sun is real-time.
# Target, dummy and rack positions are in training_config.gd.

const TR := preload("res://training_config.gd")
const TR_HALF_W := 16.0     # inner faces of the side walls at x = +-16
const TR_BACK := 13.0       # inner face of the hall's back wall
const TR_END := -106.0      # inner face of the far wall
const TR_ROOF_FRONT := -1.0 # the hall's roof reaches out to here
const TR_ROOF_Y := 4.2
const TR_LANE_B := -2.75    # lane dividers: static | middle | dummies
const TR_LANE_C := 5.5


func _build_training() -> Node3D:
	print("Training:")
	# The yard's afternoon sky and grading, with much less haze (100 m lanes).
	var yard: Node = load("res://main.tscn").instantiate()
	var env: Environment = (yard.get_node("WorldEnvironment") as WorldEnvironment).environment.duplicate()
	var lm_ref: LightmapGI = yard.get_node("LightmapGI")
	var lm_color := lm_ref.environment_custom_color
	var lm_energy := lm_ref.environment_custom_energy
	yard.free()
	env.fog_density = 0.0022
	env.fog_sky_affect = 0.1

	var root := _new_map("training", "res://assets/music/town_empty_city.ogg", env, "res://training/training.gd")
	# Afternoon sun from behind the firing line, a little from the left.
	var sun := _sun(root, Vector3(-48.0, 25.0, 0.0), Color(1.0, 0.86, 0.68), 1.5)
	sun.light_cull_mask = 1048573  # as in the yard
	var level: Node3D = root.get_node("NavigationRegion3D/Level")
	var detail: Node3D = root.get_node("Detail")
	var lights: Node3D = root.get_node("Lights")
	var kit := Kit.new()
	var len_z := TR_BACK - TR_END
	var mid_z := (TR_BACK + TR_END) * 0.5

	# Floors: polished concrete in the hall, darker worn concrete downrange.
	var m_hall := _surface("res://materials/concrete_floor.tres", "training_hall_floor", {
		"tint": Color(0.92, 0.9, 0.86), "edge_dirt_start": 0.0, "macro_strength": 0.2})
	var m_range := _surface("res://materials/concrete_floor.tres", "training_range_floor", {
		"tint": Color(0.62, 0.6, 0.55), "edge_dirt_start": 0.0, "uv_scale": 0.2, "macro_strength": 0.35})
	_blocker(level, root, "Floor", Vector3(2 * TR_HALF_W + 2, 1, len_z + 2), Vector3(0, -0.5, mid_z))
	_lm_plane(detail, root, "HallFloor", Vector2(2 * TR_HALF_W, TR_BACK - TR_ROOF_FRONT),
			Vector3(0, 0, (TR_BACK + TR_ROOF_FRONT) * 0.5), m_hall)
	var seg := (TR_ROOF_FRONT - TR_END) / 3.0
	for i in 3:
		_lm_plane(detail, root, "RangeFloor%d" % i, Vector2(2 * TR_HALF_W, seg),
				Vector3(0, 0, TR_ROOF_FRONT - seg * (i + 0.5)), m_range)

	# Walls: brick all round (4 m), box colliders.
	var w := TR_HALF_W + 0.5
	for b in [["WallW", Vector3(1, 4, len_z + 2), Vector3(-w, 2, mid_z)],
			["WallE", Vector3(1, 4, len_z + 2), Vector3(w, 2, mid_z)],
			["WallBack", Vector3(2 * w + 1, 4, 1), Vector3(0, 2, TR_BACK + 0.5)],
			["WallEnd", Vector3(2 * w + 1, 4, 1), Vector3(0, 2, TR_END - 0.5)]]:
		_blocker(level, root, b[0], b[1], b[2])
	var zb := TR_BACK + 0.5
	var ze := TR_END - 0.5
	kit.wall_run(Vector3(-w, 0, zb), Vector3(-w, 0, ze), "wall_yard", "pillar_yard", [9, 21])
	kit.wall_run(Vector3(w, 0, ze), Vector3(w, 0, zb), "wall_yard", "pillar_yard", [14], Color.WHITE, false)
	kit.wall_run(Vector3(w, 0, zb), Vector3(-w, 0, zb), "wall_yard", "pillar_yard", [], Color.WHITE, false)
	kit.wall_run(Vector3(-w, 0, ze), Vector3(w, 0, ze), "wall_yard", "pillar_yard", [], Color.WHITE, false)

	# The hall's roof: corrugated sheets on a steel frame, posts on the lane
	# dividers. Its collider is outside the navmesh region.
	var roof_d := TR_BACK + 1.0 - TR_ROOF_FRONT
	var nx := 8
	var nz := 4
	for i in nx:
		for j in nz:
			var sx := (2 * w + 1) / nx
			var sz := roof_d / nz
			kit.add("roof_sheet", Transform3D(Basis.from_scale(Vector3(sx / 4.0, 1, sz / 4.0)),
					Vector3(-w - 0.5 + sx * (i + 0.5), TR_ROOF_Y, TR_ROOF_FRONT + sz * (j + 0.5))), Color(1.9, 1.9, 1.95))
	_blocker(root, root, "Roof", Vector3(2 * w + 1, 0.3, roof_d), Vector3(0, TR_ROOF_Y + 0.15, TR_ROOF_FRONT + roof_d * 0.5))
	var frame := _batch()
	var steel := Color(0.32, 0.33, 0.36)
	_batch_box(frame, Vector3(2 * w, 0.3, 0.3), _place(Vector3(0, TR_ROOF_Y - 0.15, TR_ROOF_FRONT + 0.2), 0.0), steel)
	_batch_box(frame, Vector3(2 * w, 0.25, 0.25), _place(Vector3(0, TR_ROOF_Y - 0.15, 6.0), 0.0), steel)
	for x in [TR_LANE_B, TR_LANE_C]:
		_batch_box(frame, Vector3(0.25, TR_ROOF_Y, 0.25), _place(Vector3(x, TR_ROOF_Y * 0.5, TR_ROOF_FRONT + 0.2), 0.0), steel)
		_blocker(level, root, "RoofPost%d" % int(x), Vector3(0.3, TR_ROOF_Y, 0.3), Vector3(x, TR_ROOF_Y * 0.5, TR_ROOF_FRONT + 0.2))
	for x in [-8.0, 0.0, 8.0]:
		_batch_box(frame, Vector3(0.18, 0.35, roof_d), _place(Vector3(x, TR_ROOF_Y - 0.2, TR_ROOF_FRONT + roof_d * 0.5), 0.0), steel)

	# Shooting benches on the firing line (static and middle lanes), with gaps
	# to walk downrange.
	var wood := Color(0.5, 0.36, 0.22)
	for bench in [[Vector2(-15.4, -3.4), "BenchA"], [Vector2(-1.9, 4.9), "BenchB"]]:
		var a: Vector2 = bench[0]
		var c := Vector3((a.x + a.y) * 0.5, 0, -0.75)
		var bl := a.y - a.x
		_batch_box(frame, Vector3(bl, 0.08, 0.7), _place(c + Vector3(0, 1.0, 0), 0.0), wood)
		_batch_box(frame, Vector3(bl, 0.9, 0.08), _place(c + Vector3(0, 0.5, -0.3), 0.0), wood.darkened(0.25))
		for x in [a.x + 0.2, a.y - 0.2]:
			_batch_box(frame, Vector3(0.08, 1.0, 0.6), _place(Vector3(x, 0.5, c.z), 0.0), steel)
		_blocker(level, root, bench[1], Vector3(bl, 1.05, 0.7), c + Vector3(0, 0.52, 0))

	# Lane lines on the floor, the firing line, and a stripe at each distance.
	var paint := Color(0.86, 0.84, 0.78)
	var yellow := Color(0.95, 0.75, 0.15)
	_batch_box(frame, Vector3(2 * TR_HALF_W, 0.01, 0.15), _place(Vector3(0, 0.006, -0.1), 0.0), yellow)
	for x in [TR_LANE_B, TR_LANE_C]:
		_batch_box(frame, Vector3(0.12, 0.01, -TR_END - 4.0), _place(Vector3(x, 0.006, (TR_END + 2.0) * 0.5 - 1.0), 0.0), paint)
	# Each distance's lane: thin lines between the lanes, a stripe across it
	# at the distance, and a sign high up behind its targets.
	var edges := [-TR_HALF_W, -13.5, -11.0, -8.0, TR_LANE_B]  # the 10 / 25 / 50 / 100 m lanes
	for i in range(1, edges.size() - 1):
		_batch_box(frame, Vector3(0.06, 0.01, -TR_END - 4.0), _place(Vector3(edges[i], 0.006, (TR_END + 2.0) * 0.5 - 1.0), 0.0), paint.darkened(0.3))
	for li in TR.DISTANCES.size():
		var d: int = TR.DISTANCES[li]
		var s: float = TR.TARGET_SCALE[d]
		var c: float = TR.LANES[d]
		_batch_box(frame, Vector3(edges[li + 1] - edges[li], 0.01, 0.12),
				_place(Vector3((edges[li] + edges[li + 1]) * 0.5, 0.006, -d), 0.0), paint)
		var at := Vector3(c + 0.2 * s, 0, -d - 1.2)
		var top := 0.6 + 0.95 * s + 0.5 * s
		var k := 1.0 + d / 30.0
		_batch_box(frame, Vector3(0.08, top, 0.08), _place(at + Vector3(0, top * 0.5, -0.05), 0.0), steel)
		_batch_box(frame, Vector3(1.1 * k, 0.55 * k, 0.05), _place(at + Vector3(0, top + 0.27 * k, 0), 0.0), Color(0.12, 0.25, 0.14))
		_sign_label(detail, root, "Dist%d" % d, "%d m" % d, at + Vector3(0, top + 0.27 * k, 0.03), 0.0045 * k)
	for m: Array in TR.MOVERS:
		var z := -float(m[0])
		_batch_box(frame, Vector3(m[1] * 2.0 + 1.0, 0.06, 0.2), _place(Vector3(TR.MOVER_X, 0.03, z), 0.0), steel)
		_sign_label(detail, root, "Mover%d" % int(m[0]), "%d m" % int(m[0]), Vector3(TR.MOVER_X, 2.3, z - 0.8), 0.0045)
	# The berm behind the far targets.
	_batch_box(frame, Vector3(2 * TR_HALF_W, 2.4, 2.5), _place(Vector3(0, 1.2, TR_END + 1.25), 0.0), Color(0.55, 0.45, 0.32))
	_blocker(level, root, "Berm", Vector3(2 * TR_HALF_W, 2.4, 2.5), Vector3(0, 1.2, TR_END + 1.25))
	# Lamp housings under the roof.
	var lamp_spots := [Vector3(-10.5, 0, 5.0), Vector3(0.0, 0, 5.0), Vector3(10.5, 0, 5.0), Vector3(-5.0, 0, 10.5), Vector3(5.0, 0, 10.5)]
	for p: Vector3 in lamp_spots:
		_batch_box(frame, Vector3(1.4, 0.12, 0.45), _place(p + Vector3(0, TR_ROOF_Y - 0.45, 0), 0.0), Color(0.25, 0.25, 0.27))
	_lm_batch_mesh(frame, detail, root, "RangeProps", "training_props")
	for i in lamp_spots.size():
		var p: Vector3 = lamp_spots[i]
		var tube := MeshInstance3D.new()
		var tm := BoxMesh.new()
		tm.size = Vector3(1.25, 0.05, 0.3)
		tm.material = m_glow
		tube.mesh = tm
		tube.position = p + Vector3(0, TR_ROOF_Y - 0.53, 0)
		tube.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_add(detail, tube, "LampTube%d" % i, root)
		var l := _omni(lights, root, "Lamp%d" % i, p + Vector3(0, TR_ROOF_Y - 0.8, 0), Color(1.0, 0.9, 0.75), 2.6, 10.0)
		l.light_bake_mode = Light3D.BAKE_STATIC  # in the lightmap only: free at run time

	# Cover: concrete walls between the lanes in front of the firing line, and
	# jersey barriers in front of the dummies.
	for x in [TR_LANE_B, TR_LANE_C]:
		var a := Vector3(x, 0, -2.5)
		kit.wall_run(a, a + Vector3(0, 0, -4.3), "wall_low_broken" if x > 0 else "wall_low", "pillar_low", [], Color.WHITE, true, 4.3)
		_blocker(level, root, "Cover%d" % int(x), Vector3(0.5, 2.8, 4.3), a + Vector3(0, 1.4, -2.15))
	for x in [7.8, 12.6]:
		var at := Vector3(x, 0, -6.5)
		kit.add("barrier", Transform3D(Basis(), at))
		_blocker(level, root, "Barrier%d" % int(x), Vector3(3.0, 1.0, 0.6), at + Vector3(0, 0.5, 0))
	# The back wall: lamps, a pipe and a sign over the range end.
	for x in [-9.0, 9.0]:
		kit.mount("lamp_wall", Vector3(x, 3.0, TR_BACK), Vector3.FORWARD)
	kit.mount("pipe_h", Vector3(0, 3.6, TR_BACK), Vector3.FORWARD, Color.WHITE, Vector3(30.0, 1, 1))
	kit.mount("sign_danger", Vector3(0, 3.0, TR_END), Vector3.BACK)
	kit.build(detail, root, "Kit", {"lightmap": true, "file_prefix": "training_kit"})

	# The weapon rack on the back wall, facing downrange.
	var rack := Node3D.new()
	rack.set_script(load("res://training/weapon_rack.gd"))
	_add(root, rack, "WeaponRack", root)
	rack.transform = Transform3D(Basis(Vector3.UP, PI), Vector3(0, 0, TR_BACK - 0.5))
	_blocker(level, root, "Rack", Vector3(12.4, 2.2, 0.5), Vector3(0, 1.1, TR_BACK - 0.3))

	# Targets.
	var holder := _add(root, Node3D.new(), "Targets", root)
	for d: int in TR.DISTANCES:
		var s: float = TR.TARGET_SCALE[d]
		_target(holder, root, "Paper%d" % d, "paper", Vector3(TR.paper_x(d), 0, -d), s)
		var mx: Array[float] = TR.metal_x(d)
		for i in mx.size():
			_target(holder, root, "Metal%d_%d" % [d, i], "metal", Vector3(mx[i], 0, -d), s)
	for m: Array in TR.MOVERS:
		_target(holder, root, "Mover%d" % int(m[0]), "paper", Vector3(TR.MOVER_X, 0, -float(m[0])), 1.0, m[1], m[2])
	for i in TR.POPUPS.size():
		var p: Vector2 = TR.POPUPS[i]
		_target(holder, root, "Popup%d" % i, "popup", Vector3(p.x, 0, p.y), 1.0)

	# Lightmap: small (the yard's custom sky colour; the Compatibility editor
	# bakes the HDRI sky black).
	var lm := LightmapGI.new()
	lm.texel_scale = 0.4
	lm.environment_mode = LightmapGI.ENVIRONMENT_MODE_CUSTOM_COLOR
	lm.environment_custom_color = lm_color
	lm.environment_custom_energy = lm_energy
	lm.quality = LightmapGI.BAKE_QUALITY_LOW
	_add(root, lm, "LightmapGI", root)
	root.move_child(lm, sun.get_index() + 1)
	var old := load("res://maps/training.tscn") if ResourceLoader.exists("res://maps/training.tscn") else null
	if old:
		# Keep the baked lightmap when the map is rebuilt (rebake.bat re-bakes it).
		var prev: Node = (old as PackedScene).instantiate()
		var prev_lm := prev.get_node_or_null("LightmapGI") as LightmapGI
		if prev_lm and prev_lm.light_data:
			lm.light_data = prev_lm.light_data
		prev.free()

	_finish_map(root, Vector3(0, 0, 5.0), 0.0, [Vector3(10.0, 0, -20.0)], [])
	return root


## A floor rectangle with lightmap UVs (visual only).
func _lm_plane(parent: Node, root: Node, n: String, size: Vector2, center: Vector3, mat: Material) -> void:
	var pm := PlaneMesh.new()
	pm.size = size
	pm.material = mat
	pm.add_uv2 = true
	var mi := MeshInstance3D.new()
	mi.mesh = pm
	mi.position = center
	mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add(parent, mi, n, root)


## A merged vertex-coloured mesh with lightmap UVs (no LODs), GI static.
func _lm_batch_mesh(b: Dictionary, parent: Node, root: Node, n: String, file: String, texel := 0.2) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = b.v
	arrays[Mesh.ARRAY_NORMAL] = b.n
	arrays[Mesh.ARRAY_COLOR] = b.c
	arrays[Mesh.ARRAY_INDEX] = b.i
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, m_vcolor)
	mesh.lightmap_unwrap(Transform3D(), texel)
	var path := GEN + file + ".res"
	ResourceSaver.save(mesh, path, ResourceSaver.FLAG_COMPRESS)
	var mi := MeshInstance3D.new()
	mi.mesh = load(path)
	mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	_add(parent, mi, n, root)
	print("  %s: %d tris" % [file, b.i.size() / 3])
	return mi


func _sign_label(parent: Node, root: Node, n: String, text: String, pos: Vector3, pixel: float) -> void:
	var l := Label3D.new()
	l.text = text
	l.font_size = 96
	l.outline_size = 12
	l.pixel_size = pixel
	l.modulate = Color(1, 1, 1)
	l.position = pos
	_add(parent, l, n, root)


func _target(parent: Node, root: Node, n: String, kind: String, pos: Vector3, size: float,
		move_half := 0.0, move_speed := 0.0) -> void:
	var t := StaticBody3D.new()
	t.set_script(load("res://training/target.gd"))
	t.set("kind", kind)
	t.set("size", size)
	t.set("move_half", move_half)
	t.set("move_speed", move_speed)
	t.position = pos
	t.add_to_group("training_targets", true)
	_add(parent, t, n, root)


# --- Saving ----------------------------------------------------------------------

## Saves the map, bakes its navmesh from the collision boxes under
## NavigationRegion3D, then saves the map again with the navmesh in it.
func _save_map(map_root: Node3D, id: String) -> void:
	var scene_path := "res://maps/%s.tscn" % id
	var nav_path := "res://maps/%s_navmesh.res" % id
	# Meshes without lightmap UVs can't be baked: the probes light them instead.
	for mi: MeshInstance3D in map_root.find_children("*", "MeshInstance3D", true, true):
		if mi.owner == map_root and mi.gi_mode == GeometryInstance3D.GI_MODE_STATIC and mi.mesh \
				and mi.mesh.get_surface_count() > 0 \
				and mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2] == null:
			mi.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
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
	for p in ["cell_size", "cell_height", "agent_radius", "agent_height", "agent_max_slope",
			"geometry_parsed_geometry_type", "geometry_collision_mask", "region_min_size", "edge_max_error",
			"filter_walkable_low_height_spans", "filter_ledge_spans", "filter_low_hanging_obstacles"]:
		nm.set(p, yard.get(p))
	nm.agent_max_climb = 0.0  # flat maps (the yard has a climb for its stairs)
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


## The baked lighting of the town and warehouse: sky light as a colour (the
## Compatibility editor bakes an HDRI sky black), 6 bounces, soft shadows,
## the denoiser. Direct light of real-time lamps stays real-time; only their
## bounce light is in the lightmap. Extra lamps are BAKE_STATIC (baked fully).
## tools/rebake.bat bakes it into maps/<id>.lmbake / .exr.
func _add_lightmap(root: Node3D, sun: Node, color: Color, energy: float) -> void:
	var lm := LightmapGI.new()
	lm.quality = LightmapGI.BAKE_QUALITY_HIGH
	lm.bounces = 6
	lm.bounce_indirect_energy = 1.25
	lm.use_denoiser = true
	lm.denoiser_strength = 0.12
	lm.texel_scale = 0.4
	lm.max_texture_size = 2048
	lm.environment_mode = LightmapGI.ENVIRONMENT_MODE_CUSTOM_COLOR
	lm.environment_custom_color = color
	lm.environment_custom_energy = energy
	_add(root, lm, "LightmapGI", root)
	root.move_child(lm, sun.get_index() + 1)
