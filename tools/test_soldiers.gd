extends SceneTree
## Automated check of the Soldiers (Test) mode (soldiers/):
##   godot --headless --path . --script res://tools/test_soldiers.gd
## Prints PASS/FAIL per check and exits with code 1 if anything failed.
##
## Main menu button -> loading screen -> the Yard with soldiers only; waves
## of 3, +1, at most 8 at once; cover points on the navmesh behind the tall
## objects; soldiers take cover, burst-fire (tracer, flash, sound), leave a
## cover the player flanks; accuracy falls with distance and movement;
## headshots, hit reactions, death and rewards; the damage direction
## indicator and health regen. The zombie mode keeps its own waves.

const Cfg := preload("res://soldiers/soldiers_config.gd")
var Tactical: GDScript
var Mode: GDScript
var Zombies: GDScript
const Maps := preload("res://maps.gd")

var failures := 0
var main: Node
var player: Node
var _backup := {}


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
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
	_backup_saves()
	await _test_menu_button()
	if main == null:
		_finish()
		return
	_test_setup()
	await _test_spawns_and_cover()
	await _test_burst()
	await _test_flank()
	_test_accuracy()
	await _test_hits_and_death()
	await _test_regen()
	_finish()


func _finish() -> void:
	_restore_saves()
	print("\n%s: %d failure(s)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _test_menu_button() -> void:
	change_scene_to_file("res://ui/main_menu.tscn")
	await frames(3)
	var menu := current_scene
	var login: Control = menu.get("login_popup")
	if login:
		login.visible = false
	var button: Button = menu.get("soldiers_button")
	check(button != null and button.visible and button.text == "Soldiers (Test)", "main menu has a Soldiers (Test) button")
	if button == null:
		return
	button.pressed.emit()
	for i in 600:
		await frames(1)
		if current_scene and current_scene.name == "Main":
			break
	main = current_scene
	check(main != null and main.get_script() == Mode, "the button goes through the loading screen into the mode")
	if main == null or main.get_script() != Mode:
		main = null
		return
	player = main.player
	player.invincible = true  # until the regen check
	main.revives_left = 0
	await frames(5)


func _test_setup() -> void:
	check(main.has_node("NavigationRegion3D/Level/ContainerRed") and main.has_node("NavigationRegion3D/Level/Warehouse"),
			"the map is the Industrial Yard")
	check(main.map_id == "soldiers", "scores are saved under 'soldiers', not the Yard's")
	check(Mode.soldiers_in_wave(1) == 3 and Mode.soldiers_in_wave(2) == 4 and Mode.soldiers_in_wave(6) == 8,
			"waves: 3 soldiers, +1 each wave")
	check(main.max_enemies == 8 and Cfg.MAX_ALIVE == 8, "at most 8 soldiers at once")
	var yard: Node = load("res://main.tscn").instantiate()
	check(Zombies.wave_kinds(1).has("normal") and yard.get_script() == Zombies,
			"the zombie mode keeps main.gd and its zombie waves")
	yard.free()


func _soldiers() -> Array:
	return main.enemies.get_children().filter(func(e: Node) -> bool: return e.state != e.State.DEAD)


func _test_spawns_and_cover() -> void:
	for i in 600:
		await frames(1)
		if _soldiers().size() >= 3:
			break
	var s := _soldiers()
	check(s.size() == 3, "wave 1 spawns 3 soldiers (%d)" % s.size())
	check(s.all(func(e: Node) -> bool: return e.get_script() == Tactical and e.kind == "soldier"),
			"every enemy is the Mixamo soldier with the cover AI")
	var points: Array = main.get_cover_points()
	check(points.size() >= 12, "cover points round the containers, warehouse and crates (%d)" % points.size())
	var space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
	var backed := 0
	for c: Dictionary in points:
		var eye: Vector3 = c.pos + Vector3.UP * Cfg.EYE_HEIGHT
		var q := PhysicsRayQueryParameters3D.create(eye, eye - (c.normal as Vector3) * 2.5, 1)
		if not space.intersect_ray(q).is_empty():
			backed += 1
	check(backed == points.size(), "each cover point has its object behind it at eye height (%d/%d)" % [backed, points.size()])
	var hidden: Node = null
	for i in 900:
		await frames(1)
		for e: Node in _soldiers():
			if e.tac == Tactical.Tac.HIDE:
				hidden = e
		if hidden:
			break
	check(hidden != null, "soldiers move to cover and hide")
	if hidden:
		check(not hidden._exposed_at(hidden.cover.pos), "hidden: the player can't see the soldier at its cover")
		var claimed := points.filter(func(c: Dictionary) -> bool: return c.owner == hidden)
		check(claimed.size() == 1, "the soldier holds one cover point")


func _test_burst() -> void:
	var seen_fx := false
	var seen_sound := false
	var seen_indicator := false
	var burst_ok := false
	var shooter: Node = null
	for i in 1500:
		await frames(1)
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
	check(burst_ok, "soldiers peek out and fire bursts of %d+ shots" % Cfg.BURST.x)
	check(seen_fx, "tracers and muzzle flash show")
	check(seen_sound, "gunshot sound plays")
	check(seen_indicator, "a hit on the player shows the damage direction indicator")
	if shooter:
		await frames(30)
		check(shooter.tac == Tactical.Tac.RETURN or shooter.tac == Tactical.Tac.HIDE or shooter.tac == Tactical.Tac.FIND \
				or shooter.tac == Tactical.Tac.MOVE or shooter.tac == Tactical.Tac.PEEK,
				"after a burst the soldier goes back behind cover (or to a new one)")
	var ind: Node = main.indicator
	var cam: Camera3D = player.camera
	var ahead: float = ind.angle_to(cam.global_position - cam.global_basis.z * 5.0)
	var right: float = ind.angle_to(cam.global_position + cam.global_basis.x * 5.0)
	var behind: float = ind.angle_to(cam.global_position + cam.global_basis.z * 5.0)
	check(ind.size.x > 600.0 and absf(ahead) < 0.05 and absf(right - PI / 2.0) < 0.05 and absf(absf(behind) - PI) < 0.05,
			"the indicator covers the screen and points ahead / right / behind correctly")


func _test_flank() -> void:
	# A hiding soldier with open ground 6 m out on its side of the cover.
	var s: Node = null
	var spot := Vector3.ZERO
	for i in 1200:
		await frames(1)
		for e: Node in _soldiers():
			if e.tac != Tactical.Tac.HIDE:
				continue
			var n: Vector3 = e.cover.normal
			var t := n.cross(Vector3.UP)
			for off: Vector3 in [n * 6.0, n * 4.0 + t * 3.0, n * 4.0 - t * 3.0, n * 2.5 + t * 5.0, n * 2.5 - t * 5.0]:
				var p: Vector3 = e.cover.pos + off
				if absf(p.x) < 11.0 and absf(p.z) < 11.0 and main.off_navmesh(p, 1) < 0.2:
					s = e
					spot = p
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
	if not moved:
		print("  debug: soldier %s tac %d state %d cover %s player %s exposed %s" % [s.global_position, s.tac, s.state,
				c, player.global_position, s._exposed_at(c.pos)])
	check(moved, "a flanked soldier leaves its cover for another")
	player.global_position = Vector3(0, 0.1, 8)


func _test_accuracy() -> void:
	var near: float = Tactical.hit_chance(5.0, 0.0)
	var mid: float = Tactical.hit_chance(15.0, 0.0)
	var far: float = Tactical.hit_chance(28.0, 0.0)
	var moving: float = Tactical.hit_chance(15.0, 5.0)
	check(near > mid and mid > far and far > 0.0, "accuracy drops with distance (%.2f / %.2f / %.2f)" % [near, mid, far])
	check(moving < mid * 0.6, "accuracy drops when the player moves (%.2f vs %.2f)" % [moving, mid])


func _test_hits_and_death() -> void:
	var list := _soldiers()
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
	var kills: int = main.kills
	var cash: int = main.economy.cash
	var progress: Node = root.get_node("Progress")
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
