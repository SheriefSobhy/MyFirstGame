extends SceneTree
## Automated check of the Training Arena (training/training.gd):
##   godot --headless --path . --script res://tools/test_training.gd
## Prints PASS/FAIL per check and exits with code 1 if anything failed.
## With `-- --shots <folder>` (and without --headless) it also saves
## screenshots: the hall, the range, the dummies, the panel.
##
## Main menu Training button -> loading screen -> the arena; every weapon,
## unlimited ammo and grenades, no damage; targets (paper, steel, moving,
## pop-up), dummies that never attack and come back, stats, the weapon rack,
## the training panel, the three challenges and their saved bests, and that
## nothing is earned (no XP, coins, missions, achievements or best scores).

const Config := preload("res://training_config.gd")
const Weapons := preload("res://weapon_stats.gd")
const Maps := preload("res://maps.gd")

var failures := 0
var shots_dir := ""
var main: Node
var player: Node
var hud: Node
var ui: Node
var _backup := {}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--shots")
	if i >= 0 and i + 1 < args.size():
		shots_dir = args[i + 1]
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		failures += 1


func frames(n: int) -> void:
	for i in n:
		await physics_frame
		await process_frame  # scene changes finish at the end of a process frame


func seconds(t: float) -> void:
	await create_timer(t, true, true).timeout


func _run() -> void:
	_backup_saves()
	var settings: Node = root.get_node("Settings")
	var progress: Node = root.get_node("Progress")
	settings.clear_bests()
	# A level-1 player: training needs no unlocks.
	progress.xp = 0
	var before := _progress_snapshot(progress)

	await _test_menu_button()
	if main == null:
		_finish()
		return
	await _test_start_state()
	await _test_static_targets()
	await _test_moving_targets()
	await _test_dummies()
	await _test_stats()
	await _test_rack()
	await _test_options()
	await _test_panel()
	await _test_target_practice()
	await _test_reflex()
	await _test_headshot_challenge()

	check(_progress_snapshot(progress) == before, "nothing earned: XP, coins, stats, missions, achievements unchanged")
	check(not progress.in_match(), "training is never a match (Progress.in_match false)")
	check(not settings.bests.has("training"), "no best score for the arena")
	await _test_exit()
	_finish()


func _finish() -> void:
	_restore_saves()
	print("\n%s: %d failure(s)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _progress_snapshot(p: Node) -> String:
	return var_to_str([p.xp, p.coins, p.stats, p.daily, p.achievements, p.best_wave, p.maps_played])


# --- Getting there ---------------------------------------------------------------

func _test_menu_button() -> void:
	change_scene_to_file("res://ui/main_menu.tscn")
	await frames(3)
	var menu := current_scene
	var login: Control = menu.get("login_popup")
	if login:
		login.visible = false
	var button: Button = menu.get_node_or_null("%TrainingButton")
	check(button != null and button.visible and not button.disabled, "main menu has a Training button")
	check(Maps.TRAINING.scene == "res://maps/training.tscn" and not Maps.TRAINING in Maps.LIST,
			"the arena is not on the map selection screen")
	if button == null:
		return
	button.pressed.emit()
	for i in 600:
		await frames(1)
		if current_scene and current_scene.name == "Main":
			break
	main = current_scene
	check(main != null and main.name == "Main" and main.get_script().resource_path == "res://training/training.gd",
			"Training goes through the loading screen into the arena")
	if main == null or main.name != "Main":
		main = null
		return
	await frames(5)
	player = main.player
	hud = main.hud
	ui = main.ui
	await _screenshot("training_hall")


func _test_start_state() -> void:
	var all := true
	for i in Weapons.LIST.size():
		all = all and player.has_weapon(i)
	check(all, "every weapon available at level 1")
	check(player.infinite_ammo and player.reserve() == -1, "unlimited ammo on at the start")
	check(player.infinite_grenades and player.grenades > 0, "infinite grenades on at the start")
	var hp: int = player.health
	player.take_damage(50)
	check(player.health == hp and not player.is_dead, "the player can't be hurt in training")
	check(ui != null and ui.stats_label.visible, "hit stats on screen")
	check(main.targets.size() == 4 * 3 + 2 + Config.POPUPS.size(), "targets: paper + 2 steel per distance, 2 moving, pop-ups (%d)" % main.targets.size())
	check(main.popups.size() == Config.POPUPS.size(), "pop-up targets for the challenges")
	var kinds := {}
	for d in main.live_dummies():
		kinds[d.kind] = d.dummy
	check(kinds.size() == 6 and not (false in kinds.values()), "a dummy of every enemy type (%s)" % ", ".join(kinds.keys()))
	check(not hud.score_label.visible and not hud.cash_label.visible, "no score or cash in training")
	check(main.get_node_or_null("LightmapGI") != null, "the arena has a LightmapGI")
	var lm: LightmapGI = main.get_node("LightmapGI")
	check(lm.light_data != null, "the arena's lightmap is baked")
	for i in 600:
		if main.navmesh_ready():
			break
		await frames(1)
	check(main.navmesh_ready(), "the arena's navmeshes are ready")


# --- Targets ---------------------------------------------------------------------

func _target(n: String) -> Node:
	return main.get_node("Targets/" + n)


func _test_static_targets() -> void:
	var paper := _target("Paper10")
	_put_player(Vector3(Config.paper_x(10), 0, -1.5))
	await _shoot_at(paper.aim_point())
	check(paper.hits == 1, "paper target at 10 m takes a hit")
	check(paper.is_up and paper.hp > 0, "paper targets stay up")
	check(hud.feedback.numbers_showing() > 0, "damage number shown on a target")
	var head: int = main.headshots
	await _shoot_at(paper.head_point())
	check(main.headshots == head + 1, "the silhouette's head counts as a headshot")

	var plate := _target("Metal10_0")
	_put_player(Vector3(Config.metal_x(10)[0], 0, -1.5))
	await _shoot_at(plate.aim_point())
	check(plate.hits == 1 and not plate.is_up, "steel plate falls when hit")
	await seconds(0.3)
	await _shoot_at(plate.aim_point())
	check(plate.hits == 1, "a fallen plate can't be hit")
	await seconds(Config.METAL_RESET)
	check(plate.is_up, "steel plate stands up again after %.0f s" % Config.METAL_RESET)

	for d: int in Config.DISTANCES:
		var t := _target("Paper%d" % d)
		check(absf(t.global_position.z + d) < 0.01, "paper target at %d m" % d)
	var far := _target("Paper100")
	_put_player(Vector3(Config.paper_x(100), 0, -1.5))
	await _shoot_at(far.aim_point())
	check(far.hits == 1, "100 m paper target can be hit (pistol)")
	await _screenshot("training_range")


func _test_moving_targets() -> void:
	var m := _target("Mover30")
	var x0: float = m.global_position.x
	await seconds(0.5)
	check(absf(m.global_position.x - x0) > 0.3, "moving target slides sideways")
	var half: float = Config.MOVERS[0][1]
	check(absf(m.global_position.x - Config.MOVER_X) <= half + 0.01, "moving target stays on its rail")


# --- Dummies ---------------------------------------------------------------------

func _dummy(kind: String) -> Node:
	for d in main.live_dummies():
		if d.kind == kind and d.position.distance_to(_home(kind)) < Config.DUMMY_PATROL + 1.0:
			return d
	return null


func _home(kind: String) -> Vector3:
	var h: Vector2 = Config.DUMMY_HOMES[kind]
	return Vector3(h.x, 0, h.y)


func _test_dummies() -> void:
	# Right next to the player for a while: no attack, no damage, no explosion.
	var zombie := _dummy("normal")
	var exploder := _dummy("exploder")
	_put_player(_home("normal") + Vector3(0, 0, 1.2))
	player.rotation.y = 0.0
	var attacked := false
	for i in 90:
		await frames(1)
		for d in main.live_dummies():
			attacked = attacked or d.state == d.State.ATTACK or d.state == d.State.ARMED or d.state == d.State.AIM
	check(not attacked, "dummies never attack, aim or arm")
	var p0: Vector3 = zombie.global_position
	check(not zombie.is_trying_to_move(), "dummies stand still by default")

	main.set_dummies_walk(true)
	await seconds(1.5)
	var moved: float = zombie.global_position.distance_to(p0)
	check(moved > 0.5, "dummies walk when walking is on (%.2f m)" % moved)
	var speed: float = Vector2(zombie.velocity.x, zombie.velocity.z).length()
	check(speed <= Config.DUMMY_SPEED * 1.3, "walking dummies are slow (%.2f m/s)" % speed)
	main.set_dummies_walk(false)
	await frames(3)

	# Killed: no blast, back after DUMMY_RESPAWN.
	var hp: int = player.health
	exploder.take_damage(999, exploder.global_position + Vector3.UP, Vector3.BACK)
	await seconds(0.5)
	check(not exploder.has_exploded() and player.health == hp, "a killed exploder dummy doesn't blow up")
	check(main.live_dummies().size() == 5, "a killed dummy is gone")
	await seconds(Config.DUMMY_RESPAWN)
	check(main.live_dummies().size() == 6 and _dummy("exploder") != null, "the dummy stands up again at its spot")

	# Head zones.
	main.set_show_zones(true)
	await frames(2)
	check(main._zones.size() == 6, "head zones shown on every dummy")
	var boss := _dummy("boss")
	var zone: Node3D = main._zones.get(boss)
	var head: Dictionary = boss.head_sphere()
	check(zone != null and zone.global_position.distance_to(head.center) < 0.01, "a head zone sits on the head hitbox")
	_put_player(_home("normal") + Vector3(0, 0, 8.0))
	await frames(2)
	await _screenshot("training_dummies")
	main.set_show_zones(false)
	await frames(1)
	check(main._zones.is_empty(), "head zones hidden again")

	# Spawning from the panel, up to the cap, and removing them.
	for kind: String in Config.DUMMY_KINDS:
		(ui.panel.find_child("Spawn_" + kind, true, false) as Button).pressed.emit()
	await frames(2)
	check(main.live_dummies().size() == 12, "panel spawns a dummy of each type (%d)" % main.live_dummies().size())
	check(main.spawn_dummy_random("normal") == null, "at most %d dummies" % Config.MAX_DUMMIES)
	main.clear_spawned_dummies()
	await frames(2)
	check(main.live_dummies().size() == 6, "Remove spawned dummies keeps the six")

	# Dummies get headshots like enemies.
	var z := _dummy("brute")
	_put_player(_home("brute") + Vector3(0, 0, 6.0))
	main.reset_stats()
	await _shoot_at(z.head_sphere().center)
	check(main.headshots == 1 and main.hits == 1, "headshot on a dummy counted")
	check(hud.feedback.numbers_showing() > 0, "damage numbers on dummies")


# --- Stats, rack, options ----------------------------------------------------------

func _test_stats() -> void:
	main.reset_stats()
	var paper := _target("Paper10")
	_put_player(Vector3(Config.paper_x(10), 0, -1.5))
	for i in 3:
		await _shoot_at(paper.aim_point())
	await _shoot_at(paper.aim_point() + Vector3(3.0, 2.0, 0))  # a miss
	check(main.shots == 4 and main.hits == 3, "shots and hits counted (%d / %d)" % [main.hits, main.shots])
	check(roundi(main.accuracy()) == 75, "accuracy 75%% (%.1f)" % main.accuracy())
	check(main.headshot_share() == 0.0, "no headshots: 0%")
	check(main.last_dps > 0.0, "DPS on the last target (%.0f)" % main.last_dps)
	ui.update_stats()
	check("Accuracy 75%" in ui.stats_label.text and "DPS" in ui.stats_label.text, "stats on screen: %s" % ui.stats_label.text.replace("\n", " | "))
	# Shotgun: one shot is one hit, however many pellets land.
	main.reset_stats()
	player.switch_to(2)
	await seconds(0.5)
	await _shoot_at(paper.aim_point())
	check(main.shots == 1 and main.hits == 1, "a shotgun blast counts as one shot, one hit")
	player.switch_to(0)
	await seconds(0.5)


func _test_rack() -> void:
	var rack: Node3D = main.rack
	_put_player(Vector3(0, 0, 4.0))
	await frames(2)
	check(ui.take_index == -1 and not ui.take_button.visible, "no TAKE button away from the rack")
	var slot := 4  # SMG
	_put_player(rack.slot_position(slot) + Vector3(0, 0, -0.3))
	await frames(3)
	check(ui.take_index == slot and ui.take_button.visible, "TAKE button at the rack (%s)" % ui.take_button.text)
	ui.take_button.pressed.emit()
	await seconds(0.6)
	check(player.weapon_index == slot, "taking a gun from the rack switches to it")
	_press_key(KEY_E)  # same gun again: nothing breaks
	await frames(2)
	_put_player(rack.slot_position(1) + Vector3(0, 0, -0.3))
	await frames(3)
	_press_key(KEY_E)
	await seconds(0.6)
	check(player.weapon_index == 1, "E takes the gun in reach")
	check(rack.get_child_count() > Weapons.LIST.size() * 2, "a model and a name on every rack slot")
	_put_player(Vector3(1.5, 0, 7.5))
	player.rotation.y = PI * 0.95
	player.head.rotation.x = 0.1
	await _screenshot("training_rack")
	player.switch_to(0)
	await seconds(0.5)


func _test_options() -> void:
	main.set_infinite_ammo(false)
	check(player.reserve() == Weapons.LIST[0].max_reserve and player._reserve[1] == Weapons.LIST[1].max_reserve,
			"unlimited ammo off: normal spare ammo")
	main.set_infinite_ammo(true)
	check(player._reserve[1] == -1, "unlimited ammo on again")
	var g: int = player.grenades
	player.start_grenade()
	player.throw_grenade()
	check(player.grenades == g, "infinite grenades: throwing keeps the count")
	main.set_infinite_grenades(false)
	await seconds(1.0)
	player.start_grenade()
	player.throw_grenade()
	check(player.grenades == g - 1, "infinite grenades off: a throw uses one")
	main.set_infinite_grenades(true)
	# Reset targets: plates up, holes gone.
	var plate := _target("Metal25_0")
	plate.take_damage(1, plate.aim_point(), Vector3.BACK)
	check(not plate.is_up, "plate down before the reset")
	(ui.panel.find_child("ResetTargets", true, false) as Button).pressed.emit()
	await frames(2)
	check(plate.is_up and plate.hits == 0, "Reset targets stands everything up")


func _test_panel() -> void:
	_press_key(KEY_T)
	await frames(3)
	check(ui.panel.visible and paused, "T opens the training panel and pauses")
	check(not ui.train_button.visible, "TRAIN button hidden while the panel is open")
	for id: String in Config.CHALLENGES:
		check(ui.challenge_buttons[id].text.begins_with(Config.CHALLENGES[id].name), "panel lists %s" % Config.CHALLENGES[id].name)
	await _screenshot("training_panel")
	(ui.panel.find_child("Resume", true, false) as Button).pressed.emit()
	await frames(2)
	check(not ui.panel.visible and not paused, "Resume closes the panel")
	ui.train_button.pressed.emit()
	await frames(2)
	check(ui.panel.visible and paused, "the TRAIN button opens the panel")
	var walk: CheckButton = ui.toggles.walk
	walk.button_pressed = true
	check(main.dummies_walk, "panel toggle: dummies walk")
	walk.button_pressed = false
	var stats: CheckButton = ui.toggles.stats
	stats.button_pressed = false
	check(not ui.stats_label.visible, "panel toggle: hide hit stats")
	stats.button_pressed = true
	ui.close_panel()
	await frames(2)


# --- Challenges --------------------------------------------------------------------

func _wait_countdown() -> void:
	for i in 400:
		if main.challenge_phase == "run":
			return
		await frames(1)


func _test_target_practice() -> void:
	(ui.panel.find_child("Challenge_targets", true, false) as Button).pressed.emit()
	await frames(2)
	check(main.challenge == "targets" and main.challenge_phase == "countdown", "Target Practice starts with a countdown")
	await _wait_countdown()
	_put_player(Vector3(Config.MOVER_X, 0, -1.5))
	var n: int = Config.CHALLENGES.targets.count
	for i in n * 3:
		if main.challenge != "targets":
			break
		var t: Node = main._ch_current
		if t == null:
			await frames(1)
			continue
		if i == 0:
			check(t.is_up, "the first pop-up is up")
		await _shoot_at(t.aim_point())
	check(main.last_result.get("id") == "targets", "Target Practice finishes after %d hits" % n)
	var best: float = root.get_node("Settings").training_best("targets")
	check(best > 0.0 and absf(best - main.last_result.get("value", -1.0)) < 0.001, "best time saved (%.1f s)" % best)
	check(_saved("targets") > 0.0, "best time written to save.cfg")
	var all_down := true
	for p in main.popups:
		all_down = all_down and not p.is_up
	check(all_down, "pop-ups go down after the challenge")


func _test_reflex() -> void:
	main.start_challenge("reflex")
	Engine.time_scale = 2.0
	await _wait_countdown()
	_put_player(Vector3(Config.MOVER_X, 0, -1.5))
	var hit_some := 0
	var miss_some := 0
	var c: Dictionary = Config.CHALLENGES.reflex
	var seen := {}
	var max_up := 0.0
	var up_since := {}
	for i in 20000:
		if main.challenge != "reflex":
			break
		var t: Node = main._ch_current
		if t != null and t.is_up:
			if not up_since.has(t.get_instance_id() + main.challenge_spawned * 1000):
				up_since[t.get_instance_id() + main.challenge_spawned * 1000] = main.challenge_time
			seen[main.challenge_spawned] = true
			# Hit every other one; let the rest time out.
			if main.challenge_spawned % 2 == 0:
				await _shoot_at(t.aim_point())
				hit_some += 1
			else:
				miss_some += 1
				while main._ch_current == t and main.challenge == "reflex":
					await frames(1)
				max_up = maxf(max_up, main.challenge_time - up_since[t.get_instance_id() + main.challenge_spawned * 1000])
		await frames(1)
	Engine.time_scale = 1.0
	check(main.last_result.get("id") == "reflex", "Reflex finishes after %d targets" % c.count)
	check(main.challenge_spawned == c.count and seen.size() >= c.count - 2, "Reflex shows %d targets (%d, %d seen)" % [c.count, main.challenge_spawned, seen.size()])
	check(max_up <= c.up_time + 0.35, "a Reflex target stays up about %.0f s (%.2f)" % [c.up_time, max_up])
	var acc: float = main.last_result.get("value", -1.0)
	check(acc > 30.0 and acc < 70.0, "Reflex accuracy from hits / %d (%.0f%%)" % [c.count, acc])
	check(absf(root.get_node("Settings").training_best("reflex") - acc) < 0.001, "best accuracy saved")


func _test_headshot_challenge() -> void:
	main.start_challenge("headshots")
	await _wait_countdown()
	check(main.dummies_walk, "dummies walk during the Headshot Challenge")
	var z := _dummy("brute")
	_put_player(z.global_position + Vector3(0, 0, 6.0))
	for i in 2:
		z = _dummy("brute") if _dummy("brute") else z
		if z == null or z.state == z.State.DEAD:
			break
		await _shoot_at(z.head_sphere().center)
	var got: int = main.challenge_count
	check(got >= 1, "headshots on walking dummies count (%d)" % got)
	# Run out the clock.
	Engine.time_scale = 8.0
	for i in 3000:
		if main.challenge != "headshots":
			break
		await frames(1)
	Engine.time_scale = 1.0
	check(main.last_result.get("id") == "headshots" and int(main.last_result.value) == got,
			"the Headshot Challenge ends after %.0f s with the count" % Config.CHALLENGES.headshots.time)
	check(root.get_node("Settings").training_best("headshots") == float(got), "best headshot score saved")
	check(not main.dummies_walk, "dummies stand still again afterwards")
	# A worse run doesn't replace the best.
	check(not root.get_node("Settings").submit_training("headshots", got - 1, false), "a lower score is not a new best")
	# Stop mid-way: no result.
	main.start_challenge("targets")
	await frames(2)
	main.stop_challenge()
	check(main.challenge == "", "a challenge can be stopped")


func _test_exit() -> void:
	ui.open_panel()
	await frames(2)
	(ui.panel.find_child("Exit", true, false) as Button).pressed.emit()
	for i in 60:
		await frames(1)
		if current_scene and current_scene.name == "MainMenu":
			break
	check(current_scene != null and current_scene.name == "MainMenu" and not paused, "Exit goes back to the main menu")


# --- Helpers -----------------------------------------------------------------------

func _saved(id: String) -> float:
	var cfg := ConfigFile.new()
	if cfg.load("user://save.cfg") != OK:
		return -1.0
	return float(cfg.get_value("training", id, -1.0))


func _put_player(pos: Vector3) -> void:
	player.global_position = pos
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0
	player.head.rotation.x = 0.0


## Turns the view at `point` and fires once (when the gun is ready).
func _shoot_at(point: Vector3) -> void:
	while player._fire_cooldown > 0.0 or player.is_reloading() or player._switching:
		await physics_frame
	var cam: Camera3D = player.camera
	for i in 2:  # twice: turning the body moves the camera a little
		var to := point - cam.global_position
		player.rotation.y = atan2(-to.x, -to.z)
		player.head.rotation.x = atan2(to.y, Vector2(to.x, to.z).length())
		await physics_frame
	player._spread = 0.0
	player.touch_shoot = true
	await physics_frame
	player.touch_shoot = false
	await frames(2)


func _press_key(key: Key) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = key
	ev.keycode = key
	ev.pressed = true
	Input.parse_input_event(ev)
	var up := ev.duplicate()
	up.pressed = false
	Input.parse_input_event(up)


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
	var settings: Node = root.get_node("Settings")
	settings.clear_bests()
	settings._load()


func _screenshot(file_name: String) -> void:
	if shots_dir == "":
		return
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	img.save_png(shots_dir.path_join(file_name + ".png"))
	print("saved ", file_name)
