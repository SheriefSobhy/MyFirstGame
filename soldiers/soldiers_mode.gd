extends "res://main.gd"
## Soldiers (Test) mode (main menu > Soldiers (Test)): the Industrial Yard
## (maps/soldiers.tscn is main.tscn with this script) against soldiers only,
## who fight from cover (tactical_soldier.gd). The zombie mode (main.gd) is
## unchanged; this only replaces what differs:
##  - waves: START_SOLDIERS, +SOLDIERS_PER_WAVE each wave, MAX_ALIVE at once
##  - cover points round the Yard's tall objects (get_cover_points)
##  - the player: a red damage direction indicator (damage_indicator.gd) and
##    health regen after REGEN_DELAY s without damage
## Cash, the shop, XP, missions and achievements count as normal. Best score
## and best wave are saved under "soldiers", not the Yard's.
## Balance numbers: soldiers_config.gd.

const Cfg := preload("res://soldiers/soldiers_config.gd")
const SOLDIER_SCENE := preload("res://soldiers/tactical_soldier.tscn")
const TacticalSoldier := preload("res://soldiers/tactical_soldier.gd")
const DamageIndicator := preload("res://soldiers/damage_indicator.gd")
const SoldiersDemo := preload("res://soldiers/soldiers_demo.gd")
const MODE_ID := "soldiers"

## Cover spots: {pos, peek, normal (away from the object), object, owner
## (the soldier using it, or null)}. Built once the navmesh is ready.
var cover_points: Array[Dictionary] = []
var indicator: DamageIndicator
var _since_hit := 0.0
var _regen_left := 0.0
var _last_health := 0


func _ready() -> void:
	if SoldiersDemo.requested():
		Settings.tutorial_done = true  # the recorded demo plays straight away (not saved)
	# main.tscn's map_id ("yard") picks the Yard's lighting mood in main.gd;
	# the scores are saved under this mode's id from here on.
	super._ready()
	map_id = MODE_ID
	max_enemies = Cfg.MAX_ALIVE
	spawn_timer.wait_time = Cfg.SPAWN_INTERVAL
	indicator = DamageIndicator.new()
	indicator.name = "DamageIndicator"
	hud.add_child(indicator)
	hud.move_child(indicator, hud.get_node("DamageFlash").get_index() + 1)
	_last_health = player.health
	player.health_changed.connect(_on_health_changed)
	player.hit_taken.connect(func() -> void: _since_hit = 0.0)
	_prewarm_soldier_fx()
	if SoldiersDemo.requested():
		add_child(SoldiersDemo.new())


func _setup_progress() -> void:
	Progress.start_match(MODE_ID)
	Progress.leveled_up.connect(hud.show_level_up)
	Progress.mission_completed.connect(hud.on_mission_completed)
	Progress.achievement_unlocked.connect(hud.on_achievement)
	Progress.star_earned.connect(hud.on_star_earned)


func _process(delta: float) -> void:
	super._process(delta)
	_update_regen(delta)


# --- Waves -------------------------------------------------------------------

static func soldiers_in_wave(n: int) -> int:
	return Cfg.START_SOLDIERS + Cfg.SOLDIERS_PER_WAVE * (n - 1)


func start_wave(n: int) -> void:
	wave = n
	phase = Phase.FIGHT
	_spawn_queue.clear()
	for i in soldiers_in_wave(n):
		_spawn_queue.append("soldier")
	_to_spawn = _spawn_queue.size()
	hud.show_banner("Wave %d" % n, "%d soldiers" % _to_spawn)
	hud.set_wave(wave, _to_spawn + _alive)
	spawn_timer.start()
	hud.set_shop_available(false)
	economy.new_wave()
	Progress.on_wave_started(n)
	get_tree().call_group("explosive_barrels", "respawn")


func spawn_enemy() -> void:
	var soldier := SOLDIER_SCENE.instantiate()
	soldier.kind = "soldier"
	if not _spawn_queue.is_empty():
		_spawn_queue.pop_front()
	var layer := EnemyTypes.nav_layer(soldier.kind)
	var point: Node3D = _pick_spawn_point(layer)
	var offset := Vector3(randf_range(-SPAWN_SPREAD, SPAWN_SPREAD), 0.0, randf_range(-SPAWN_SPREAD, SPAWN_SPREAD))
	var pos := _on_navmesh(point.global_position + offset, layer)
	if off_navmesh(pos, layer) > SPAWN_OFF_MESH:
		pos = _on_navmesh(point.global_position, layer)
	soldier.position = pos
	soldier.died.connect(_on_enemy_died.bind(soldier))
	soldier.stuck.connect(_on_enemy_stuck.bind(soldier))
	soldier.shot_at_player.connect(_on_soldier_shot)
	enemies.add_child(soldier)
	_to_spawn -= 1
	_alive += 1


func _on_soldier_shot(from: Vector3, hit: bool) -> void:
	if hit:
		indicator.add_hit(from)


# --- Cover -------------------------------------------------------------------

## The cover points (built on the first call once the navmesh is ready;
## empty before that, and soldiers fight in the open meanwhile).
func get_cover_points() -> Array[Dictionary]:
	if cover_points.is_empty() and navmesh_ready():
		_build_cover()
	return cover_points


# Two spots along each side of every COVER_OBJECTS entry (near each end, a
# little off the face), each with its peek spot just past that corner.
# Spots the navmesh doesn't reach (between the warehouse and the outer wall)
# are dropped.
func _build_cover() -> void:
	var region := nav_region(EnemyTypes.nav_layer("soldier"))
	if region == null:
		return
	for o: Dictionary in Cfg.COVER_OBJECTS:
		var center: Vector2 = o.center
		var half: Vector2 = o.size * 0.5
		for axis in 2:
			for side: float in [-1.0, 1.0]:
				var n := Vector2(side, 0.0) if axis == 0 else Vector2(0.0, side)
				var t := Vector2(0.0, 1.0) if axis == 0 else Vector2(1.0, 0.0)
				var half_n := half.x if axis == 0 else half.y
				var half_t := half.y if axis == 0 else half.x
				var face := center + n * (half_n + Cfg.COVER_OUT)
				for end: float in [-1.0, 1.0]:
					var pos: Variant = _snap(region, face + t * end * maxf(half_t - Cfg.COVER_EDGE_IN, 0.0))
					var peek: Variant = _snap(region, face + t * end * (half_t + Cfg.PEEK_OUT))
					if pos == null or peek == null or _near_cover(pos):
						continue
					cover_points.append({"pos": pos, "peek": peek, "normal": Vector3(n.x, 0.0, n.y),
							"object": o.name, "owner": null})


func _snap(region: NavigationRegion3D, p: Vector2) -> Variant:
	var want := Vector3(p.x, 0.0, p.y)
	var q := NavigationServer3D.region_get_closest_point(region.get_rid(), want)
	if Vector2(q.x - want.x, q.z - want.z).length() > Cfg.COVER_SNAP:
		return null
	return q


func _near_cover(pos: Vector3) -> bool:
	for c in cover_points:
		if (c.pos as Vector3).distance_to(pos) < Cfg.COVER_MERGE:
			return true
	return false


# --- Player: regen ---------------------------------------------------------

func _on_health_changed(health: int) -> void:
	if health < _last_health:
		_since_hit = 0.0
	_last_health = health


# REGEN_RATE health a second once REGEN_DELAY s have passed since the last hit.
func _update_regen(delta: float) -> void:
	if player.is_dead or phase == Phase.OVER:
		return
	_since_hit += delta
	if _since_hit < Cfg.REGEN_DELAY or player.health >= player.MAX_HEALTH:
		_regen_left = 0.0
		return
	_regen_left += Cfg.REGEN_RATE * delta
	var amount := int(_regen_left)
	if amount > 0:
		_regen_left -= amount
		player.heal(amount)


## Seconds since the player last took damage (for tests).
func time_since_hit() -> float:
	return _since_hit


# The tracer and muzzle flash drawn once, tiny, in front of the camera, so
# their shaders compile now and not on the first shot.
func _prewarm_soldier_fx() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var spot := camera.global_position - camera.global_basis.z * 2.0
	var warm: Array[Node3D] = []
	var mats := TacticalSoldier.fx_materials()
	for i in 2:
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new() if i == 0 else QuadMesh.new()
		mi.material_override = mats[i]
		add_child(mi)
		mi.global_position = spot
		mi.scale = Vector3.ONE * 0.01
		warm.append(mi)
	for i in 3:
		await get_tree().process_frame
	for mi in warm:
		mi.queue_free()
