extends SceneTree
## Mobile and first-impression features: the first-match tutorial, Customize
## Controls (move / resize / opacity / reset), left-handed mirroring, Auto
## graphics quality, the 30/60 FPS cap, the revive ("Watch ad to revive")
## and the loading screen.
##   godot --headless --path . --script res://tools/test_mobile.gd
## Prints PASS/FAIL per check and exits with code 1 if anything failed.
## Your saved settings and best scores are backed up and restored afterwards.

# Loaded at run time: these use the autoloads, which a tool script's
# preloads would compile before.
var AutoQuality: GDScript
var LoadingScreen: GDScript
const Maps := preload("res://maps.gd")
const Economy := preload("res://economy.gd")
var TOUCH_SCENE: PackedScene

var failures := 0
var settings: Node
var _backup := {}


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		failures += 1


func frames(n: int) -> void:
	for i in n:
		await process_frame


func seconds(s: float) -> void:
	await create_timer(s, true).timeout


func _run() -> void:
	_backup_saves()
	settings = root.get_node("Settings")
	AutoQuality = load("res://auto_quality.gd")
	LoadingScreen = load("res://ui/loading_screen.gd")
	TOUCH_SCENE = load("res://touch_controls.tscn")
	settings.clear_bests()
	_test_settings()
	await _test_auto_quality()
	await _test_touch_layout()
	await _test_settings_menu()
	await _test_tutorial()
	await _test_revive()
	await _test_loading_screen()
	_restore_saves()
	print("\n%s: %d failure(s)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _test_settings() -> void:
	print("--- Settings")
	check(settings.tutorial_done, "tests start with the tutorial off")
	check(settings.touch_layout.is_empty() and not settings.left_handed and settings.touch_opacity == 1.0,
			"tests start with the default touch layout")
	check(Engine.max_fps == 0, "no frame rate cap in headless runs")
	settings.set_value("quality", settings.Quality.HIGH)
	settings.auto_quality = settings.Quality.LOW
	settings.set_value("quality", settings.Quality.AUTO)
	check(settings.auto_quality == -1, "choosing Auto again measures again")
	check(settings.effective_quality() == settings.Quality.HIGH, "Auto before measuring: High on a computer")
	settings.auto_quality = settings.Quality.MEDIUM
	check(settings.effective_quality() == settings.Quality.MEDIUM, "Auto uses what it picked")
	settings.set_value("quality", settings.Quality.LOW)
	check(settings.effective_quality() == settings.Quality.LOW, "a fixed quality is used as is")

	settings.set_value("fps_cap", 30)
	settings.set_value("left_handed", true)
	settings.set_value("touch_opacity", 0.5)
	settings.set_button_layout("shoot", Vector2(-200, -150), 1.3)
	settings.set_value("quality", settings.Quality.AUTO)
	settings.auto_quality = settings.Quality.MEDIUM
	settings.save_settings()
	var cfg := ConfigFile.new()
	check(cfg.load(settings.SETTINGS_PATH) == OK and cfg.get_value("graphics", "fps_cap") == 30
			and cfg.get_value("controls", "left_handed") == true
			and is_equal_approx(cfg.get_value("controls", "touch_opacity"), 0.5)
			and cfg.get_value("graphics", "quality") == settings.Quality.AUTO
			and cfg.get_value("graphics", "auto_quality") == settings.Quality.MEDIUM
			and cfg.get_value("controls", "touch_layout").shoot.pos == Vector2(-200, -150),
			"new settings are saved")
	settings.fps_cap = 60
	settings.auto_quality = -1
	settings._load()
	check(settings.fps_cap == 30 and settings.auto_quality == settings.Quality.MEDIUM, "and load back")
	settings.set_button_layout("jump", Vector2(10, 10), 99.0)
	check(settings.button_layout("jump").scale == settings.MAX_BUTTON_SCALE, "button size is clamped")
	settings.reset_touch_layout()
	settings.left_handed = false
	settings.set_value("fps_cap", 60)
	check(settings.touch_layout.is_empty() and settings.touch_opacity == 1.0, "reset touch layout")


func _test_auto_quality() -> void:
	print("--- Auto quality")
	var Q: Dictionary = settings.Quality
	check(AutoQuality.pick(59.0, Q.HIGH) == Q.HIGH, "High at ~60 FPS stays High")
	check(AutoQuality.pick(40.0, Q.HIGH) == Q.MEDIUM, "High at 40 FPS: Medium")
	check(AutoQuality.pick(25.0, Q.HIGH) == Q.LOW, "High at 25 FPS: Low")
	check(AutoQuality.pick(60.0, Q.MEDIUM) == Q.HIGH, "Medium at 60 FPS: High")
	check(AutoQuality.pick(45.0, Q.MEDIUM) == Q.MEDIUM, "Medium at 45 FPS stays Medium")
	check(AutoQuality.pick(30.0, Q.MEDIUM) == Q.LOW, "Medium at 30 FPS: Low")
	check(AutoQuality.pick(60.0, Q.LOW) == Q.MEDIUM and AutoQuality.pick(40.0, Q.LOW) == Q.LOW,
			"Low: at most Medium")
	# A short measurement (headless runs as fast as it can: High).
	settings.set_value("quality", Q.HIGH)
	settings.set_value("quality", Q.AUTO)
	var aq: Node = AutoQuality.new()
	aq.warmup = 0.05
	aq.measure_time = 0.3
	var got := [-1]
	var fps := [0.0]
	aq.picked.connect(func(q: int) -> void:
		got[0] = q
		fps[0] = aq.average_fps())
	root.add_child(aq)
	await seconds(0.6)
	check(got[0] >= 0 and got[0] == AutoQuality.pick(fps[0], Q.HIGH) and settings.auto_quality == got[0]
			and not is_instance_valid(aq),
			"measuring picks from the frame rate and saves it (got %d at %.0f FPS)" % [got[0], fps[0]])
	settings.set_value("quality", Q.HIGH)


func _test_touch_layout() -> void:
	print("--- Touch layout")
	var touch: Control = TOUCH_SCENE.instantiate()
	touch.force_show = true
	root.add_child(touch)
	await frames(2)
	var size: Vector2 = touch.size
	check(size.x > 0 and touch._button_center("shoot") == size + touch.BUTTONS.shoot.offset, "default spot")
	touch.place_button("shoot", Vector2(300, 400), 1.4)
	check(touch._button_center("shoot").distance_to(Vector2(300, 400)) < 0.5, "a moved button is where it was put")
	check(is_equal_approx(touch._button_radius("shoot"), touch.BUTTONS.shoot.radius * 1.4), "and resized")
	check(settings.button_layout("shoot").pos.x > 0, "left half: saved from the left edge")
	touch.place_button("jump", Vector2(size.x - 250, 300), 1.0)
	check(settings.button_layout("jump").pos.x < 0, "right half: saved from the right edge")
	touch.place_button("reload", Vector2(-50, -50), 1.0)
	check(touch._button_center("reload").x >= touch._button_radius("reload") - 0.5, "buttons are kept on screen")

	settings.left_handed = true
	check(touch._button_center("shoot").distance_to(Vector2(size.x - 300, 400)) < 0.5, "left-handed mirrors the buttons")
	check(touch._joy_home().x > size.x * 0.5, "left-handed: joystick on the right")
	check(touch._button_at(Vector2(size.x - 300, 400)) == "shoot", "the mirrored button is pressed where it is drawn")
	touch.place_button("shoot", Vector2(size.x - 500, 400), 1.4)
	settings.left_handed = false
	check(touch._button_center("shoot").distance_to(Vector2(500, 400)) < 0.5, "moving while mirrored saves it unmirrored")

	settings.touch_opacity = 0.5
	check(is_equal_approx(touch._fade(Color(1, 1, 1, 0.6)).a, 0.3), "opacity fades the buttons")
	settings.reset_touch_layout()
	check(touch._button_center("shoot") == size + touch.BUTTONS.shoot.offset, "reset puts it back")
	touch.highlight = "shoot"
	check(touch.highlight == "shoot", "the tutorial can point at a button")
	touch.queue_free()


func _test_settings_menu() -> void:
	print("--- Settings screen and Customize Controls")
	change_scene_to_file("res://ui/main_menu.tscn")
	await frames(5)
	var sm: Control = current_scene.settings_menu
	sm.open()
	await frames(1)
	check(sm.quality_buttons.size() == 4 and sm.quality_buttons[3].text == "Auto", "Graphics has an Auto button")
	sm.quality_buttons[3].pressed.emit()
	check(settings.quality == settings.Quality.AUTO and sm.quality_hint.text.contains("next match"),
			"Auto: measured in the next match")
	sm.fps_buttons[0].pressed.emit()
	check(settings.fps_cap == 30, "30 FPS button")
	sm.fps_buttons[1].pressed.emit()
	check(settings.fps_cap == 60, "60 FPS button")
	sm.left_handed_button.toggled.emit(true)
	check(settings.left_handed, "Left-handed toggle")
	sm.left_handed_button.toggled.emit(false)
	check(sm.tutorial_button.text == "Replay Tutorial", "Replay Tutorial button")
	sm.tutorial_button.pressed.emit()
	check(not settings.tutorial_done and sm.tutorial_button.disabled, "Replay Tutorial plays it next match")
	settings.tutorial_done = true

	sm.customize_button.pressed.emit()
	await frames(2)
	var ed: Control = sm.controls_editor
	check(ed != null and ed.visible, "Customize Controls opens")
	var touch: Control = ed.touch
	check(touch.edit_mode and touch.visible, "the editor shows the buttons")
	var from: Vector2 = touch._button_center("jump")
	var to := Vector2(420, 380)
	ed._gui_input(_mouse_button(from, true))
	check(touch.edit_selected == "jump", "pressing a button selects it")
	ed._gui_input(_mouse_motion(to))
	ed._gui_input(_mouse_button(to, false))
	check(touch._button_center("jump").distance_to(to) < 1.0, "dragging moves it")
	ed.size_slider.value = 1.5
	check(is_equal_approx(settings.button_layout("jump").scale, 1.5), "the Size slider resizes the selected button")
	ed.opacity_slider.value = 0.4
	check(is_equal_approx(settings.touch_opacity, 0.4), "the Opacity slider")
	ed.done_button.pressed.emit()
	check(not ed.visible, "Done closes the editor")
	var cfg := ConfigFile.new()
	cfg.load(settings.SETTINGS_PATH)
	check(cfg.get_value("controls", "touch_layout", {}).has("jump"), "the layout is saved")
	sm.customize_button.pressed.emit()
	ed.reset_button.pressed.emit()
	check(settings.touch_layout.is_empty() and settings.touch_opacity == 1.0, "Reset to default")
	ed.done_button.pressed.emit()
	sm.close()


func _mouse_button(pos: Vector2, pressed: bool) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	return ev


func _mouse_motion(pos: Vector2) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	return ev


func _load_main() -> Node:
	change_scene_to_file("res://main.tscn")
	await frames(15)
	return current_scene


func _test_tutorial() -> void:
	print("--- Tutorial")
	settings.tutorial_done = false
	var main := await _load_main()
	var tut: Node = main.tutorial
	var player: Node = main.player
	check(tut != null and tut.current_step() == "move", "first match: the tutorial starts with moving")
	check(main.wave == 0, "wave 1 waits for the tutorial")
	await seconds(1.5)
	check(main.enemies.get_child_count() == 0, "no enemies during the basics")

	player.global_position += Vector3(3, 0, 0)
	check(await _step_is(tut, "look"), "walking: next tip (look)")
	player.look(Vector2(900, 0))
	check(await _step_is(tut, "shoot"), "looking around: next tip (shoot)")
	player.touch_shoot = true
	var ok := await _step_is(tut, "aim")
	player.touch_shoot = false
	check(ok, "shooting: next tip (aim)")
	player.toggle_aim()
	ok = await _step_is(tut, "switch")
	player.toggle_aim()
	check(ok, "aiming: next tip (switch weapon)")
	player.switch_to(1)
	check(await _step_is(tut, "grenade"), "switching: next tip (grenade)")
	player.start_grenade()
	await frames(3)
	player.throw_grenade()
	check(await _until(func() -> bool: return main.wave == 1), "the grenade: basics done, wave 1 starts")
	check(settings.tutorial_done, "the tutorial counts as done")
	check(tut.current_step() == "", "no tip during the wave")

	# Clear wave 1: the shop tip comes at the break.
	main.spawn_timer.wait_time = 0.05
	var cleared := await _until(func() -> bool:
		for e in main.enemies.get_children():
			if e.state != e.State.DEAD:
				e.take_damage(99, e.global_position + Vector3.UP, Vector3.UP)
		return main.phase == main.Phase.BREAK)
	check(cleared and await _step_is(tut, "shop"), "the break: the shop tip")
	main.hud.open_shop()
	check(await _until(func() -> bool: return not is_instance_valid(tut)), "opening the shop ends the tutorial")
	main.hud.close_shop()
	paused = false

	# Skipping (Replay Tutorial, then Skip).
	settings.tutorial_done = false
	main = await _load_main()
	tut = main.tutorial
	check(tut != null and main.wave == 0, "the tutorial plays again")
	tut.skip_button.pressed.emit()
	await frames(2)
	check(main.wave == 1 and not is_instance_valid(tut) and settings.tutorial_done, "Skip starts wave 1 and ends the tutorial")
	settings.tutorial_done = true
	main = await _load_main()
	check(main.tutorial == null and main.wave == 1, "after that: straight to wave 1")


func _step_is(tut: Node, id: String) -> bool:
	return await _until(func() -> bool: return is_instance_valid(tut) and tut.current_step() == id)


## Waits (up to 10 s) for cond to be true.
func _until(cond: Callable) -> bool:
	var until := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < until:
		if cond.call():
			return true
		await process_frame
	return false


func _test_revive() -> void:
	print("--- Revive")
	var main := await _load_main()
	var hud: Node = main.hud
	var player: Node = main.player
	main.spawn_timer.wait_time = 0.05
	var found := []
	await _until(func() -> bool:
		for c in main.enemies.get_children():
			if c.state != c.State.DEAD:
				found.append(c)
		return not found.is_empty())
	var e: Node = found[0] if not found.is_empty() else null
	main.spawn_timer.stop()
	check(e != null, "an enemy to push away")
	# A side of the player with room to be pushed into.
	var side := Vector3.RIGHT
	var space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
	for dir: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK,
			Vector3(1, 0, 1).normalized(), Vector3(-1, 0, 1).normalized(), Vector3(1, 0, -1).normalized(), Vector3(-1, 0, -1).normalized()]:
		var from: Vector3 = player.global_position + Vector3.UP * 0.8
		var q := PhysicsRayQueryParameters3D.create(from, from + dir * 8.0, 1, [player.get_rid(), e.get_rid()])
		if space.intersect_ray(q).is_empty():
			side = dir
			break
	e.global_position = player.global_position + side * 2.0 + Vector3.UP * 0.2
	e.velocity = Vector3.ZERO
	await frames(2)
	var before: float = e.global_position.distance_to(player.global_position)
	check(main.revives_left == Economy.REVIVES_PER_MATCH, "one revive per match")
	player.take_damage(1000)
	await frames(2)
	check(paused and hud.revive_screen.visible and not hud.game_over_panel.visible, "dying offers a revive")
	hud.revive_screen.watch_button.pressed.emit()
	await frames(2)
	check(hud.revive_screen.ad_panel.visible and paused, "Watch ad: the (placeholder) ad plays, game still paused")
	await seconds(Economy.REVIVE_AD_TIME * 0.5)
	check(paused and player.is_dead, "still in the ad halfway through")
	check(await _until(func() -> bool: return not paused), "after the ad the game goes on")
	check(not player.is_dead and player.health == player.MAX_HEALTH, "revived with full health")
	check(e.state == e.State.HIT, "enemies near the player are staggered")
	await seconds(0.6)
	var after: float = e.global_position.distance_to(player.global_position)
	check(after > before + 1.5, "and pushed back (%.1f m -> %.1f m)" % [before, after])
	check(player.is_invulnerable(), "a moment of no damage")
	player.take_damage(30)
	check(player.health == player.MAX_HEALTH, "no damage right after the revive")
	check(main.revives_left == 0 and main.phase != main.Phase.OVER, "the revive is used up")
	await _until(func() -> bool: return not player.is_invulnerable())
	player.take_damage(1000)
	await frames(2)
	check(hud.game_over_panel.visible and not hud.revive_screen.visible, "dying again: straight to Game Over")
	paused = false

	# The offer runs out by itself.
	main = await _load_main()
	main.player.take_damage(1000)
	await frames(2)
	main.hud.revive_screen._offer_left = 0.05
	check(await _until(func() -> bool: return main.hud.game_over_panel.visible), "no answer: Game Over")
	paused = false


func _test_loading_screen() -> void:
	print("--- Loading screen")
	LoadingScreen.go(self, Maps.find("yard"))
	await frames(3)
	var ls: Node = current_scene
	check(ls.name == "LoadingScreen", "the loading screen shows")
	check(ls.tip_label.text.begins_with("Tip: ") and ls.title_label.text == "Industrial Yard", "with the map's name and a tip")
	var seen := 0.0
	var until := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < until and current_scene == ls:
		seen = maxf(seen, ls.progress_bar.value)
		await process_frame
	check(seen > 0.5, "the progress bar fills (%.2f)" % seen)
	await frames(5)
	check(current_scene.name == "Main", "then the map starts")


# Keeps the player's real settings and best scores safe from the test.
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
