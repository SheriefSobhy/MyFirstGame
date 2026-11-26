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

var _main: Node
var _report := PackedStringArray()


static func requested() -> bool:
	return OS.is_debug_build() and FileAccess.file_exists(FLAG)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_main = get_parent()
	_run.call_deferred()


func _wait(t: float) -> void:
	await get_tree().create_timer(t, true, false, true).timeout


func _shot(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [DIR, file_name])


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
