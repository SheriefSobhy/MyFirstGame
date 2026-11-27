extends Node
## Debug builds only: an automatic tour of the first-person weapons on a real
## device. If user://weapon_tour exists, the main menu goes straight into the
## Industrial Yard and this node (added by main.gd) shows every weapon at the
## hip, aiming, firing and mid-reload, saves screenshots to user://tour/ and
## writes user://tour/report.txt (FPS per weapon, quality, draw calls), then
## deletes the flag and quits. Pull the files with
##   adb exec-out run-as <package> tar c files/tour > tour.tar

const Weapons := preload("res://weapon_stats.gd")
const FLAG := "user://weapon_tour"
const DIR := "user://tour"
## Pistol only: hip, walk, fire, aim, reload (not empty, then empty) and a
## switch out and back, with the frame times of each step in the report
## (user://tour/report.txt) and 4 pictures. Made for screen recordings:
##   adb shell run-as <package> touch files/pistol_test
const PISTOL_FLAG := "user://pistol_test"

var _main: Node
var _report := PackedStringArray()
var _phase := ""
var _times := {}   # phase -> PackedFloat32Array of frame times (ms)
var _spikes := PackedStringArray()


static func requested() -> bool:
	return OS.is_debug_build() and (FileAccess.file_exists(FLAG) or FileAccess.file_exists(PISTOL_FLAG))


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_main = get_parent()
	if FileAccess.file_exists(PISTOL_FLAG):
		_pistol_run.call_deferred()
	else:
		_run.call_deferred()


func _process(delta: float) -> void:
	if _phase != "":
		if not _times.has(_phase):
			_times[_phase] = PackedFloat32Array()
		_times[_phase].append(delta * 1000.0)
		if delta > 0.07:
			_spikes.append("  spike %5.1f ms in '%s', frame %d" % [delta * 1000.0, _phase, _times[_phase].size()])


func _pistol_run() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var tree := get_tree()
	var player: Node = _main.get_node("Player")
	var hud: Node = _main.get_node("HUD")
	_main.get_node("SpawnTimer").stop()
	_phase = "load"
	await _wait(1.0)
	for e in tree.get_nodes_in_group("enemies"):
		e.queue_free()
	player.own_all_weapons()
	player.set_infinite_ammo(true)
	player.switch_to(0)
	if tree.paused:
		hud.resume()
	await _wait(2.0)
	_report.append("model %s, quality %s, screen %s, renderer %s" % [OS.get_model_name(),
			Settings.QUALITY_NAMES[Settings.effective_quality()], DisplayServer.window_get_size(),
			RenderingServer.get_current_rendering_method()])
	_phase = "idle (breathing)"
	await _wait(1.5)
	await _shot("1_hip")
	await _wait(1.0)
	_phase = "walk"
	player.touch_move = Vector2(0, -0.6)
	await _wait(1.6)
	player.touch_move = Vector2.ZERO
	await _wait(0.5)
	_phase = "first shots (hip)"
	var t0 := Time.get_ticks_usec()
	player.shoot()
	_report.append("first shoot() call: %.1f ms of CPU" % ((Time.get_ticks_usec() - t0) / 1000.0))
	await _wait(0.4)
	for i in 4:
		player.touch_shoot = true
		await _wait(0.05)
		player.touch_shoot = false
		if i == 1:
			await _shot("3_fire")
		await _wait(0.4)
	_phase = "aim in"
	player.toggle_aim()
	await _wait(0.7)
	await _shot("2_ads")
	_phase = "shots (aiming)"
	for i in 3:
		player.touch_shoot = true
		await _wait(0.05)
		player.touch_shoot = false
		await _wait(0.45)
	_phase = "aim out"
	player.toggle_aim()
	await _wait(0.8)
	_phase = "reload (rounds left)"
	player.start_reload()
	await _wait(2.4)
	_phase = "empty the magazine"
	while player.ammo() > 0:
		player.touch_shoot = true
		await _wait(0.05)
		player.touch_shoot = false
		await _wait(0.2)
	await _wait(0.6)
	_phase = "reload (empty)"
	player.start_reload()
	await _wait(player.reload_time(0) * 0.42)
	await _shot("4_reload")
	await _wait(2.0)
	_phase = "switch out and back"
	player.switch_to(1)
	await _wait(0.9)
	player.switch_to(0)
	await _wait(1.5)
	# What the pistol's first-person view costs (same spot, hidden / shown).
	_phase = "view hidden"
	player.view_model.visible = false
	await _wait(1.5)
	_phase = "view shown"
	player.view_model.visible = true
	await _wait(1.5)
	_phase = ""
	_report.append_array(_spikes)
	for p: String in _times:
		var t: PackedFloat32Array = _times[p]
		var worst := 0.0
		var total := 0.0
		var slow := 0
		for ms in t:
			worst = maxf(worst, ms)
			total += ms
			if ms > 50.0:
				slow += 1
		_report.append("%-22s %4d frames, avg %5.1f fps, worst frame %6.1f ms, frames > 50 ms: %d" % [
				p, t.size(), t.size() * 1000.0 / maxf(total, 1.0), worst, slow])
	var f := FileAccess.open(DIR + "/report.txt", FileAccess.WRITE)
	f.store_string("\n".join(_report) + "\n")
	f.close()
	DirAccess.remove_absolute(PISTOL_FLAG)
	tree.quit()


func _wait(t: float) -> void:
	await get_tree().create_timer(t, true, false, true).timeout


func _shot(file_name: String) -> void:
	var keep := _phase
	_phase = ""  # reading the picture back stalls a frame: not counted
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [DIR, file_name])
	await get_tree().process_frame
	await get_tree().process_frame
	_phase = keep


func _fps(t: float) -> float:
	var frames := Engine.get_frames_drawn()
	var start := Time.get_ticks_msec()
	await _wait(t)
	return (Engine.get_frames_drawn() - frames) * 1000.0 / maxf(Time.get_ticks_msec() - start, 1.0)


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var tree := get_tree()
	var player: Node = _main.get_node("Player")
	var hud: Node = _main.get_node("HUD")
	_main.get_node("SpawnTimer").stop()
	await _wait(1.0)
	for e in tree.get_nodes_in_group("enemies"):
		e.queue_free()
	player.own_all_weapons()
	player.set_infinite_ammo(true)
	await _wait(1.0)
	_report.append("model %s, quality %s, screen %s" % [OS.get_model_name(),
			Settings.QUALITY_NAMES[Settings.effective_quality()], DisplayServer.window_get_size()])
	for slot in Weapons.LIST.size():
		var w: Dictionary = Weapons.LIST[slot]
		var tag := "%d_%s" % [slot, String(w.name).to_lower().replace(" ", "_")]
		if tree.paused:
			hud.resume()
		player.switch_to(slot)
		await _wait(0.9)
		var fps_hip := await _fps(2.0)
		var draw := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		await _shot(tag + "_hip")
		if w.sight != "scope":
			player.toggle_aim()
			await _wait(0.6)
			await _shot(tag + "_ads")
			player.toggle_aim()
			await _wait(0.4)
		player.touch_shoot = true
		await _wait(0.06)
		await _shot(tag + "_fire")
		player.touch_shoot = false
		await _wait(w.fire_delay + 0.5)
		player._mag[slot] = 1
		player.start_reload()
		await _wait(w.reload_time * 0.4)
		await _shot(tag + "_reload")
		await _wait(w.reload_time * 0.7)
		_report.append("%-14s fps at the hip %.0f, draw calls %d" % [w.name, fps_hip, draw])
	# What the first-person view itself costs: same spot, arms and gun hidden.
	player.switch_to(1)
	await _wait(1.0)
	var with_view := await _fps(3.0)
	player.view_model.visible = false
	await _wait(0.5)
	var without := await _fps(3.0)
	player.view_model.visible = true
	_report.append("rifle at the hip: %.1f fps with arms + gun, %.1f fps without" % [with_view, without])
	var f := FileAccess.open(DIR + "/report.txt", FileAccess.WRITE)
	f.store_string("\n".join(_report) + "\n")
	f.close()
	DirAccess.remove_absolute(FLAG)
	tree.quit()
