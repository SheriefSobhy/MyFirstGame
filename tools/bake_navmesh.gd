extends SceneTree
## Bakes every map's navmeshes from the collision shapes under its
## NavigationRegion3D (walls, buildings, containers, cars, shelves, crates,
## pallets...): one per enemy size in enemy_types.gd NAV_MESHES, saved as
## <map navmesh><suffix>.res. The first (no suffix) is the map scene's own
## region; main.gd adds a region for each of the others when the map loads.
## Run after changing a map (tools/rebake.bat and build_maps.gd do):
##   godot --headless --path . --script res://tools/bake_navmesh.gd

const Types := preload("res://enemy_types.gd")
const MAPS := ["res://main.tscn", "res://maps/town.tscn", "res://maps/warehouse.tscn", "res://maps/training.tscn"]

## Must match navigation/3d/default_cell_size and default_cell_height in
## project.godot. Fine cells so each agent radius is kept closely (Recast
## rounds radius and height up to whole cells).
const CELL_SIZE := 0.125
const CELL_HEIGHT := 0.1      # 0.25 lost the 0.3-0.46 m crates, jerrycans and tyres

var done := false


func _process(_delta: float) -> bool:
	if done:
		return true
	done = true
	for path: String in MAPS:
		_bake_map(path)
	print("BAKE_NAVMESH: done")
	quit()
	return true


func _bake_map(scene_path: String) -> void:
	print("== ", scene_path)
	# Bake in a copy of only the navigation region, inside the tree (so the
	# game itself doesn't start). The player start tells which part of the
	# navmesh is the real, walkable level.
	var copy: Node = load(scene_path).instantiate()
	var start: Vector3 = (copy.get_node("Player") as Node3D).position
	var region: NavigationRegion3D = copy.get_node("NavigationRegion3D")
	copy.remove_child(region)
	copy.free()
	root.add_child(region)

	var base: NavigationMesh = region.navigation_mesh
	var base_path := base.resource_path
	for m: Dictionary in Types.NAV_MESHES:
		# The first is re-baked into the scene's own resource (keeps its uid).
		var nm := base if m.suffix == "" else NavigationMesh.new()
		_bake(region, nm, m.radius, m.height, start, base_path.get_basename() + m.suffix + ".res")
	region.free()


func _bake(region: NavigationRegion3D, nm: NavigationMesh, radius: float, height: float,
		start: Vector3, path: String) -> void:
	_configure(nm, radius, height)
	region.navigation_mesh = nm
	region.bake_navigation_mesh(false)
	var before := nm.get_polygon_count()
	_keep_connected(nm, [start])
	var err := ResourceSaver.save(nm, path)
	print("  r %.3f, h %.2f: %d polygons (%d unreachable removed) -> %s %s" % [radius, height,
			nm.get_polygon_count(), before - nm.get_polygon_count(), path, error_string(err)])


func _configure(nm: NavigationMesh, radius: float, height: float) -> void:
	nm.clear()
	nm.cell_size = CELL_SIZE
	nm.cell_height = CELL_HEIGHT
	nm.agent_radius = radius
	nm.agent_height = height
	# No steps: the floors are flat, and even a pallet (0.14 m, 1 cell over the
	# floor) stops the smaller enemies, so it must be an obstacle too.
	nm.agent_max_climb = 0.0
	nm.agent_max_slope = 30.0
	# Every static collider under the region, on any layer.
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nm.geometry_collision_mask = 0xFFFFFFFF
	nm.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	# Godot leaves these off. Without them the floor under a low crate, tyre or
	# jerrycan (lower than an enemy, higher than a step) stays walkable, so
	# paths went straight through them, and the tops of crates and containers
	# became walkable too.
	nm.filter_walkable_low_height_spans = true
	nm.filter_ledge_spans = true
	nm.filter_low_hanging_obstacles = true
	nm.region_min_size = 2.0
	nm.edge_max_error = 1.3


## Collision boxes are hollow to the baker, so the inside of a building or
## container comes out as a walkable island nobody can reach, and corners too
## tight for big enemies become dead ends cut off from the rest. Keeps only
## the parts of the navmesh connected to a seed (the player start).
func _keep_connected(nm: NavigationMesh, seeds: Array[Vector3]) -> void:
	var verts := nm.get_vertices()
	var polys: Array[PackedInt32Array] = []
	for i in nm.get_polygon_count():
		polys.append(nm.get_polygon(i))
	# Union-find over vertices: polygons sharing a vertex are connected.
	var parent := PackedInt32Array()
	parent.resize(verts.size())
	for i in verts.size():
		parent[i] = i
	for poly in polys:
		for k in range(1, poly.size()):
			_union(parent, poly[0], poly[k])
	var keep := {}
	for s in seeds:
		var best := -1
		var best_d := INF
		for i in polys.size():
			var c := Vector3.ZERO
			for idx in polys[i]:
				c += verts[idx]
			c /= polys[i].size()
			if absf(c.y - s.y) > 1.5:
				continue
			var d := 0.0 if _contains_xz(verts, polys[i], s) else Vector2(c.x - s.x, c.z - s.z).length()
			if d < best_d:
				best_d = d
				best = i
		if best >= 0 and best_d < 4.0:
			keep[_find(parent, polys[best][0])] = true
	if keep.is_empty():
		push_warning("no navmesh near the player start or spawn points: kept everything")
		return
	# Rebuild with only the kept polygons (and their vertices).
	var remap := {}
	var new_verts := PackedVector3Array()
	var new_polys: Array[PackedInt32Array] = []
	for poly in polys:
		if not keep.has(_find(parent, poly[0])):
			continue
		var np := PackedInt32Array()
		for idx in poly:
			if not remap.has(idx):
				remap[idx] = new_verts.size()
				new_verts.append(verts[idx])
			np.append(remap[idx])
		new_polys.append(np)
	nm.clear_polygons()
	nm.vertices = new_verts
	for np in new_polys:
		nm.add_polygon(np)


func _find(parent: PackedInt32Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i


func _union(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[ra] = rb


func _contains_xz(verts: PackedVector3Array, poly: PackedInt32Array, p: Vector3) -> bool:
	var inside := false
	var n := poly.size()
	for i in n:
		var a := verts[poly[i]]
		var b := verts[poly[(i + 1) % n]]
		if (a.z > p.z) != (b.z > p.z) and p.x < (b.x - a.x) * (p.z - a.z) / (b.z - a.z) + a.x:
			inside = not inside
	return inside
