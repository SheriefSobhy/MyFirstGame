extends SceneTree
## Screenshots of the first-person weapons (needs a window, not --headless):
##   godot --path . --script res://tools/weapon_shots.gd -- --shots <dir> [--only <slot>,<slot>] [--side] [--reload] [--quality 0|1|2]
## Per weapon: <slot>_<name>_hip.png and _ads.png; --reload adds a shot in
## the middle of the reload, --side a view from outside (right of the gun)
## to check where the hands sit. Enemies are stopped.

const Weapons := preload("res://weapon_stats.gd")

var shots_dir := ""
var player: Node


func _initialize() -> void:
	_run.call_deferred()


func _arg(name: String, def := "") -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else def


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	shots_dir = _arg("--shots", "user://weapon_shots")
	DirAccess.make_dir_recursive_absolute(shots_dir)
	var settings := root.get_node("Settings")
	if _arg("--quality") != "":
		settings.quality = int(_arg("--quality"))
	change_scene_to_file("res://main.tscn")
	await _frames(10)
	var main := current_scene
	main.get_node("SpawnTimer").stop()
	for e in get_nodes_in_group("enemies"):
		e.queue_free()
	player = main.get_node("Player")
	player.own_all_weapons()
	player.set_infinite_ammo(true)
	var hud := main.get_node("HUD")
	# The HUD pauses the game when the window loses focus: undo that.
	process_frame.connect(func() -> void:
		if paused:
			hud.resume())
	await _frames(5)
	var slots: Array = range(Weapons.LIST.size())
	if _arg("--only") != "":
		slots = Array(_arg("--only").split(",")).map(func(x: String) -> int: return int(x))
	for slot: int in slots:
		var w: Dictionary = Weapons.LIST[slot]
		var tag := "%d_%s" % [slot, w.name.to_lower().replace(" ", "_")]
		player.switch_to(slot)
		await _seconds(0.8)
		await _shot(tag + "_hip")
		if "--side" in args:
			await _side(tag + "_side")
		if w.sight != "scope":
			player.toggle_aim()
			await _seconds(0.5)
			await _shot(tag + "_ads")
			if "--side" in args:
				await _side(tag + "_ads_side")
			player.toggle_aim()
			await _seconds(0.4)
		if "--fire" in args:
			player.touch_shoot = true
			await _frames(2)
			player.touch_shoot = false
			await _seconds(0.04)
			await _shot(tag + "_fire")
			await _seconds(w.fire_delay + 0.6)
		if "--reload" in args:
			player._mag[slot] = 1
			player.start_reload()
			for k in [0.15, 0.45, 0.8]:
				await _seconds(w.reload_time * k - (0.0 if k == 0.15 else w.reload_time * (0.3 if k == 0.45 else 0.35)))
				await _shot("%s_reload_%d" % [tag, int(k * 100)])
				if "--side" in args:
					await _side("%s_reload_%d_side" % [tag, int(k * 100)])
			await _seconds(w.reload_time * 0.3)
	hud.visible = true
	quit(0)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _seconds(t: float) -> void:
	if t > 0.0:
		await create_timer(t, true, false, true).timeout


func _shot(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(shots_dir.path_join(file_name + ".png"))
	print("saved ", file_name)


# A camera to the right of the gun, looking at it.
func _side(file_name: String) -> void:
	var cam: Camera3D = player.camera
	var gun: Node3D = player.weapon_recoil
	var side := Camera3D.new()
	side.fov = 40.0
	side.near = 0.01
	root.add_child(side)
	var target := gun.global_position + cam.global_basis * Vector3(-0.02, 0.0, -0.12)
	side.global_position = target + cam.global_basis * Vector3(0.9, 0.12, 0.05)
	side.look_at(target, cam.global_basis.y)
	side.make_current()
	await _frames(2)
	await _shot(file_name)
	cam.make_current()
	side.queue_free()
