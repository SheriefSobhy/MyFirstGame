extends "res://main.gd"
## Combat mode (Play > Combat > a map): any of the 3 maps against soldiers
## only, who fight from cover (tactical_soldier.gd). Each map's Combat scene
## is maps/combat_<map id>.tscn: the map's scene with this script. The zombie
## mode (main.gd) is unchanged; this only replaces what differs:
##  - waves: START_SOLDIERS, +SOLDIERS_PER_WAVE each wave, MAX_ALIVE at once
##  - spawns at least SPAWN_MIN_DISTANCE m from the player, out of sight if possible
##  - cover points round the map's tall and low objects (get_cover_points)
##  - soldiers start unaware (tactical_soldier.gd perception): they sweep the
##    area round a guess of where the player is, hear the player's shots
##    (_on_player_fired) and see less far in the dark and fog (visibility_at)
##  - the player: a red damage direction indicator (damage_indicator.gd) and
##    health regen after REGEN_DELAY s without damage
## Cash, the shop, XP, missions and achievements count as normal. Best score,
## stars and "reach wave" missions are saved under "combat_<map id>"
## (maps.gd save_key), apart from the map's zombie ones.
## Balance numbers: soldiers_config.gd.

const Cfg := preload("res://soldiers/soldiers_config.gd")
const SOLDIER_SCENE := preload("res://soldiers/tactical_soldier.tscn")
const TacticalSoldier := preload("res://soldiers/tactical_soldier.gd")
const DamageIndicator := preload("res://soldiers/damage_indicator.gd")
const SoldiersDemo := preload("res://soldiers/soldiers_demo.gd")
const MapList := preload("res://maps.gd")

## The map's own id ("yard", "town", "warehouse"); map_id becomes the save key.
var base_map_id := ""
## Cover spots: {pos, peek, normal (away from the object), object, low
## (crouch behind it, stand up to fire over it), eye (eye height hidden
## there), owner (the soldier using it, or null)}. Built once the navmesh is ready.
var cover_points: Array[Dictionary] = []
var indicator: DamageIndicator
var _since_hit := 0.0
var _regen_left := 0.0
var _last_health := 0
var _lamps: Array[Vector4] = []  # lit spots: position + reach (visibility_at)
var _lamps_found := false


func _ready() -> void:
	if SoldiersDemo.requested():
		Settings.tutorial_done = true  # the recorded demo plays straight away (not saved)
	# The scene's map_id ("town") picks the map's lighting mood in main.gd;
	# the scores are saved under the Combat key from here on.
	base_map_id = map_id
	super._ready()
	map_id = MapList.save_key(base_map_id, MapList.COMBAT)
	max_enemies = Cfg.MAX_ALIVE
	spawn_timer.wait_time = Cfg.SPAWN_INTERVAL
	indicator = DamageIndicator.new()
	indicator.name = "DamageIndicator"
	hud.add_child(indicator)
	hud.move_child(indicator, hud.get_node("DamageFlash").get_index() + 1)
	_last_health = player.health
	player.health_changed.connect(_on_health_changed)
	player.hit_taken.connect(func() -> void: _since_hit = 0.0)
	player.fired.connect(_on_player_fired)
	_prewarm_soldier_fx()
	if SoldiersDemo.requested():
		add_child(SoldiersDemo.new())


func _setup_progress() -> void:
	Progress.start_match(MapList.save_key(base_map_id, MapList.COMBAT))
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
	soldier.alert = false  # unaware: sweeps round a guess of where the player is
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


# Soldiers come in far from the player: spawn points SPAWN_MIN_DISTANCE m
# away or more that the player can't see, else any of those, else one of
# the 2 farthest.
func _pick_spawn_point(layer := EnemyTypes.NAV_SMALL) -> Node3D:
	var usable := _spawn_points_for(layer)
	var player_pos := player.global_position
	var far := usable.filter(func(p: Node3D) -> bool:
		return p.global_position.distance_to(player_pos) >= Cfg.SPAWN_MIN_DISTANCE)
	if far.is_empty():
		var sorted := usable.duplicate()
		sorted.sort_custom(func(a: Node3D, b: Node3D) -> bool:
			return a.global_position.distance_to(player_pos) > b.global_position.distance_to(player_pos))
		return sorted.slice(0, 2).pick_random()
	var space := get_world_3d().direct_space_state
	var eye := player_pos + Vector3.UP * 1.6
	var exclude: Array[RID] = [player.get_rid()]
	var hidden := far.filter(func(p: Node3D) -> bool:
		var q := PhysicsRayQueryParameters3D.create(eye, p.global_position + Vector3.UP * 1.5, 1, exclude)
		return not space.intersect_ray(q).is_empty())
	return (hidden if not hidden.is_empty() else far).pick_random()


func _on_soldier_shot(from: Vector3, hit: bool) -> void:
	if hit:
		indicator.add_hit(from)


# Every shot of the player's: the soldiers in earshot hear it.
func _on_player_fired() -> void:
	var pos := player.global_position
	for e in enemies.get_children():
		if e.has_method("hear_gunshot"):
			e.hear_gunshot(pos)


## How well the player can be seen at `pos` (0..1, x the soldiers' sight
## range): the map's light and fog (soldiers_config.gd VISIBILITY), at least
## LAMP_VISIBILITY near a lamp.
func visibility_at(pos: Vector3) -> float:
	var base: float = Cfg.VISIBILITY.get(base_map_id, 1.0)
	if base >= Cfg.LAMP_VISIBILITY:
		return base
	if not _lamps_found:
		_lamps_found = true
		for n in find_children("*", "Light3D", true, false):
			var l := n as Light3D
			var reach := 0.0
			if l is OmniLight3D:
				reach = (l as OmniLight3D).omni_range
			elif l is SpotLight3D:
				reach = (l as SpotLight3D).spot_range
			if reach > 0.0 and l.light_energy > 0.3:
				var p := l.global_position
				_lamps.append(Vector4(p.x, p.y, p.z, reach * Cfg.LAMP_REACH))
	for l in _lamps:
		if pos.distance_to(Vector3(l.x, l.y, l.z)) < l.w:
			return Cfg.LAMP_VISIBILITY
	return base


# --- Cover -------------------------------------------------------------------

## The cover points (built on the first call once the navmesh is ready;
## empty before that, and soldiers fight in the open meanwhile).
func get_cover_points() -> Array[Dictionary]:
	if cover_points.is_empty() and navmesh_ready():
		_build_cover()
	return cover_points


## The level's box colliders that can hide a soldier (soldiers_config.gd
## "Cover"): [{name, center, axes [x, z] (flat unit vectors), half (x, z
## half sizes), top}], tallest first.
func cover_objects() -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	var skip: Array = Cfg.COVER_SKIP.get(base_map_id, [])
	var level := get_node_or_null("NavigationRegion3D")
	if level == null:
		return list
	for shape_node: Node in level.find_children("*", "CollisionShape3D", true, false):
		var cs := shape_node as CollisionShape3D
		var body := cs.get_parent() as StaticBody3D
		if body == null or not (cs.shape is BoxShape3D) or (body.collision_layer & 1) == 0 or skip.has(String(body.name)):
			continue
		var xf := cs.global_transform
		if absf(xf.basis.y.normalized().y) < 0.95:
			continue  # tilted
		var size: Vector3 = (cs.shape as BoxShape3D).size
		var hy := size.y * xf.basis.y.length() * 0.5
		var top := xf.origin.y + hy
		if xf.origin.y - hy > 0.5 or top < Cfg.LOW_COVER:
			continue  # off the ground, or too low
		var ax := Vector3(xf.basis.x.x, 0.0, xf.basis.x.z)
		var az := Vector3(xf.basis.z.x, 0.0, xf.basis.z.z)
		var half := Vector2(size.x * ax.length(), size.z * az.length()) * 0.5
		if minf(half.x, half.y) * 2.0 < Cfg.MIN_COVER_SIDE or maxf(half.x, half.y) * 2.0 > Cfg.MAX_COVER_SIDE:
			continue  # a pole, or a long outer wall
		list.append({"name": String(body.name), "center": Vector3(xf.origin.x, 0.0, xf.origin.z),
				"axes": [ax.normalized(), az.normalized()], "half": half, "top": top})
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.top > b.top)
	return list


# Two spots along each side of every cover object (near each end, a little
# off the face). Tall ones get a peek spot just past that corner; behind low
# ones the soldier crouches and stands up on the spot to fire (peek = pos).
# Spots the navmesh doesn't reach (or inside other objects) are dropped.
func _build_cover() -> void:
	var region := nav_region(EnemyTypes.nav_layer("soldier"))
	if region == null:
		return
	for o: Dictionary in cover_objects():
		var low: bool = o.top < Cfg.TALL_COVER
		for axis in 2:
			for side: float in [-1.0, 1.0]:
				var n: Vector3 = o.axes[axis] * side
				var t: Vector3 = o.axes[1 - axis]
				var half_n: float = o.half[axis]
				var half_t: float = o.half[1 - axis]
				var face: Vector3 = o.center + n * (half_n + Cfg.COVER_OUT)
				for end: float in [-1.0, 1.0]:
					# Something in the way (a prop, a wall): slide in along the face.
					var pos: Variant = null
					for slide: float in Cfg.COVER_SLIDE:
						var along := half_t - Cfg.COVER_EDGE_IN - slide
						if along < 0.0 and slide > 0.0:
							break
						pos = _snap(region, face + t * end * maxf(along, 0.0))
						if pos != null:
							break
					if pos == null or _near_cover(pos):
						continue
					var peek: Variant = pos if low else null
					if not low:
						for out: float in [Cfg.PEEK_OUT, Cfg.PEEK_OUT * 0.7]:
							peek = _snap(region, face + t * end * (half_t + out))
							if peek != null:
								break
					if peek == null:
						continue
					cover_points.append({"pos": pos, "peek": peek, "normal": n, "object": o.name, "low": low,
							"eye": Cfg.CROUCH_EYE_HEIGHT if low else Cfg.EYE_HEIGHT, "owner": null})


func _snap(region: NavigationRegion3D, p: Vector3) -> Variant:
	var q := NavigationServer3D.region_get_closest_point(region.get_rid(), p)
	if Vector2(q.x - p.x, q.z - p.z).length() > Cfg.COVER_SNAP:
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


# The tracer, muzzle flash and "?" icon drawn once, tiny, in front of the camera, so
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
	var icon := TacticalSoldier.make_icon()
	add_child(icon)
	icon.global_position = spot
	icon.visible = true
	warm.append(icon)
	for i in 3:
		await get_tree().process_frame
	for mi in warm:
		mi.queue_free()
