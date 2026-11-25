extends "res://main.gd"
## The Training Arena (maps/training.tscn, built by tools/build_maps.gd): a
## shooting range opened from the main menu's Training button. Always
## unlocked, and nothing is earned here: it never calls Progress' match
## functions, so no XP, coins, missions, achievements or best scores.
## It reuses main.gd for the graphics settings, the navmeshes and the shader
## prewarm; the waves never start.
##
## - Every weapon, unlimited spare ammo and infinite grenades (both can be
##   turned off), the player can't be hurt. The Armory's upgrades and skins
##   apply as in a match (player.gd reads Progress).
## - Weapon rack (training/weapon_rack.gd): walk up to a gun, E / TAKE.
## - Targets (training/target.gd): paper and steel plates at 10/25/50/100 m,
##   two moving targets, and the pop-up targets the challenges use.
## - Dummies of every enemy type (enemy.gd `dummy`): stand still or walk
##   slowly, never attack, stand up again DUMMY_RESPAWN s after dying.
## - Stats: shots, hits, accuracy, headshot share, DPS on the last target.
## - Challenges (training_config.gd CHALLENGES): best results are saved by
##   Settings.submit_training().
## - The training panel (training/training_ui.gd, T or the TRAIN button).
## Every number is in training_config.gd.

signal challenge_finished(id: String, value: float, new_best: bool)

const Config := preload("res://training_config.gd")
const TrainingUI := preload("res://training/training_ui.gd")
const Weapons := preload("res://weapon_stats.gd")
const Feedback := preload("res://combat_feedback.gd")
const PlayerScript := preload("res://player.gd")

var ui: TrainingUI
var rack: Node3D
var targets: Array[Node] = []      # every target.gd node
var popups: Array[Node] = []       # the pop-up ones (challenges)
var dummies_walk := false
var show_zones := false

# Stats since the last reset.
var shots := 0
var hits := 0
var headshots := 0
## DPS on the last target hit (damage per second of the latest burst of hits,
## in damage-number units: x combat_feedback.gd DAMAGE_DISPLAY_SCALE).
var last_dps := 0.0
var _shot_hit := false        # the current shot already counted a hit...
var _shot_head := false       # ...and a headshot
var _dps_target: Node = null
var _dps_damage := 0
var _dps_start := 0.0
var _dps_last := -100.0

# Dummies: what each live one is ({kind, pos, patrol}), so it can come back.
var _dummy_info := {}         # dummy -> Dictionary
var _respawns: Array[Dictionary] = []   # {info, time}
var _zones := {}              # dummy -> head zone marker

## The running challenge ("" = none), "countdown" or "run", and its progress.
var challenge := ""
var challenge_phase := ""
var challenge_time := 0.0     # countdown left, then seconds since GO
var challenge_count := 0      # targets hit / headshots
var challenge_spawned := 0    # Reflex: targets shown so far
## {id, value, new_best} of the last finished challenge.
var last_result := {}
var _ch_timer := 0.0
var _ch_current: Node = null
var _walk_before := false
var _countdown_shown := -1


func _ready() -> void:
	_add_navmeshes()
	_nav_iteration_start = NavigationServer3D.map_get_iteration_id(get_world_3d().navigation_map)
	_player_start = player.global_position
	wind.stream.loop = true
	wind.play()
	Music.play_game(music)
	spawn_timer.stop()  # no waves
	phase = Phase.BREAK

	_connect_player_hud()
	hud.main_menu_requested.connect(exit_to_menu)
	player.invincible = true
	player.own_all_weapons()
	player.set_infinite_ammo(true)
	player.infinite_grenades = true
	player.add_grenades(PlayerScript.MAX_GRENADES)
	player.fired.connect(_on_fired)
	player.enemy_hit.connect(_on_hit)
	hud.feedback.force_numbers = true
	hud.score_label.visible = false
	hud.cash_label.visible = false
	hud.health_label.visible = false
	hud.wave_label.text = "Training Arena"
	player.emit_status()

	_apply_quality()
	Settings.changed.connect(_apply_quality)
	_prewarm_effects()

	rack = $WeaponRack
	for t: Node in get_tree().get_nodes_in_group("training_targets"):
		targets.append(t)
		if t.kind == "popup":
			popups.append(t)
		t.hit.connect(_on_target_hit)
	for kind: String in Config.DUMMY_KINDS:
		var home: Vector2 = Config.DUMMY_HOMES[kind]
		spawn_dummy(kind, Vector3(home.x, 0, home.y))

	ui = TrainingUI.new()
	ui.name = "TrainingUI"
	ui.training = self
	hud.add_child(ui)
	hud.move_child(ui, hud.pause_menu.get_index())  # under the pause menu
	hud.show_banner("Training Arena", "Weapon rack behind you  ·  %s: training panel" %
			("TRAIN" if DisplayServer.is_touchscreen_available() else "T"), 3.5)


func _process(delta: float) -> void:
	_update_respawns(delta)
	_update_challenge(delta)
	if show_zones:
		_update_zones()
	ui.set_take(rack.nearest(player.global_position, Config.RACK_REACH) if not player.is_dead else -1)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo) or get_tree().paused:
		return
	match event.physical_keycode:
		KEY_E:
			if ui.take_index >= 0:
				take_weapon(ui.take_index)
				get_viewport().set_input_as_handled()
		KEY_T:
			ui.open_panel()
			get_viewport().set_input_as_handled()


## Back to the main menu. Nothing to save: training earns nothing.
func exit_to_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file(MENU_SCENE)


# The player can't die here (player.invincible), but just in case.
func _on_player_died() -> void:
	player.revive()


# --- Weapons -----------------------------------------------------------------------

## The weapon rack: switch to weapon slot `index`.
func take_weapon(index: int) -> void:
	var name_: String = Weapons.LIST[index].name
	if player.weapon_index == index:
		hud.show_message("%s in hand" % name_)
		return
	player.switch_to(index)
	hud.show_message("Took the %s" % name_)


func set_infinite_ammo(on: bool) -> void:
	player.set_infinite_ammo(on)


func set_infinite_grenades(on: bool) -> void:
	player.infinite_grenades = on
	if not on:
		player.add_grenades(PlayerScript.MAX_GRENADES)


# --- Dummies -----------------------------------------------------------------------

## A dummy of `kind` standing at `pos` (it walks along the lane around `pos`
## while dummies_walk is on). Returns null when there are already MAX_DUMMIES.
func spawn_dummy(kind: String, pos: Vector3) -> Node:
	if live_dummies().size() >= Config.MAX_DUMMIES:
		hud.show_message("At most %d dummies" % Config.MAX_DUMMIES)
		return null
	var info := {"kind": kind, "pos": pos,
		"patrol": [pos + Vector3(0, 0, -Config.DUMMY_PATROL), pos + Vector3(0, 0, Config.DUMMY_PATROL)]}
	return _make_dummy(info)


## A dummy of `kind` somewhere in the dummy area (the panel's Spawn buttons).
func spawn_dummy_random(kind: String) -> Node:
	var a := Config.DUMMY_AREA
	var pos := Vector3(randf_range(a.position.x, a.end.x), 0, randf_range(a.position.y, a.end.y))
	var d := spawn_dummy(kind, pos)
	if d:
		hud.show_message("%s dummy spawned" % EnemyTypes.TYPES[kind].name)
	return d


func _make_dummy(info: Dictionary) -> Node:
	var kind: String = info.kind
	var layer := EnemyTypes.nav_layer(kind)
	var e := ENEMY_SCENE.instantiate()
	e.kind = kind
	e.dummy = true
	e.dummy_walk = dummies_walk
	e.speed_scale = Config.DUMMY_SPEED / EnemyTypes.TYPES[kind].speed
	var patrol: Array[Vector3] = []
	for p: Vector3 in info.patrol:
		patrol.append(_on_navmesh(p, layer))
	e.patrol = patrol
	e.position = _on_navmesh(info.pos, layer)
	e.rotation.y = PI  # facing the firing line
	e.died.connect(_on_dummy_died.bind(e))
	enemies.add_child(e)
	_dummy_info[e] = info
	return e


## The dummies alive now.
func live_dummies() -> Array[Node]:
	var out: Array[Node] = []
	for e: Node in _dummy_info:
		if is_instance_valid(e) and e.state != e.State.DEAD:
			out.append(e)
	return out


func _on_dummy_died(e: Node) -> void:
	var info: Dictionary = _dummy_info.get(e, {})
	_dummy_info.erase(e)
	if _zones.has(e):
		_zones[e].queue_free()
		_zones.erase(e)
	if not info.is_empty():
		_respawns.append({"info": info, "time": Config.DUMMY_RESPAWN})


func _update_respawns(delta: float) -> void:
	for i in range(_respawns.size() - 1, -1, -1):
		_respawns[i].time -= delta
		if _respawns[i].time <= 0.0:
			var info: Dictionary = _respawns[i].info
			_respawns.remove_at(i)
			_make_dummy(info)


## Dummies walking slowly along the lane, or standing still.
func set_dummies_walk(on: bool) -> void:
	dummies_walk = on
	for e in live_dummies():
		e.set_dummy_walk(on)


## Removes the dummies spawned from the panel; the six standard ones stay.
func clear_spawned_dummies() -> void:
	var homes := {}
	for kind: String in Config.DUMMY_HOMES:
		var h: Vector2 = Config.DUMMY_HOMES[kind]
		homes[Vector3(h.x, 0, h.y)] = true
	for e: Node in _dummy_info.keys():
		if not homes.has(_dummy_info[e].pos):
			_dummy_info.erase(e)
			e.queue_free()
	_respawns = _respawns.filter(func(r: Dictionary) -> bool: return homes.has(r.info.pos))
	for e: Node in _zones.keys():
		if not is_instance_valid(e) or e.is_queued_for_deletion():
			_zones[e].queue_free()
			_zones.erase(e)


## Head hitbox markers on the dummies on / off.
func set_show_zones(on: bool) -> void:
	show_zones = on
	if not on:
		for z: Node in _zones.values():
			z.queue_free()
		_zones.clear()


# A see-through sphere on each dummy's head hitbox (enemy.gd head_sphere()).
func _update_zones() -> void:
	for e in live_dummies():
		var head: Dictionary = e.head_sphere()
		if head.is_empty():
			continue
		var z: MeshInstance3D = _zones.get(e)
		if z == null:
			z = _zone_marker()
			e.add_child(z)
			_zones[e] = z
		z.global_position = head.center
		z.scale = Vector3.ONE * head.radius


static var _zone_mesh: SphereMesh


static func _zone_marker() -> MeshInstance3D:
	if _zone_mesh == null:
		_zone_mesh = SphereMesh.new()
		_zone_mesh.radius = 1.0
		_zone_mesh.height = 2.0
		_zone_mesh.radial_segments = 16
		_zone_mesh.rings = 8
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(1.0, 0.8, 0.2, 0.35)
		m.no_depth_test = true
		_zone_mesh.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = _zone_mesh
	mi.top_level = true
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


# --- Targets -----------------------------------------------------------------------

## Reset Targets: every target back up (pop-ups down), holes gone, missing
## dummies back right away.
func reset_targets() -> void:
	for t in targets:
		if challenge == "" or t.kind != "popup":
			t.reset()
	for r in _respawns:
		r.time = 0.0
	get_tree().call_group("bullet_holes", "queue_free")


func _on_target_hit(target: Node, _damage: int, _headshot: bool) -> void:
	if challenge_phase != "run" or target != _ch_current:
		return
	challenge_count += 1
	_ch_current = null
	match challenge:
		"targets":
			if challenge_count >= Config.CHALLENGES.targets.count:
				_finish_challenge(challenge_time)
			else:
				_pop_next()
		"reflex":
			_ch_timer = randf_range(Config.CHALLENGES.reflex.gap.x, Config.CHALLENGES.reflex.gap.y)


# --- Stats -------------------------------------------------------------------------

func reset_stats() -> void:
	shots = 0
	hits = 0
	headshots = 0
	last_dps = 0.0
	_dps_target = null
	_dps_last = -100.0


func accuracy() -> float:
	return 100.0 * hits / shots if shots > 0 else 0.0


func headshot_share() -> float:
	return 100.0 * headshots / hits if hits > 0 else 0.0


func _on_fired() -> void:
	shots += 1
	_shot_hit = false
	_shot_head = false


# A shot hit a target or a dummy (player.gd enemy_hit). One shot counts as
# one hit however many pellets or targets it hit.
func _on_hit(target: Node3D, damage: int, _point: Vector3, headshot: bool, _killed: bool) -> void:
	if not _shot_hit:
		_shot_hit = true
		hits += 1
	if headshot and not _shot_head:
		_shot_head = true
		headshots += 1
	var now := Time.get_ticks_msec() / 1000.0
	if target != _dps_target or now - _dps_last > Config.DPS_BURST_GAP:
		_dps_target = target
		_dps_damage = 0
		_dps_start = now
	_dps_damage += damage
	_dps_last = now
	# Over the burst plus one shot's delay: a single hit shows the gun's rate.
	var span := now - _dps_start + float(player.current_weapon().fire_delay)
	last_dps = _dps_damage * Feedback.DAMAGE_DISPLAY_SCALE / maxf(span, 0.05)
	if headshot and challenge == "headshots" and challenge_phase == "run" and target.get("dummy") == true:
		challenge_count += 1
		if challenge_count >= Config.CHALLENGES.headshots.count:
			_finish_challenge(challenge_count)


# --- Challenges --------------------------------------------------------------------

## Starts challenge `id` (training_config.gd CHALLENGES) after a countdown.
## The stats start again from zero.
func start_challenge(id: String) -> void:
	stop_challenge()
	challenge = id
	challenge_phase = "countdown"
	challenge_time = Config.COUNTDOWN
	challenge_count = 0
	challenge_spawned = 0
	_countdown_shown = -1
	_ch_current = null
	reset_stats()
	for p in popups:
		p.reset()
	if id == "headshots":
		_walk_before = dummies_walk
		set_dummies_walk(true)


## Stops the running challenge without a result.
func stop_challenge() -> void:
	if challenge == "":
		return
	_end_challenge()
	hud.wave_label.text = "Training Arena"
	hud.show_banner("Challenge stopped", "", 1.2)


func _end_challenge() -> void:
	if challenge == "headshots":
		set_dummies_walk(_walk_before)
	challenge = ""
	challenge_phase = ""
	_ch_current = null
	for p in popups:
		p.pop_down()


func _update_challenge(delta: float) -> void:
	if challenge == "":
		return
	var c: Dictionary = Config.CHALLENGES[challenge]
	if challenge_phase == "countdown":
		challenge_time -= delta
		var n := ceili(challenge_time)
		if n != _countdown_shown:
			_countdown_shown = n
			if n > 0:
				hud.show_banner(str(n), c.name, 0.6)
		if challenge_time <= 0.0:
			challenge_phase = "run"
			challenge_time = 0.0
			hud.show_banner("GO!", c.info, 0.8)
			if challenge == "targets":
				_pop_next()
			elif challenge == "reflex":
				_ch_timer = 0.3
		hud.wave_label.text = c.name
		return
	challenge_time += delta
	match challenge:
		"targets":
			hud.wave_label.text = "%s  ·  %d / %d  ·  %.1f s" % [c.name, challenge_count, c.count, challenge_time]
		"headshots":
			var left: float = c.time - challenge_time
			hud.wave_label.text = "%s  ·  %d / %d  ·  %d s" % [c.name, challenge_count, c.count, ceili(maxf(left, 0.0))]
			if left <= 0.0:
				_finish_challenge(challenge_count)
		"reflex":
			hud.wave_label.text = "%s  ·  %d hit  ·  %d / %d" % [c.name, challenge_count, challenge_spawned, c.count]
			_ch_timer -= delta
			if _ch_timer > 0.0:
				return
			if _ch_current != null:
				_ch_current.pop_down()  # too slow: a miss
				_ch_current = null
				_ch_timer = randf_range(c.gap.x, c.gap.y)
			elif challenge_spawned >= c.count:
				_finish_challenge(100.0 * challenge_count / c.count)
			else:
				_pop_next()
				challenge_spawned += 1
				_ch_timer = c.up_time


# Raises a random pop-up target (not the last one).
func _pop_next() -> void:
	var last := _ch_current
	var choices := popups.filter(func(p: Node) -> bool: return p != last and not p.is_up)
	if choices.is_empty():
		choices = popups
	_ch_current = choices.pick_random()
	_ch_current.pop_up()


func _finish_challenge(value: float) -> void:
	var id := challenge
	var c: Dictionary = Config.CHALLENGES[id]
	var new_best: bool = Settings.submit_training(id, value, c.lower_is_better)
	_end_challenge()
	last_result = {"id": id, "value": value, "new_best": new_best}
	hud.wave_label.text = "Training Arena"
	var sub := "New best!" if new_best else "Best: %s" % Config.format_best(id, Settings.training_best(id))
	sub += "   ·   Accuracy %d%%" % roundi(accuracy())
	hud.show_banner("%s: %s" % [c.name, Config.format_best(id, value)], sub, 4.0)
	challenge_finished.emit(id, value, new_best)
	ui.refresh()
