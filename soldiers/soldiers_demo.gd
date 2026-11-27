extends Node
## Debug builds only: a recorded demo of the Combat mode on a phone.
## If user://soldiers_demo exists, the main menu goes straight into Combat on
## the map named in it (yard / town / warehouse; empty = yard) and this node
## (added by soldiers_mode.gd) plays it: walks between spots (fixed ones in
## the Yard, random navmesh points round the start elsewhere), turns to the
## nearest soldier it can see and fires. It never dies (heals itself when
## low). After DURATION s it writes user://soldiers_demo.txt (FPS, frame
## times, soldiers) and quits. The flag is deleted at the start, so the next
## launch is normal.
##   adb shell "run-as <package> sh -c 'echo town > files/soldiers_demo'"
##   adb shell screenrecord --time-limit 60 /sdcard/soldiers_test.mp4

const FLAG := "user://soldiers_demo"
const REPORT := "user://soldiers_demo.txt"
const DURATION := 75.0
const RIFLE := 1   # weapon_stats.gd LIST: the Assault Rifle
const WAYPOINTS := [Vector3(0, 0, 8), Vector3(6, 0, 7), Vector3(9, 0, 1), Vector3(1, 0, -0.5),
		Vector3(-2.5, 0, 6.5), Vector3(-9.5, 0, 8.5), Vector3(-9, 0, -1), Vector3(-1, 0, 9)]

var _main: Node
var _player: Node
var _t := 0.0
var _times := PackedFloat32Array()
var _max_alive := 0
var _target: Node3D
var _pick_timer := 0.0
var _waypoint := 0
var _leg_time := 0.0
var _hold := 0.0


var _waypoints: Array = []


static func requested() -> bool:
	return OS.is_debug_build() and FileAccess.file_exists(FLAG)


## The map id written in the flag file ("yard" if none).
static func requested_map() -> String:
	var id := FileAccess.get_file_as_string(FLAG).strip_edges() if FileAccess.file_exists(FLAG) else ""
	return id if id in ["yard", "town", "warehouse"] else "yard"


func _ready() -> void:
	DirAccess.remove_absolute(FLAG)
	_main = get_parent()
	if _main.base_map_id == "yard":
		_waypoints = WAYPOINTS.duplicate()
	_player = _main.player
	_player.give_weapon(RIFLE)
	_player.switch_to(RIFLE)
	_player.set_infinite_ammo(true)


func _process(delta: float) -> void:
	_times.append(delta * 1000.0)
	_max_alive = maxi(_max_alive, _main.enemies.get_child_count())


func _physics_process(delta: float) -> void:
	_t += delta
	if _t >= DURATION:
		_finish()
		return
	if _player.is_dead:
		return
	if _player.health < 30:
		_player.heal(40)
	_pick_timer -= delta
	if _pick_timer <= 0.0:
		_pick_timer = 0.2
		_target = _pick_target()
	var cam: Camera3D = _player.camera
	if _target and is_instance_valid(_target) and _target.state != _target.State.DEAD:
		var aim := _target.global_position + Vector3.UP * 1.25
		_player._turn_towards(aim, 0.14)
		var off := (-cam.global_basis.z).angle_to((aim - cam.global_position).normalized())
		_player.touch_shoot = off < deg_to_rad(2.5)
	else:
		_player.touch_shoot = false
		var near := _nearest_soldier(false)
		if near:
			_player._turn_towards(near.global_position + Vector3.UP * 1.25, 0.04)
	_move(delta)


# Walks from waypoint to waypoint; stands still now and then while shooting.
func _move(delta: float) -> void:
	_leg_time += delta
	if _waypoints.is_empty():
		_make_waypoints()
		if _waypoints.is_empty():
			return
	var wp: Vector3 = _waypoints[_waypoint]
	var to: Vector3 = wp - _player.global_position
	to.y = 0.0
	if to.length() < 1.0 or _leg_time > 9.0:
		_waypoint = (_waypoint + 1) % _waypoints.size()
		_leg_time = 0.0
		_hold = randf_range(0.5, 2.0)
	if _hold > 0.0 and _player.touch_shoot:
		_hold -= delta
		_player.touch_move = Vector2.ZERO
		return
	var local: Vector3 = _player.global_basis.inverse() * to
	_player.touch_move = Vector2(local.x, local.z).normalized() * 0.85


# 8 random navmesh points within 12 m of the player start (once the navmesh is ready).
func _make_waypoints() -> void:
	if not _main.navmesh_ready():
		return
	var region: NavigationRegion3D = _main.nav_region(1)
	if region == null:
		return
	var start: Vector3 = _main._player_start
	for i in 200:
		var p := NavigationServer3D.region_get_random_point(region.get_rid(), 1, true)
		if Vector2(p.x - start.x, p.z - start.z).length() < 12.0:
			_waypoints.append(p)
			if _waypoints.size() >= 8:
				break


func _pick_target() -> Node3D:
	return _nearest_soldier(true)


func _nearest_soldier(visible_only: bool) -> Node3D:
	var cam: Camera3D = _player.camera
	var best: Node3D = null
	var best_d := INF
	for e: Node3D in get_tree().get_nodes_in_group("enemies"):
		var d := e.global_position.distance_to(_player.global_position)
		if d >= best_d:
			continue
		if visible_only:
			var q := PhysicsRayQueryParameters3D.create(cam.global_position, e.global_position + Vector3.UP * 1.25, 3, [_player.get_rid()])
			var hit: Dictionary = _player.get_world_3d().direct_space_state.intersect_ray(q)
			if not hit.is_empty() and hit.collider != e:
				continue
		best = e
		best_d = d
	return best


func _finish() -> void:
	set_physics_process(false)
	_player.touch_shoot = false
	_player.touch_move = Vector2.ZERO
	var sorted := _times.duplicate()
	sorted.sort()
	var total := 0.0
	for t in _times:
		total += t
	var n := maxi(_times.size(), 1)
	var lines := PackedStringArray([
		"map %s, model %s, quality %s, screen %s" % [_main.base_map_id, OS.get_model_name(), Settings.QUALITY_NAMES[Settings.effective_quality()], DisplayServer.window_get_size()],
		"%.0f s, %d frames, avg %.1f fps" % [_t, _times.size(), 1000.0 * n / maxf(total, 1.0)],
		"frame ms: median %.1f, 95%% %.1f, 99%% %.1f, max %.1f" % [sorted[n / 2], sorted[n * 95 / 100], sorted[n * 99 / 100], sorted[n - 1]],
		"wave %d, kills %d, most enemies at once %d" % [_main.wave, _main.kills, _max_alive],
	])
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(lines) + "\n")
		f.close()
	print("\n".join(lines))
	get_tree().quit()
