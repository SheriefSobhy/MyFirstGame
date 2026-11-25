extends SceneTree
## Automated check of the game loop: main menu, waves, pause menu, settings,
## Game Over, best score, Retry and back to the menu.
##   godot --headless --path . --script res://tools/test_game_loop.gd
## Prints PASS/FAIL per check and exits with code 1 if anything failed.
## Your saved settings and best score are backed up and restored afterwards.

const MENU := "res://ui/main_menu.tscn"

var failures := 0
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


func _run() -> void:
	_backup_saves()
	var settings: Node = root.get_node("Settings")
	var music: Node = root.get_node("Music")
	settings.clear_bests()

	await _test_settings(settings)

	# --- Main menu ---
	change_scene_to_file(MENU)
	await frames(5)
	var menu := current_scene
	check(menu.title_label.text == "Last Stand", "menu shows the game title (got '%s')" % menu.title_label.text)
	check(menu.play_button.visible and menu.settings_button.visible and menu.quit_button.visible,
			"menu has Play, Settings and Quit")
	check(music.current_track() == music.MENU_TRACK, "menu music plays")
	menu.settings_button.pressed.emit()
	check(menu.settings_menu.visible, "menu Settings opens the settings screen")
	menu.settings_menu.back_button.pressed.emit()
	check(not menu.settings_menu.visible, "settings Back closes it")

	menu.play_button.pressed.emit()
	await frames(5)
	var select := current_scene
	check(select.name == "MapSelect", "Play opens the map selection screen")
	check(select.play_buttons.size() == 3, "three maps to choose from")
	select.play_buttons["yard"].pressed.emit()
	check(await _wait_for_scene("LoadingScreen"), "Play shows the loading screen")
	check(await _wait_for_scene("Main"), "the loading screen opens the map")
	await frames(5)
	var main := current_scene
	check(main.name == "Main" and main.map_id == "yard", "picking Industrial Yard loads the yard")
	await create_timer(1.6).timeout  # let the music fade over
	check(music.current_track() == music.GAME_TRACK, "gameplay music plays")

	await _test_waves(main)
	await _test_pause(main, settings)
	await _test_game_over(main, settings)

	_restore_saves()
	print("\n%s: %d failure(s)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _test_settings(settings: Node) -> void:
	settings.set_value("master_volume", 0.5)
	check(absf(AudioServer.get_bus_volume_db(0) - linear_to_db(0.5)) < 0.01, "master volume sets the Master bus")
	var music_bus := AudioServer.get_bus_index("Music")
	check(music_bus > 0, "a Music bus exists")
	settings.set_value("music_volume", 0.0)
	check(AudioServer.is_bus_mute(music_bus), "music volume 0 mutes the Music bus")
	settings.set_value("look_sensitivity", 2.0)
	settings.set_value("quality", 0)
	settings.save_settings()
	var cfg := ConfigFile.new()
	check(cfg.load(settings.SETTINGS_PATH) == OK, "settings saved to user://")
	check(cfg.get_value("audio", "master_volume") == 0.5 and cfg.get_value("audio", "music_volume") == 0.0
			and cfg.get_value("controls", "look_sensitivity") == 2.0 and cfg.get_value("graphics", "quality") == 0,
			"saved settings have the right values")
	# Back to normal for the rest of the test.
	settings.set_value("master_volume", 1.0)
	settings.set_value("music_volume", 0.6)
	settings.set_value("look_sensitivity", 1.0)
	settings.set_value("quality", 2)
	check(not AudioServer.is_bus_mute(music_bus), "music unmutes again")


func _test_waves(main: Node) -> void:
	var hud: Node = main.hud
	check(main.wave == 1 and main.enemies_in_wave(1) == 5, "wave 1 has 5 enemies")
	check(main.enemies_in_wave(2) > 5 and main.enemies_in_wave(3) > main.enemies_in_wave(2), "each wave adds enemies")
	check(main.speed_in_wave(2) > 1.0 and main.speed_in_wave(3) > main.speed_in_wave(2), "each wave is faster")
	check(hud.banner_title.text == "Wave 1", "'Wave 1' banner shows (got '%s')" % hud.banner_title.text)
	check(hud.wave_label.text.begins_with("Wave 1"), "HUD shows the wave (got '%s')" % hud.wave_label.text)
	check(hud.pause_button.visible, "pause button is shown")

	# Kill every enemy as it appears until the wave is cleared.
	main.spawn_timer.wait_time = 0.05
	main.player.health = 40
	var spawned := 0
	for i in 600:
		for e in main.enemies.get_children():
			if e.state != e.State.DEAD:
				spawned += 1
				e.take_damage(99, e.global_position + Vector3.UP, Vector3.UP)
		if main.phase == main.Phase.BREAK:
			break
		await frames(1)
	check(spawned == 5, "wave 1 spawned 5 enemies (got %d)" % spawned)
	check(main.phase == main.Phase.BREAK, "clearing wave 1 starts the break")
	check(main.kills == 5 and main.waves_survived == 1, "5 kills, 1 wave survived")
	check(main.score == 5 * main.KILL_POINTS + main.WAVE_POINTS, "score counts kills and the wave bonus (got %d)" % main.score)
	check(main.player.health == 40 + main.WAVE_HEAL, "clearing a wave heals the player (health %d)" % main.player.health)
	check(hud.banner_title.text == "Wave 1 cleared", "'Wave 1 cleared' banner shows")
	await frames(3)
	check(hud.wave_label.text.begins_with("Wave 2 in"), "HUD counts down to wave 2 (got '%s')" % hud.wave_label.text)

	# Skip the rest of the break.
	main._break_left = 0.01
	await frames(3)
	check(main.wave == 2 and main.phase == main.Phase.FIGHT, "wave 2 starts after the break")
	check(hud.banner_title.text == "Wave 2", "'Wave 2' banner shows")
	# (Wave 1 bodies may still be lying around, so look for a living one.)
	var e: Node = null
	for i in 200:
		for child in main.enemies.get_children():
			if child.state != child.State.DEAD:
				e = child
		if e != null:
			break
		await frames(1)
	check(e != null, "wave 2 enemies spawn")
	check(is_equal_approx(e.speed_scale, main.speed_in_wave(2)), "wave 2 enemies are faster (%.2f)" % e.speed_scale)
	main.spawn_timer.wait_time = main.SPAWN_INTERVAL


func _test_pause(main: Node, settings: Node) -> void:
	var hud: Node = main.hud
	var touch: Control = hud.touch_controls

	# Touches on the pause button don't turn the view; pausing drops held fingers.
	touch.visible = true
	await frames(1)
	var pause_center: Vector2 = hud.pause_button.get_global_rect().get_center()
	touch._touch_down(7, pause_center)
	check(not touch._fingers.has("look"), "touch on the pause button isn't used for looking")
	touch._touch_down(3, touch._button_center("shoot"))
	check(main.player.touch_shoot, "shoot button held")

	hud.pause_button.pressed.emit()
	check(paused and hud.pause_menu.visible and not hud.pause_button.visible, "pause button pauses the game")
	check(not main.player.touch_shoot and touch._fingers.is_empty(), "pausing lets go of held touch buttons")
	touch.visible = false

	_settings_button(hud).pressed.emit()
	check(hud.settings_menu.visible and not hud.pause_menu.visible, "pause Settings opens the settings screen")

	# Graphics quality applies straight away.
	settings.set_value("quality", 0)
	check(not main.sun.shadow_enabled and not main.environment.fog_enabled
			and is_equal_approx(main.get_viewport().scaling_3d_scale, 0.5), "Low: no shadows, no fog, 50% resolution")
	settings.set_value("quality", 1)
	check(main.sun.shadow_enabled and main.environment.fog_enabled
			and is_equal_approx(main.get_viewport().scaling_3d_scale, 0.6), "Medium: shadows, fog, 60% resolution")
	settings.set_value("quality", 2)
	check(main.sun.shadow_enabled and main.environment.glow_enabled
			and is_equal_approx(main.get_viewport().scaling_3d_scale, 1.0), "High: shadows, glow, full resolution")

	hud.settings_menu.back_button.pressed.emit()
	check(hud.pause_menu.visible and paused, "closing settings returns to the pause menu")
	hud.resume_button.pressed.emit()
	check(not paused and not hud.pause_menu.visible and hud.pause_button.visible, "Resume unpauses")

	# Esc toggles the pause menu.
	_press_esc()
	await frames(2)
	check(paused and hud.pause_menu.visible, "Esc pauses")
	_press_esc()
	await frames(2)
	check(not paused, "Esc again resumes")


func _test_game_over(main: Node, settings: Node) -> void:
	var hud: Node = main.hud
	var score: int = main.score
	main.player.take_damage(1000)
	await frames(2)
	check(paused and hud.revive_screen.visible and not hud.game_over_panel.visible,
			"dying first offers a revive (game paused)")
	check(hud.revive_screen.watch_button.text == "Watch ad to revive", "the revive button says Watch ad")
	_press_esc()
	await frames(2)
	check(paused and hud.revive_screen.visible, "Esc doesn't resume past the revive offer")
	hud.revive_screen.no_button.pressed.emit()
	await frames(2)
	check(paused and hud.game_over_panel.visible and not hud.revive_screen.visible, "No thanks shows Game Over and pauses")
	check(hud.waves_label.text == "Waves survived: 1", "Game Over shows waves survived (got '%s')" % hud.waves_label.text)
	check(hud.kills_label.text == "Kills: 5", "Game Over shows kills (got '%s')" % hud.kills_label.text)
	check(hud.final_score_label.text == "Score: %d" % score, "Game Over shows the score")
	check(hud.best_label.text == "New best score!", "first run is a new best")
	check(not hud.pause_button.visible, "no pause button on Game Over")
	var save := ConfigFile.new()
	check(save.load(settings.SAVE_PATH) == OK and save.get_value("best_yard", "score") == score,
			"best score saved to user:// for the yard")

	# Retry: a fresh run that ends with a lower score.
	hud.retry_button.pressed.emit()
	await frames(15)
	main = current_scene
	hud = main.hud
	check(not paused and main.wave == 1 and main.score == 0 and not main.player.is_dead, "Retry starts a fresh game")
	check(main.revives_left == 1, "Retry gives the revive back")
	main.revives_left = 0
	main.player.take_damage(1000)
	await frames(2)
	check(hud.best_label.text == "Best: %d" % score, "lower score shows the saved best (got '%s')" % hud.best_label.text)

	_over_menu_button(hud).pressed.emit()
	await frames(10)
	check(current_scene.name == "MainMenu" and not paused, "Main Menu button goes back to the menu")
	check(current_scene.best_label.text.begins_with("Best: %d" % score), "menu shows the best score")


## Waits (up to 30 s) until the current scene is `scene_name`.
func _wait_for_scene(scene_name: String) -> bool:
	var until := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < until:
		if current_scene != null and current_scene.name == scene_name:
			return true
		await process_frame
	return false


func _press_esc() -> void:
	var ev := InputEventAction.new()
	ev.action = "release_mouse"
	ev.pressed = true
	Input.parse_input_event(ev)


func _settings_button(hud: Node) -> Button:
	return hud.get_node("%SettingsButton")


func _over_menu_button(hud: Node) -> Button:
	return hud.get_node("%OverMenuButton")


# Keeps the player's real settings and best score safe from the test.
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
	settings._load()
	settings._apply_audio()
