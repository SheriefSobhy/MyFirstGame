extends SceneTree
## Automated check of the Combat mode (soldiers/) on all 3 maps:
##   godot --headless --path . --script res://tools/test_soldiers.gd [-- --map town]
## Prints PASS/FAIL per check and exits with code 1 if anything failed.
##
## Play -> choose a mode -> choose a map -> loading screen -> the map with
## soldiers only (no Soldiers (Test) button any more); waves of 3, +1, at
## most 8 at once, spawning far from the player; cover points on the navmesh
## behind tall and low objects; soldiers take cover (crouching behind low
## cover), burst-fire (tracer, flash, sound), leave a cover the player
## flanks; accuracy falls with distance and movement; headshots, hit
## reactions, death and rewards; the damage direction indicator and health
## regen; best wave / stars / missions saved per mode and map. The zombie
## mode keeps its own waves and scenes.
## Perception: an unaware guard doesn't notice a player behind it (standing
## or walking), hears them sprint ("?"), turns, sees them ("!"); its radio
## report reaches a soldier nearby 1-2 s later but not one far away; a far
## one hears a gunshot; losing the player = search ("?") then patrol again.
## Animation: the velocity blend (forward / strafe / back, playback speed =
## ground speed), aiming idle while firing, crouch idle, hit reaction,
## smooth turning.

const Cfg := preload("res://soldiers/soldiers_config.gd")
const Maps := preload("res://maps.gd")
const Progression := preload("res://progression_config.gd")
var Tactical: GDScript
var Mode: GDScript
var Zombies: GDScript

var failures := 0
var main: Node
var player: Node
var progress: Node
var map_id := ""
var _backup := {}
var _spawn_distances: Array[float] = []
var _max_turn := 0.0  # biggest yaw change of a soldier in one physics frame
var _strafed := 0  # frames a soldier was seen strafing / backing off
var _yaws := {}
var _feet := Vector2i.ZERO  # walking / running samples: playback speed matched the ground speed, or not


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + ("[%s] " % map_id if map_id != "" else "") + what)
	if not ok:
		failures += 1


func frames(n: int) -> void:
	for i in n:
		await physics_frame
		await process_frame


func seconds(t: float) -> void:
	await create_timer(t, true, true).timeout


func _run() -> void:
	Tactical = load("res://soldiers/tactical_soldier.gd")
	Mode = load("res://soldiers/soldiers_mode.gd")
	Zombies = load("res://main.gd")
	progress = root.get_node("Progress")
	_backup_saves()
	progress.xp = Progression.xp_for_level(15)  # every map unlocked
	_test_keys_and_missions()
	var only := ""
	var args := OS.get_cmdline_user_args()
	if args.has("--map"):
		only = args[args.find("--map") + 1]
	for m: Dictionary in Maps.LIST:
		if only != "" and m.id != only:
			continue
		map_id = m.id
		await _test_menu_flow(m.id)
		if main == null:
			continue
		_test_setup()
		await _test_spawns_and_cover()
		_test_audio()
		await _test_burst()
		if map_id != "warehouse":
			await _test_crouch()
		await _test_flank()
		await _test_hits_and_death()
		await _test_regen()
		await _test_perception()
		_test_saved_apart()
	map_id = ""
	_test_accuracy()
	_finish()


func _finish() -> void:
	_restore_saves()
	print("\n%s: %d failure(s)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _test_keys_and_missions() -> void:
	check(Maps.save_key("town", Maps.COMBAT) == "combat_town" and Maps.save_key("town", Maps.ZOMBIES) == "town"
			and Maps.base_id("combat_warehouse") == "warehouse" and Maps.mode_of("combat_yard") == Maps.COMBAT,
			"save keys: Zombies 'town', Combat 'combat_town'")
	check(Maps.for_mode("town", Maps.COMBAT).scene == "res://maps/combat_town.tscn"
			and Maps.for_mode("town", Maps.ZOMBIES).scene == "res://maps/town.tscn", "each map has a Combat scene")
	var combat := 0
	var zombies := 0
	for day in 120:
		for mission: Dictionary in progress.make_missions("2026-%02d-%02d" % [day / 28 + 1, day % 28 + 1]):
			if mission.type != "reach_wave":
				continue
			if Maps.mode_of(mission.map) == Maps.COMBAT and mission.text.ends_with("(Combat)"):
				combat += 1
			elif not mission.map.begins_with("combat_"):
				zombies += 1
	check(combat > 0 and zombies > 0, "'reach wave' missions name a map in either mode (%d combat, %d zombies)" % [combat, zombies])


func _test_menu_flow(id: String) -> void:
	main = null
	change_scene_to_file("res://ui/main_menu.tscn")
	await frames(3)
	var menu := current_scene
	var login: Control = menu.get("login_popup")
	if login:
		login.visible = false
	check(menu.find_child("SoldiersButton", true, false) == null, "no Soldiers (Test) button on the main menu")
	menu.play_button.pressed.emit()
	for i in 60:
		await frames(1)
		if current_scene and current_scene.name == "MapSelect":
			break
	var select := current_scene
	if select == null or select.name != "MapSelect":
		check(false, "Play opens the mode / map selection")
		return
	check(select.choosing_mode and select.mode_buttons.size() == 2 and select.mode_buttons.has(Maps.COMBAT),
			"Play shows the mode choice first (Zombies / Combat)")
	select.mode_buttons[Maps.COMBAT].pressed.emit()
	await frames(2)
	select.combat_buttons["waves"].pressed.emit()  # Combat > Waves (Missions: test_missions.gd)
	await frames(2)
	check(not select.choosing_mode and select.mode == Maps.COMBAT and select.play_buttons.size() == 3,
			"choosing Combat > Waves shows the 3 maps")
	var button: Button = select.play_buttons[id]
	check(not button.disabled, "the map is unlocked at level 15")
	button.pressed.emit()
	for i in 900:
		await frames(1)
		if current_scene and current_scene.name == "Main":
			break
	main = current_scene
	check(main != null and main.get_script() == Mode, "the map opens in Combat through the loading screen")
	if main == null or main.get_script() != Mode:
		main = null
		return
	player = main.player
	player.invincible = true  # until the regen check
	main.revives_left = 0
	_spawn_distances.clear()
	main.enemies.child_entered_tree.connect(func(e: Node) -> void:
		_spawn_distances.append(Vector2(e.position.x - player.global_position.x, e.position.z - player.global_position.z).length()))
	await frames(5)


func _test_setup() -> void:
	check(main.base_map_id == map_id and main.map_id == "combat_" + map_id, "scores are saved under 'combat_%s'" % map_id)
	check(progress.current.get("map", "") == "combat_" + map_id, "the match counts for Combat on this map")
	check(Mode.soldiers_in_wave(1) == 3 and Mode.soldiers_in_wave(2) == 4 and Mode.soldiers_in_wave(6) == 8,
			"waves: 3 soldiers, +1 each wave")
	check(main.max_enemies == 8 and Cfg.MAX_ALIVE == 8, "at most 8 soldiers at once")
	var zombie_scene: Node = load(Maps.find(map_id).scene).instantiate()
	check(Zombies.wave_kinds(1).has("normal") and zombie_scene.get_script() == Zombies,
			"the zombie mode keeps main.gd and its zombie waves")
	zombie_scene.free()


func _soldiers() -> Array:
	return main.enemies.get_children().filter(func(e: Node) -> bool: return e.state != e.State.DEAD)


func _test_audio() -> void:
	var music: AudioStream = root.get_node("Music")._player.stream
	check(music == Mode.COMBAT_TRACK and music.loop, "Combat plays its own looping music")
	check(main.distant_fire != null, "distant gunfire ambience")
	var s: Node = _soldiers()[0]
	var voice: AudioStreamPlayer3D = s.growl_player
	voice.stop()
	s._growl_timer = 0.0
	s._update_growl(1.0)
	s._growl(1.0)
	check(not voice.playing and voice.stream is AudioStreamWAV, "soldiers never growl or groan (the voice is a radio blip)")


func _test_spawns_and_cover() -> void:
	for i in 600:
		await frames(1)
		if _soldiers().size() >= 3:
			break
	var s := _soldiers()
	check(s.size() == 3, "wave 1 spawns 3 soldiers (%d)" % s.size())
	check(s.all(func(e: Node) -> bool: return e.get_script() == Tactical and e.kind == "soldier"),
			"every enemy is the Mixamo soldier with the cover AI")
	var nearest: float = _spawn_distances.min() if not _spawn_distances.is_empty() else 0.0
	check(nearest >= Cfg.SPAWN_MIN_DISTANCE - main.SPAWN_SPREAD - 0.5,
			"soldiers spawn away from the player (nearest %.1f m)" % nearest)
	var points: Array = main.get_cover_points()
	var low := points.filter(func(c: Dictionary) -> bool: return c.low)
	var objects := {}
	for c: Dictionary in points:
		objects[c.object] = true
	print("  %d cover points (%d low) round %d objects: %s" % [points.size(), low.size(), objects.size(), ", ".join(objects.keys())])
	check(points.size() >= 16 and objects.size() >= 4, "cover points round the map's objects (%d at %d)" % [points.size(), objects.size()])
	if map_id == "warehouse":  # racks, forklifts, the truck and the container: all tall
		check(low.is_empty() and points.size() > 0, "tall cover only (racks, forklifts, truck, container)")
	else:
		check(low.size() >= 4 and low.size() < points.size(), "both tall cover and low cover (%d low)" % low.size())
	var space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
	var backed := 0
	var unique := true
	for c: Dictionary in points:
		var eye: Vector3 = c.pos + Vector3.UP * (c.eye as float)
		var q := PhysicsRayQueryParameters3D.create(eye, eye - (c.normal as Vector3) * 2.5, 1)
		if not space.intersect_ray(q).is_empty():
			backed += 1
		for o: Dictionary in points:
			if o != c and (o.pos as Vector3).distance_to(c.pos) < Cfg.COVER_MERGE - 0.01:
				unique = false
	check(backed == points.size(), "each cover point has its object behind it at eye height (%d/%d)" % [backed, points.size()])
	check(unique, "cover points are spread out (none closer than %.1f m)" % Cfg.COVER_MERGE)
	var on_mesh := points.filter(func(c: Dictionary) -> bool: return main.off_navmesh(c.pos, 1) < Cfg.COVER_SNAP + 0.05)
	check(on_mesh.size() == points.size(), "every cover point is on the soldiers' navmesh")
	var hidden: Node = null
	for i in 1200:
		await frames(1)
		for e: Node in _soldiers():
			if e.tac == Tactical.Tac.HIDE:
				hidden = e
		if hidden:
			break
	check(hidden != null, "soldiers move to cover and hide")
	if hidden:
		check(not hidden._exposed_at(hidden.cover.pos, hidden.cover.eye), "hidden: the player can't see the soldier at its cover")
		var claimed := points.filter(func(c: Dictionary) -> bool: return c.owner == hidden)
		check(claimed.size() == 1, "the soldier holds one cover point")


func _test_burst() -> void:
	var seen_fx := false
	var seen_sound := false
	var seen_indicator := false
	var burst_ok := false
	var shooter: Node = null
	var aim_anim := true
	var aimed := false
	for i in 4000:
		await frames(1)
		for e: Node in _soldiers():
			_watch_anim(e, _yaws)
			var bl: Vector3 = e.anim_blend()
			var v := Vector2(e.velocity.x, e.velocity.z).length()
			if e.state == e.State.AIM and e._state_time > 0.3:
				aimed = true
				aim_anim = aim_anim and e.anim_action() == "aim"
		for e: Node in _soldiers():
			if e.fx_visible():
				seen_fx = true
			if e.is_gun_sound_playing():
				seen_sound = true
			if e.shots_fired >= Cfg.BURST.x:
				burst_ok = true
				shooter = e
		if main.indicator.active_count() > 0:
			seen_indicator = true
		if burst_ok and seen_indicator and seen_fx and seen_sound:
			break
	if not burst_ok:
		for e: Node in _soldiers():
			print("  debug: soldier at %s tac %d state %d shots %d dist %.1f view %s cover %s" % [e.global_position, e.tac, e.state, e.shots_fired, e._flat_distance_to_player(), e.can_see_player(), e.cover.get("object", "-")])
	check(burst_ok, "soldiers peek out and fire bursts of %d+ shots" % Cfg.BURST.x)
	check(seen_fx, "tracers and muzzle flash show")
	check(seen_sound, "gunshot sound plays")
	check(seen_indicator, "a hit on the player shows the damage direction indicator")
	check(aimed and aim_anim, "aiming idle while firing")
	check(_max_turn <= deg_to_rad(Cfg.TURN_RATE) / 60.0 * 1.6, "turns smoothly (at most %.0f deg a frame)" % rad_to_deg(_max_turn))
	if shooter:
		await frames(30)
		check(shooter.tac != Tactical.Tac.OPEN or main.get_cover_points().is_empty(),
				"after a burst the soldier goes back behind cover (or to a new one)")
	var ind: Node = main.indicator
	var cam: Camera3D = player.camera
	var ahead: float = ind.angle_to(cam.global_position - cam.global_basis.z * 5.0)
	var right: float = ind.angle_to(cam.global_position + cam.global_basis.x * 5.0)
	var behind: float = ind.angle_to(cam.global_position + cam.global_basis.z * 5.0)
	check(ind.size.x > 600.0 and absf(ahead) < 0.05 and absf(right - PI / 2.0) < 0.05 and absf(absf(behind) - PI) < 0.05,
			"the indicator covers the screen and points ahead / right / behind correctly")


# A soldier behind low cover crouches out of sight (shorter hit capsule,
# head down) and stands up to fire over it.
func _test_crouch() -> void:
	# Send the soldiers to low cover only (the tall points are taken).
	var points: Array = main.get_cover_points()
	# Stand 8-14 m in front of a low cover point, where a soldier standing up
	# there can see the player over it.
	var space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
	var target: Dictionary = {}
	for c: Dictionary in points:
		if not c.low or not target.is_empty():
			continue
		for d: float in [10.0, 8.0, 12.0, 14.0]:
			var p: Vector3 = c.pos - (c.normal as Vector3) * d
			if main.off_navmesh(p, 1) > 0.2:
				continue
			var q := PhysicsRayQueryParameters3D.create(c.pos + Vector3.UP * 1.45, p + Vector3.UP * 1.2, 3)
			if space.intersect_ray(q).is_empty():
				player.global_position = Vector3(p.x, 0.1, p.z)
				target = c
				break
	check(not target.is_empty(), "a spot facing a low cover point")
	await frames(2)
	# Only that cover point is free.
	var blocker := Node.new()
	root.add_child(blocker)
	for c: Dictionary in points:
		if c != target:
			c.owner = blocker
	for e: Node in _soldiers():
		e.raise_alert()  # they know where the player went
		e._go(Tactical.Tac.FIND)
	# One soldier starts just behind that cover and holds it. From wherever the
	# burst test left them, the way there can lead past the player, where the
	# soldier stops to jab and never arrives.
	var runner: Node = _soldiers()[0]
	runner.global_position = main._on_navmesh(target.pos + (target.normal as Vector3) * 1.5, 1) + Vector3.UP * 0.1
	runner.velocity = Vector3.ZERO
	runner._no_view.clear()
	target.owner = runner
	var s: Node = null
	for i in 1500:
		await frames(1)
		for e: Node in _soldiers():
			_watch_anim(e, _yaws)
		for e: Node in _soldiers():
			if e.wants_crouch() and e.crouch_amount() >= 1.0 and e._clear_view_from(e.cover.pos):
				s = e
		if s:
			break
	if s == null:
		check(false, "a soldier crouches behind low cover")
	else:
		await seconds(0.3)
		check(s.anim_action() == "crouch", "the crouch idle clip plays behind low cover")
		var head_y: float = s.head_sphere().center.y - s.global_position.y
		var capsule: CapsuleShape3D = s.collision.shape
		check(capsule.height <= Cfg.CROUCH_HEIGHT + 0.01 and head_y < 1.25,
				"a soldier crouches behind low cover (head %.2f m up, capsule %.1f m)" % [head_y, capsule.height])
		check(not s._exposed_at(s.cover.pos, Cfg.CROUCH_EYE_HEIGHT), "crouched, the player can't see it over the cover")
		var stood := false
		for i in 900:
			await frames(1)
			if s.state == s.State.DEAD:
				break
			if s.state == s.State.AIM and s.crouch_amount() < 0.2 and capsule.height > Cfg.CROUCH_HEIGHT + 0.1:
				stood = true
				break
		if not stood:
			print("  debug: tac %d state %d crouch %.2f dist %.1f view %s cover %s" % [s.tac, s.state, s.crouch_amount(), s._flat_distance_to_player(), s._clear_view_from(s.cover.get("pos", s.global_position)), s.cover.get("object", "-")])
		check(stood, "it stands up to fire over the low cover")
	for c: Dictionary in points:
		if c.owner == blocker:
			c.owner = null
	blocker.free()
	player.global_position = main._player_start + Vector3.UP * 0.1


func _test_flank() -> void:
	# A hiding soldier with open ground 6 m out on its side of the cover.
	var s: Node = null
	var spot := Vector3.ZERO
	var offsets: Array[Vector2] = []  # (out along the normal, along the face)
	for out: float in [6.0, 4.0, 2.5, 8.0, 1.5]:
		for side: float in [0.0, 3.0, -3.0, 5.0, -5.0]:
			offsets.append(Vector2(out, side))
	for i in 1800:
		await frames(1)
		for e: Node in _soldiers():
			_watch_anim(e, _yaws)
		for e: Node in _soldiers():
			if e.tac != Tactical.Tac.HIDE:
				continue
			var n: Vector3 = e.cover.normal
			var t := n.cross(Vector3.UP)
			for o: Vector2 in offsets:
				var off: Vector3 = n * o.x + t * o.y
				var p: Vector3 = e.cover.pos + off
				if main.off_navmesh(p, 1) < 0.2 and not e._exposed_at(e.cover.pos, e.cover.eye):
					# Standing at p must see the soldier.
					var space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
					var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 1.6, e.cover.pos + Vector3.UP * (e.cover.eye as float), 1)
					if space.intersect_ray(q).is_empty():
						s = e
						spot = p
						break
			if s:
				break
		if s:
			break
	if s == null:
		check(false, "a hiding soldier to flank")
		return
	var before: int = s.flanked_count
	var c: Dictionary = s.cover
	# Stand there: the soldier is in plain view.
	player.global_position = Vector3(spot.x, 0.1, spot.z)
	var moved := false
	for i in 120:
		await frames(1)
		if s.flanked_count > before or s.cover != c:
			moved = true
			break
	check(moved, "a flanked soldier leaves its cover for another")
	player.global_position = main._player_start + Vector3.UP * 0.1


func _test_accuracy() -> void:
	var near: float = Tactical.hit_chance(5.0, 0.0)
	var mid: float = Tactical.hit_chance(15.0, 0.0)
	var far: float = Tactical.hit_chance(28.0, 0.0)
	var moving: float = Tactical.hit_chance(15.0, 5.0)
	check(near > mid and mid > far and far > 0.0, "accuracy drops with distance (%.2f / %.2f / %.2f)" % [near, mid, far])
	check(moving < mid * 0.6, "accuracy drops when the player moves (%.2f vs %.2f)" % [moving, mid])


func _test_hits_and_death() -> void:
	print("  %d frames of soldiers strafing / backing off in the fight" % _strafed)
	_strafed = 0
	var list := _soldiers().filter(func(e: Node) -> bool: return e.crouch_amount() == 0.0 and e.state != e.State.AIM)
	if list.is_empty():
		list = _soldiers()
	if list.is_empty():
		check(false, "a soldier to shoot")
		return
	var s: Node = list[0]
	var head: Dictionary = s.head_sphere()
	var center: Vector3 = head.center
	var from := center + Vector3(4.0, 0.0, 0.0)
	check(s.is_head_hit(from, (center - from).normalized()), "headshots hit the soldier's head")
	var chest := center - Vector3.UP * 0.6
	check(not s.is_head_hit(from, (chest - from).normalized()), "a chest shot is not a headshot")
	s.take_damage(1, chest, Vector3.RIGHT, false)
	check(s.state == s.State.HIT, "a hit staggers the soldier (hit reaction)")
	await frames(2)
	check(s.get_node("Model/AnimationTree").get("parameters/hit/active"), "the hit reaction clip plays")
	var kills: int = main.kills
	var cash: int = main.economy.cash
	var xp: int = progress.xp
	s.take_damage(40, center, Vector3.RIGHT, true)
	await frames(2)
	check(s.state == s.State.DEAD and s.last_hit_was_headshot(), "a headshot kills it (death animation)")
	check(main.kills == kills + 1 and main.economy.cash > cash and progress.xp > xp, "the kill pays cash and XP")
	check(s.cover.is_empty(), "a dead soldier frees its cover point")


func _test_regen() -> void:
	main.spawn_timer.stop()
	for e: Node in main.enemies.get_children():
		e.queue_free()
	await frames(2)
	player.invincible = false
	player.heal(100)
	player.take_damage(30)
	var hurt: int = player.health
	check(hurt < 100 and main.time_since_hit() < 0.1, "damage resets the regen timer")
	await seconds(Cfg.REGEN_DELAY - 1.0)
	check(player.health == hurt, "no regen before %.0f s" % Cfg.REGEN_DELAY)
	await seconds(2.0)
	check(player.health > hurt, "health comes back after %.0f s without damage (%d -> %d)" % [Cfg.REGEN_DELAY, hurt, player.health])


# Largest turn per physics frame (alive, not dying), per soldier id.
func _watch_anim(e: Node, yaws: Dictionary) -> void:
	var id := e.get_instance_id()
	var frame := Engine.get_physics_frames()
	if yaws.has(id) and frame - (yaws[id] as Vector2).y == 1 and e.state != e.State.DEAD:
		_max_turn = maxf(_max_turn, absf(wrapf(e.rotation.y - (yaws[id] as Vector2).x, -PI, PI)))
	yaws[id] = Vector2(e.rotation.y, frame)
	var bl: Vector3 = e.anim_blend()
	if e.state == e.State.CHASE and Vector2(e.velocity.x, e.velocity.z).length() > 0.6 and (absf(bl.x) > 0.5 or bl.y < -0.5):
		_strafed += 1


# Walking or running straight ahead: is the clip played at the speed that
# matches the ground speed (within the playback limits)?
func _check_feet(e: Node) -> void:
	var bl: Vector3 = e.anim_blend()
	var v := Vector2(e.velocity.x, e.velocity.z).length()
	if e.state != e.State.CHASE or v < 0.5 or absf(bl.x) > 0.1:
		return
	var clip := "walk" if absf(bl.y - 1.0) < 0.05 else ("run" if absf(bl.y - 2.0) < 0.05 else "")
	if clip == "":
		return
	var want := clampf(v / (e._clip_speeds[clip] * e.stats.model_scale), Cfg.ANIM_SCALE.x, Cfg.ANIM_SCALE.y)
	if absf(bl.z - want) < 0.1 * want:
		_feet.x += 1
	else:
		_feet.y += 1


# A navmesh point about `dist` m from `from` (at least 7 m from `avoid`), in
# the open (a clear line at eye height) if need_view, or INF.
func _open_spot(from: Vector3, dist: float, avoid := Vector3.INF, need_view := true) -> Vector3:
	var space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
	for i in 24:
		var a := i * TAU / 24.0
		var p: Vector3 = main._on_navmesh(from + Vector3(cos(a), 0.0, sin(a)) * dist, 1)
		if main.off_navmesh(p, 1) > 0.3 or absf(_flat(p, from) - dist) > 1.5:
			continue
		if avoid != Vector3.INF and _flat(p, avoid) < 7.0:
			continue
		var q := PhysicsRayQueryParameters3D.create(from + Vector3.UP * 1.5, p + Vector3.UP * 1.5, 3, [player.get_rid()])
		if not need_view or space.intersect_ray(q).is_empty():
			return p
	return Vector3.INF


# True if the soldiers' navmesh path from `a` to `b` is about a straight line.
func _walks_straight(a: Vector3, b: Vector3) -> bool:
	var path := NavigationServer3D.map_get_path(main.get_world_3d().navigation_map, a, b, true, 1)
	if path.is_empty() or _flat(path[path.size() - 1], b) > 0.3:
		return false
	var length := 0.0
	for i in range(1, path.size()):
		length += _flat(path[i - 1], path[i])
	return length < _flat(a, b) * 1.05


func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


# A guard that stays at `pos` looking away from `away_from` (no patrol).
func _spawn_guard(pos: Vector3, away_from: Vector3, still := true) -> Node:
	var s: Node = main.SOLDIER_SCENE.instantiate()
	s.kind = "soldier"
	s.alert = false
	s.guard_post = pos
	var d := pos - away_from
	s.guard_yaw = rad_to_deg(atan2(-d.x, -d.z))
	s.rotation.y = deg_to_rad(s.guard_yaw)
	s.position = pos + Vector3.UP * 0.1
	main.enemies.add_child(s)
	if still:
		s._route.assign([s.guard_post])
	return s


func _put_player(pos: Vector3) -> void:
	player.global_position = pos + Vector3.UP * 0.1
	player.velocity = Vector3.ZERO


func _test_perception() -> void:
	main.spawn_timer.stop()
	for e: Node in main.enemies.get_children():
		e.queue_free()
	await frames(2)
	player.invincible = true
	var start: Vector3 = main._player_start
	# Darkness / fog: the map's visibility, lamps light spots up.
	var base: float = Cfg.VISIBILITY.get(map_id, 1.0)
	check(is_equal_approx(main.visibility_at(start + Vector3(0, 0, 500)), base),
			"sight range x%.2f on this map (light, fog)" % base)
	if base < Cfg.LAMP_VISIBILITY:
		var lamps: Array = main._lamps
		check(not lamps.is_empty() and main.visibility_at(Vector3(lamps[0].x, lamps[0].y, lamps[0].z)) == Cfg.LAMP_VISIBILITY,
				"lamps light spots up in the dark (%d lamps)" % lamps.size())
	var a_pos := _open_spot(start, 10.0)
	if a_pos == Vector3.INF:
		check(false, "an open spot for the perception test")
		return
	_put_player(start)
	# Where the player will sprint, 5 m behind A. The squad mate B must neither
	# hear that nor see the player there (it faces away), so that only A's radio
	# can tell it.
	var behind: Vector3 = main._on_navmesh(a_pos + (start - a_pos).normalized() * 5.0, 1)
	var b_pos := Vector3.INF
	for d: float in [8.0, 11.0, 14.0, 17.0, 20.0]:
		if b_pos == Vector3.INF:
			var p := _open_spot(a_pos, d, start, false)
			if p != Vector3.INF and _flat(p, behind) > Cfg.SPRINT_HEAR + 3.5:
				b_pos = p
	var a := _spawn_guard(a_pos, start)
	var b: Node = _spawn_guard(b_pos, behind) if b_pos != Vector3.INF else null
	# A far soldier (> RADIO_RANGE from A): the spawn point farthest from A.
	var far_pos := Vector3.INF
	for p: Node3D in main._spawn_points_for(1):
		var q: Vector3 = main._on_navmesh(p.global_position, 1)
		if _flat(q, a_pos) > Cfg.RADIO_RANGE + 3.0 and _flat(q, start) > 20.0 \
				and (far_pos == Vector3.INF or _flat(q, a_pos) > _flat(far_pos, a_pos)):
			far_pos = q
	var c: Node = _spawn_guard(far_pos, start) if far_pos != Vector3.INF else null
	if b == null or c == null:
		print("  debug: no spot for the %s" % ("squad mate" if b == null else "far soldier"))
	await seconds(1.5)
	check(a.awareness == Tactical.Aware.UNAWARE and a.icon_text() == "",
			"an unaware guard doesn't notice a player standing behind it (10 m)")
	Input.action_press("move_left")
	await seconds(0.5)
	Input.action_release("move_left")
	await frames(3)
	check(a.awareness == Tactical.Aware.UNAWARE, "walking behind it is silent")
	# Sprinting 5 m behind it: heard.
	_put_player(behind)
	player.rotation.y = atan2(-(a_pos - behind).x, -(a_pos - behind).z)
	await frames(2)
	Input.action_press("move_left")
	Input.action_press("sprint")
	var suspicious := false
	for i in 40:
		await frames(1)
		if a.awareness == Tactical.Aware.SUSPICIOUS and a.icon_text() == "?":
			suspicious = true
			break
	Input.action_release("move_left")
	Input.action_release("sprint")
	check(suspicious, "sprinting close behind it is heard: suspicious, '?' above its head")
	# It turns, sees the player and goes into combat.
	var combat := false
	for i in 240:
		await frames(1)
		if a.awareness == Tactical.Aware.COMBAT:
			combat = true
			break
	await frames(1)  # the icon updates in _process
	check(combat and a.icon_text() == "!" and _flat(a.known_position(), player.global_position) < 1.5,
			"it turns, sees the player: combat, '!' (%s, '%s')" % [Tactical.Aware.keys()[a.awareness], a.icon_text()])
	# Radio: the soldier 8 m away hears it 1-2 s later, the far one never.
	if b:
		check(b.awareness != Tactical.Aware.COMBAT, "the squad mate isn't told at once")
		var waited := 0.0
		while waited < 3.0 and b.awareness != Tactical.Aware.COMBAT:
			await frames(1)
			waited += 1.0 / 60.0
		check(b.awareness == Tactical.Aware.COMBAT and waited >= Cfg.RADIO_DELAY.x - 0.25 and waited <= Cfg.RADIO_DELAY.y + 0.3,
				"a radio report brings the squad mate %.0f m away in %.1f s" % [_flat(a_pos, b_pos), waited])
		check(a.radio_reports >= 1, "the guard radioed the player's position")
	if c:
		check(c.awareness == Tactical.Aware.UNAWARE, "a soldier %.0f m away gets no report (not map-wide)" % _flat(far_pos, a_pos))
	# Shots: a far soldier hears one within GUNSHOT_HEAR m with a clear line.
	if c:
		var shot_pos := _open_spot(far_pos, 20.0)
		if shot_pos != Vector3.INF:
			_put_player(shot_pos)
			await frames(2)
			player.fired.emit()
			await frames(2)
			check(c.awareness == Tactical.Aware.SUSPICIOUS, "a gunshot 20 m away makes a soldier suspicious")
			c._calm_down()
	# Lost: the player gone (far away under the map) -> search, then patrol.
	var seen_at: Vector3 = a.known_position()
	var gone := a_pos + (a_pos - (far_pos if c else start)).normalized() * 80.0 + Vector3.DOWN * 30.0
	player.set_physics_process(false)
	player.global_position = gone
	var searched := false
	for i in int((Cfg.LOSE_CONTACT + 3.0) * 60):
		await frames(1)
		if a.awareness == Tactical.Aware.SEARCH:
			searched = true
			break
	await frames(1)
	check(searched and a.icon_text() == "?", "out of sight for %.0f s: it searches ('?')" % Cfg.LOSE_CONTACT)
	check(_flat(a.known_position(), seen_at) < 3.0 or a.known_position().distance_to(gone) > 30.0,
			"it searches where it last saw / heard the player")
	# A guard left to patrol where the player was (they are gone now).
	var d: Node = _spawn_guard(start, a_pos, false)
	var calm := false
	var patrolled := false
	for i in int((Cfg.SEARCH_TIME + 2.0) * 60):
		await frames(1)
		_check_feet(a)
		_check_feet(d)
		if _flat(d.global_position, start) > 1.5 and d.awareness == Tactical.Aware.UNAWARE:
			patrolled = true
		if a.awareness == Tactical.Aware.UNAWARE:
			calm = true
			break
	await frames(1)
	check(calm and a.icon_text() == "", "after %.0f s of searching it goes back to patrol" % Cfg.SEARCH_TIME)
	check(_feet.x > 30 and _feet.y <= _feet.x / 10,
			"walk / run playback speed follows the ground speed (%d ok, %d off)" % [_feet.x, _feet.y])
	check(d._route.size() > 1 and patrolled, "unaware guards patrol round their post (%d points)" % d._route.size())
	player.set_physics_process(true)
	_put_player(start)
	player.invincible = false
	await _test_strafe()


# A soldier in combat moving back to its cover with the player in view keeps
# facing them: sideways = the strafe clips, away = walking backwards.
func _test_strafe() -> void:
	var start: Vector3 = main._player_start
	_put_player(start)
	player.invincible = true
	# The perception test's soldiers would block the rays and the way.
	for e: Node in main.enemies.get_children():
		e.queue_free()
	await frames(2)
	var e_pos := _open_spot(start, 8.0)
	if e_pos == Vector3.INF:
		return
	var to_player := (start - e_pos).normalized()
	var side := to_player.cross(Vector3.UP).normalized()
	for way: String in ["side", "back"]:
		var dir: Vector3 = side if way == "side" else -to_player
		var goal := Vector3.INF
		for d: float in [4.0, 3.0, 2.0]:
			for sgn: float in [1.0, -1.0]:
				var p: Vector3 = main._on_navmesh(e_pos + dir * d * sgn, 1)
				# A straight walk there: round an obstacle it would head another way.
				if goal == Vector3.INF and main.off_navmesh(p, 1) < 0.2 and _flat(p, e_pos) > d - 0.5 \
						and _walks_straight(e_pos, p) \
						and (way == "side" or _flat(p, start) > _flat(e_pos, start) + 1.0):
					goal = p
		if goal == Vector3.INF:
			check(false, "a straight %s walk to test" % way)
			continue
		var e: Node = main.SOLDIER_SCENE.instantiate()
		e.kind = "soldier"
		e.position = e_pos + Vector3.UP * 0.1
		e.rotation.y = atan2(-to_player.x, -to_player.z)
		main.enemies.add_child(e)
		await frames(2)
		e.cover = {"pos": goal, "peek": goal, "normal": -to_player, "object": "test", "low": false, "eye": Cfg.EYE_HEIGHT, "owner": e}
		e._peeks_left = 2
		e._go(Tactical.Tac.RETURN)
		e._seen_time = 0.0
		var frames_ok := 0
		var facing := true
		for i in 90:
			await frames(1)
			if e.tac != Tactical.Tac.RETURN or e.state != e.State.CHASE:
				break
			var bl: Vector3 = e.anim_blend()
			var v := Vector2(e.velocity.x, e.velocity.z).length()
			if v > 0.6 and ((way == "side" and absf(bl.x) > 0.5) or (way == "back" and bl.y < -0.5)):
				frames_ok += 1
			var fwd: Vector3 = -e.global_basis.z
			var look: Vector3 = (player.global_position - e.global_position) * Vector3(1, 0, 1)
			if i > 20 and v > 0.6 and fwd.dot(look.normalized()) < cos(deg_to_rad(25.0)):
				facing = false
		check(frames_ok > 15 and facing, "moving %s in combat it faces the player (%s clip, %d frames)" %
				[way, "strafe" if way == "side" else "walk back", frames_ok])
		e.queue_free()
		await frames(2)
	player.invincible = false


# Best wave (stars) and the best score go to "combat_<map>", not the map's zombie entry.
func _test_saved_apart() -> void:
	var key := "combat_" + map_id
	var zombie_wave: int = progress.best_wave.get(map_id, 0)
	progress.on_wave_started(15)
	check(progress.stars(key) == 3 and progress.best_wave.get(map_id, 0) == zombie_wave,
			"stars count for Combat on this map only")
	var settings: Node = root.get_node("Settings")
	var zombie_best: int = settings.best_score_for(map_id)
	settings.submit_score(4321, 15, main.map_id)
	check(settings.best_score_for(key) >= 4321 and settings.best_score_for(map_id) == zombie_best,
			"the best score is saved for Combat on this map only")
	var reach := {"id": "reach", "type": "reach_wave", "kind": "", "map": map_id, "text": "t", "target": 99,
			"reward": 1, "progress": 0, "done": false}
	var reach_combat := reach.duplicate()
	reach_combat.map = key
	progress.daily.missions.append(reach)
	progress.daily.missions.append(reach_combat)
	progress.on_wave_started(16)
	check(reach_combat.progress == 16 and reach.progress == 0, "a Combat 'reach wave' mission counts in Combat only")
	progress.daily.missions.erase(reach)
	progress.daily.missions.erase(reach_combat)


func _backup_saves() -> void:
	for path: String in ["user://settings.cfg", "user://save.cfg"]:
		_backup[path] = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else null


func _restore_saves() -> void:
	for path: String in _backup:
		if _backup[path] == null:
			DirAccess.remove_absolute(path)
		else:
			var f := FileAccess.open(path, FileAccess.WRITE)
			f.store_buffer(_backup[path])
