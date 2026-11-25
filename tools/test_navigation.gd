extends SceneTree
## Enemy navigation stress test on all three maps:
##   godot --headless --path . --fixed-fps 60 --script res://tools/test_navigation.gd
## (--fixed-fps 60 runs the game as fast as the computer can, 60 steps per
## game second.) Add `-- --quick` for 15 s per run instead of 60, and
## `--only <map id>`, `--pos <n>` or `--only <map id> --at <x>,<z>` to run
## just one map / position.
##
## Static checks per map: every navmesh (small enemies, Brute, Boss) is there
## and fits its types, every obstacle (crate, pallet, car, shelf, container,
## building...) is cut out of all of them, and enemies only spawn where they
## can walk out. Then, from several player positions, it keeps
## MAX_ALIVE enemies of every type coming for RUN_TIME seconds. An enemy
## "arrives" when it starts a punch, arms (exploder) or aims (soldier, which
## also needs a clear view); it is then removed and the next one spawns.
## An enemy counts as STUCK if, while walking, it barely moved for
## STUCK_SECONDS (away from the player), if its own stuck recovery kicked in,
## or if it didn't arrive in time. If the player stands somewhere too tight
## for its size, it must wait where its path ends instead ("waited").
## Exits with code 1 if anything failed.

const Maps := preload("res://maps.gd")
const Types := preload("res://enemy_types.gd")

const KINDS := ["normal", "runner", "brute", "boss", "soldier", "exploder"]
const RUN_TIME := 60.0
const MAX_ALIVE := 8
const SPAWN_EVERY := 0.6
const STUCK_SECONDS := 2.0
const STILL_DISTANCE := 0.3      # moved less than this = standing still
const EXTRA_POSITIONS := 3       # random player positions besides the map's start...
const CORNER_POSITIONS := 2      # ...and the corners furthest from it (worst for crowds)
const POSITION_SPACING := 8.0

var failures := 0
var run_time := RUN_TIME
var totals := {"spawned": 0, "arrived": 0, "stuck": 0}


var only_map := ""
var only_pos := -1
var at := []   # --at x,z (with --only): run from that one spot instead
var trace := false  # --trace: print every enemy every 5 s


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if "--quick" in args:
		run_time = 15.0
	var i := args.find("--only")
	if i >= 0 and i + 1 < args.size():
		only_map = args[i + 1]
	i = args.find("--pos")
	if i >= 0 and i + 1 < args.size():
		only_pos = int(args[i + 1])
	trace = "--trace" in args
	i = args.find("--at")
	if i >= 0 and i + 1 < args.size():
		at = Array(args[i + 1].split(",")).map(func(t: String) -> float: return float(t))
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		failures += 1


func frames(n: int) -> void:
	for i in n:
		await physics_frame
		await process_frame  # scene changes finish at the end of a process frame


# Until the navigation map has synced with every region of the map (the
# small enemies', the Brute's and the Boss's), so path queries see them all.
# Checking too early made every path come back empty now and then.
func _wait_for_navmesh(main: Node) -> void:
	for i in 600:
		if main.navmesh_ready():  # synced since this scene loaded, every region on it
			return
		await physics_frame
	check(false, "%s: the navigation map syncs within 600 frames" % main.map_id)


func _run() -> void:
	for m: Dictionary in Maps.LIST:
		if only_map == "" or only_map == m.id:
			await _test_map(m)
	print("\nTotal: %d enemies spawned, %d arrived, %d stuck" % [totals.spawned, totals.arrived, totals.stuck])
	check(totals.stuck == 0, "no enemy got stuck on any map")
	print("\n%s: %d failure(s)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _test_map(m: Dictionary) -> void:
	print("\n--- ", m.name)
	change_scene_to_file(m.scene)
	await frames(20)
	var main := current_scene
	main.get_node("SpawnTimer").stop()
	main.phase = main.Phase.OVER  # no wave logic: this test spawns the enemies
	_clear_enemies(main)
	await _wait_for_navmesh(main)
	var player: CharacterBody3D = main.get_node("Player")
	var regions: Array[NavigationRegion3D] = []
	for nav: Dictionary in Types.NAV_MESHES:
		var region: NavigationRegion3D = main.nav_region(nav.layer)
		var nm: NavigationMesh = region.navigation_mesh if region else null
		check(nm != null and nm.get_polygon_count() > 50 and region.navigation_layers == nav.layer
				and is_equal_approx(nm.agent_radius, nav.radius) and is_equal_approx(nm.agent_height, nav.height),
				"%s: navmesh%s on layer %d, r %.3f h %.2f (%d polygons)" % [m.name, nav.suffix, nav.layer,
				nm.agent_radius if nm else 0.0, nm.agent_height if nm else 0.0, nm.get_polygon_count() if nm else 0])
		if region == null:
			return
		regions.append(region)
	# Every type has a navmesh it fits on.
	for k: String in Types.TYPES:
		var nav: Dictionary = Types.nav_mesh_for(k)
		check(nav.radius >= Types.TYPES[k].radius and nav.height >= Types.TYPES[k].height,
				"%s: %s (r %.2f, h %.2f) walks on navmesh%s (r %.3f, h %.2f)" % [m.name, k, Types.TYPES[k].radius,
				Types.TYPES[k].height, nav.suffix, nav.radius, nav.height])
	_check_obstacles(m.name, regions)
	_check_spawns(m.name, main)

	var positions := _player_positions(main, regions)
	if at.size() == 2:
		positions = [Vector3(at[0], 0.0, at[1])] as Array[Vector3]
	for i in positions.size():
		if only_pos < 0 or only_pos == i:
			seed(hash(m.id) + i)  # each run is the same with or without --only/--pos
			await _run_from(main, player, positions[i], i)


func _region_name(region: NavigationRegion3D) -> String:
	return str(region.name).trim_prefix("NavigationRegion").to_lower()


# Every obstacle standing on the ground must be cut out of every navmesh:
# the navmesh closest to its middle (at floor height) must not be right there.
func _check_obstacles(tag: String, regions: Array[NavigationRegion3D]) -> void:
	var covered: Array[String] = []
	var count := 0
	for body: StaticBody3D in regions[0].find_children("*", "StaticBody3D", true, false):
		for cs: CollisionShape3D in body.find_children("*", "CollisionShape3D", false, false):
			if cs.shape == null or cs.disabled:
				continue
			var box := _shape_aabb(cs)
			if box.size.y < 0.1 or box.position.y > 0.1 or box.end.y < 0.1:
				continue  # floors, roofs and beams
			count += 1
			var mid := box.get_center()
			mid.y = 0.1
			for region in regions:
				var p := NavigationServer3D.region_get_closest_point(region.get_rid(), mid)
				if p.y < 0.6 and Vector2(p.x - mid.x, p.z - mid.z).length() < 0.05:
					covered.append("%s (%s)" % [regions[0].get_path_to(body), _region_name(region)])
	check(covered.is_empty(), "%s: all %d obstacles (incl. pallets, crates, tyres) are cut out of every navmesh %s" % [
			tag, count, covered])


func _shape_aabb(cs: CollisionShape3D) -> AABB:
	var local: AABB
	if cs.shape is BoxShape3D:
		var s: Vector3 = cs.shape.size
		local = AABB(-s * 0.5, s)
	elif cs.shape is CylinderShape3D:
		var c: CylinderShape3D = cs.shape
		local = AABB(Vector3(-c.radius, -c.height * 0.5, -c.radius), Vector3(c.radius * 2.0, c.height, c.radius * 2.0))
	else:
		local = cs.shape.get_debug_mesh().get_aabb()
	return cs.global_transform * local


# Every spawn point connects to the player start for the small enemies. Some
# are in corners too tight for the Brute or the Boss: main.gd must not spawn
# those there, and must still have a few spawn points for them.
func _check_spawns(tag: String, main: Node) -> void:
	var map: RID = main.get_world_3d().navigation_map
	var start: Vector3 = (main.get_node("Player") as Node3D).global_position
	for nav: Dictionary in Types.NAV_MESHES:
		var cut: Array[String] = []
		for s: Node3D in main.get_node("SpawnPoints").get_children():
			var path := NavigationServer3D.map_get_path(map, s.global_position, start, true, nav.layer)
			if path.is_empty() or _flat(path[path.size() - 1], start) > 1.0 \
					or _flat(path[0], s.global_position) > main.SPAWN_SPREAD + 0.5:
				cut.append(s.name)
		var used: Array = main._spawn_points_for(nav.layer).map(func(s: Node) -> String: return s.name)
		if nav.layer == Types.NAV_SMALL:
			check(cut.is_empty(), "%s: every spawn point is on the navmesh and connects to the player start %s" % [tag, cut])
		else:
			var wrong := cut.filter(func(n: String) -> bool: return n in used)
			check(wrong.is_empty() and used.size() >= 3, "%s: navmesh%s enemies spawn at the %d points they can walk out of (not %s)" % [
					tag, nav.suffix, used.size(), cut])


# The player's start, a few spread-out random points on every navmesh (every
# type can reach them), and the corners of the map furthest from the start
# (on the small navmesh: the Brute and the Boss may not fit there, and must
# then wait at the end of their path rather than squeeze in).
func _player_positions(main: Node, regions: Array[NavigationRegion3D]) -> Array[Vector3]:
	var player: Node3D = main.get_node("Player")
	var out: Array[Vector3] = [player.global_position]
	var small := regions[0]
	var area := AABB(small.navigation_mesh.get_vertices()[0], Vector3.ZERO)
	for v in small.navigation_mesh.get_vertices():
		area = area.expand(v)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(main.map_id)
	var tries := 0
	while out.size() < 1 + EXTRA_POSITIONS and tries < 2000:
		tries += 1
		var want := Vector3(rng.randf_range(area.position.x, area.end.x), 0.0, rng.randf_range(area.position.z, area.end.z))
		var p := NavigationServer3D.region_get_closest_point(regions[-1].get_rid(), want)
		if p.y > 0.5 or _flat(p, want) > 0.05:
			continue
		if regions.any(func(r: NavigationRegion3D) -> bool:
				return NavigationServer3D.region_get_closest_point(r.get_rid(), p).distance_to(p) > 0.1):
			continue
		if out.any(func(o: Vector3) -> bool: return o.distance_to(p) < POSITION_SPACING):
			continue
		out.append(p)
	var corners: Array[Vector3] = []
	for c in [Vector3(area.position.x, 0, area.position.z), Vector3(area.end.x, 0, area.position.z),
			Vector3(area.position.x, 0, area.end.z), Vector3(area.end.x, 0, area.end.z)]:
		var p := NavigationServer3D.region_get_closest_point(small.get_rid(), c)
		if p.y < 0.5:
			corners.append(p)
	corners.sort_custom(func(a: Vector3, b: Vector3) -> bool:
		return a.distance_to(out[0]) > b.distance_to(out[0]))
	out.append_array(corners.slice(0, CORNER_POSITIONS))
	return out


func _clear_enemies(main: Node) -> void:
	for e in main.get_node("Enemies").get_children():
		e.free()


func _run_from(main: Node, player: CharacterBody3D, pos: Vector3, index: int) -> void:
	_clear_enemies(main)
	main.wave = 1 + index * 3  # later runs: faster enemies (main.speed_in_wave)
	player.global_position = pos
	player.velocity = Vector3.ZERO
	await frames(5)
	var dt := 1.0 / Engine.physics_ticks_per_second
	var t := 0.0
	var next_spawn := 0.0
	var kind_i := index  # each run starts with a different type
	var tracked := {}    # enemy -> info
	var by_kind := {}
	for k in KINDS:
		by_kind[k] = {"spawned": 0, "arrived": 0, "stuck": 0, "waited": 0}
	var stuck_list: Array[String] = []
	var enemies: Node = main.get_node("Enemies")

	while t < run_time:
		await physics_frame
		t += dt
		if trace and fmod(t, 5.0) < dt:
			print("    t=%.0f" % t)
			for e: Node3D in tracked.keys():
				if is_instance_valid(e):
					print("      %s %s state %d still %.1f %s" % [e.kind, _v(e.global_position), e.state,
							tracked[e].still, _why(e, enemies)])
		player.global_position = pos  # the player stands still (and can't die)
		player.velocity = Vector3.ZERO
		player.health = 1000000
		if t >= next_spawn and enemies.get_child_count() < MAX_ALIVE:
			next_spawn = t + SPAWN_EVERY
			var kind: String = KINDS[kind_i % KINDS.size()]
			kind_i += 1
			main._spawn_queue = [kind] as Array[String]
			main.spawn_enemy()
			var e: Node3D = enemies.get_child(enemies.get_child_count() - 1)
			var plan := _plan(main, e, pos)
			tracked[e] = {"kind": kind, "born": t, "anchor": e.global_position, "still": 0.0,
					"stuck": "", "timeout": plan.time, "reaches": plan.reaches, "end": plan.end}
			by_kind[kind].spawned += 1
		for e: Node3D in tracked.keys():
			var info: Dictionary = tracked[e]
			if not is_instance_valid(e):
				tracked.erase(e)
				continue
			if e.state in [e.State.ATTACK, e.State.ARMED, e.State.AIM]:
				by_kind[info.kind].arrived += 1
				_finish(e, info, by_kind, stuck_list, t)
				tracked.erase(e)
				continue
			# Our own stuck check (doesn't trust the enemy's).
			var near: bool = e._player_in_range(e.stats.attack_range + e.NEAR_PLAYER)
			if e.is_trying_to_move() and e.state == e.State.CHASE and not near:
				if _flat(e.global_position, info.anchor) < STILL_DISTANCE:
					info.still += dt
					if info.still >= STUCK_SECONDS and info.stuck == "":
						info.stuck = "no progress for %.0fs at %s, %s" % [STUCK_SECONDS, _v(e.global_position), _why(e, enemies)]
				else:
					info.anchor = e.global_position
					info.still = 0.0
			else:
				info.anchor = e.global_position
				info.still = 0.0
			if e.stuck_level >= 1 and info.stuck == "":
				info.stuck = "its own stuck check fired at %s, %s" % [_v(e.global_position), _why(e, enemies)]
			if not info.reaches and _flat(e.global_position, info.end) < 3.0 and not e.is_trying_to_move():
				info.born = t  # waiting where its path ends (the player is somewhere too tight)
				if not info.has("waited"):
					info.waited = true
					by_kind[info.kind].waited += 1
			if t - info.born > info.timeout and info.stuck == "":
				info.stuck = "didn't arrive in %.0fs (at %s, %.1f m from the player)" % [info.timeout,
						_v(e.global_position), _flat(e.global_position, pos)]
	for e: Node3D in tracked.keys():
		if is_instance_valid(e):
			_finish(e, tracked[e], by_kind, stuck_list, t)

	var spawned := 0
	var arrived := 0
	var parts: Array[String] = []
	for k: String in KINDS:
		var s: Dictionary = by_kind[k]
		spawned += s.spawned
		arrived += s.arrived
		parts.append("%s %d/%d%s%s" % [k, s.arrived, s.spawned, (" waited %d" % s.waited) if s.waited > 0 else "",
				(" STUCK %d" % s.stuck) if s.stuck > 0 else ""])
	totals.spawned += spawned
	totals.arrived += arrived
	totals.stuck += stuck_list.size()
	print("  player at %s (speed x%.2f): %d spawned, %d arrived, %d stuck   [%s]" % [_v(pos),
			main.speed_in_wave(main.wave), spawned, arrived, stuck_list.size(), ", ".join(parts)])
	for s in stuck_list:
		print("      ", s)
	check(stuck_list.is_empty() and arrived > 0, "%s from %s: no enemy stuck" % [main.map_id, _v(pos)])
	_clear_enemies(main)


# Its path to the player: how long it may take to arrive (the path length at
# its speed, doubled, plus time to get round the crowd), whether the path
# reaches the player (close enough to attack) and where it ends.
func _plan(main: Node, e: Node3D, target: Vector3) -> Dictionary:
	var map: RID = main.get_world_3d().navigation_map
	var path := NavigationServer3D.map_get_path(map, e.global_position, target, true, Types.nav_layer(e.kind))
	var length := 0.0
	for k in range(1, path.size()):
		length += path[k - 1].distance_to(path[k])
	var end: Vector3 = path[path.size() - 1] if not path.is_empty() else e.global_position
	return {"time": length / (e.stats.speed * e.speed_scale) * 2.0 + 12.0, "end": end,
			"reaches": _flat(end, target) <= maxf(e.stats.attack_range, 1.0)}


func _finish(e: Node3D, info: Dictionary, by_kind: Dictionary, stuck_list: Array[String], _t: float) -> void:
	var counts: Array = e.stuck_counts
	var reason: String = info.stuck
	if reason == "" and (counts[1] > 0 or counts[2] > 0 or counts[3] > 0):
		reason = "its own stuck check fired (re-path %d, sidestep %d, respawn %d)" % [counts[1], counts[2], counts[3]]
	if reason != "":
		by_kind[info.kind].stuck += 1
		stuck_list.append("%s: %s" % [info.kind, reason])
	e.queue_free()


# What the enemy was doing, to help find the cause.
func _why(e: Node3D, enemies: Node) -> String:
	var agent: NavigationAgent3D = e.agent
	var next := agent.get_next_path_position()
	var close: Array[String] = []
	for o: Node3D in enemies.get_children():
		if o != e and _flat(o.global_position, e.global_position) < e.stats.radius + o.stats.radius + 0.3:
			close.append(o.kind)
	var space: PhysicsDirectSpaceState3D = e.get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = e.collision.shape
	q.transform = e.collision.global_transform
	q.collision_mask = 2 | 1
	q.exclude = [e.get_rid()]
	var hits: Array[String] = []
	for h in space.intersect_shape(q, 4):
		hits.append(str(h.collider.name))
	var slides: Array[String] = []
	for i in e.get_slide_collision_count():
		var c: KinematicCollision3D = e.get_slide_collision(i)
		slides.append("%s n%s" % [c.get_collider().name if c.get_collider() else "?", _v(c.get_normal())])
	return "y %.2f floor %s, next %s (%.1f m), finished %s, vel %s, safe %s, touching %s, overlaps %s, slides %s" % [
			e.global_position.y, e.is_on_floor(), _v(next),
			_flat(next, e.global_position), agent.is_navigation_finished(),
			_v(e.velocity), _v(e._safe_velocity), close, hits, slides]


func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _v(p: Vector3) -> String:
	return "(%.1f, %.1f)" % [p.x, p.z]
