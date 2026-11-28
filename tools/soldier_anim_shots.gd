extends SceneTree
## Screenshots of the soldier's animation clips, for a visual check (needs a
## window, no --headless):
##   godot --path . --script res://tools/soldier_anim_shots.gd -- --shots <folder> [--at 0.4]
## Saves <folder>/clips_front_a/b.png and clips_side_a/b.png: one frozen soldier per
## clip of soldier_anims.res (labelled), `--at` = share of each clip's length.

const CLIPS := ["idle", "relaxed", "aim", "walk", "run", "walk_back", "walk_left", "walk_right", "crouch", "hit", "shoot"]

var shots_dir := ""
var at := 0.4
var main: Node
var player: Node


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--shots")
	if i < 0 or i + 1 >= args.size():
		print("usage: -- --shots <folder> [--at 0.4]")
		quit(1)
		return
	shots_dir = args[i + 1]
	DirAccess.make_dir_recursive_absolute(shots_dir)
	i = args.find("--at")
	if i >= 0 and i + 1 < args.size():
		at = float(args[i + 1])
	root.get_node("Settings").quality = 2
	_run.call_deferred()


func _run() -> void:
	change_scene_to_file("res://maps/training.tscn")
	await process_frame
	while current_scene == null or current_scene.get_node_or_null("Player") == null:
		await process_frame
	for n in 10:
		await physics_frame
	main = current_scene
	player = main.get_node("Player")
	main.get_node("HUD").visible = false
	player.invincible = true
	var holder: Node = main.get_node("Enemies")
	for e in holder.get_children():
		e.queue_free()
	var start := Vector3(0, 0, -3.0)
	var soldiers: Array[Node3D] = []
	for k in CLIPS.size():
		var e: Node3D = main.ENEMY_SCENE.instantiate()
		e.kind = "soldier"
		e.dummy = true
		e.position = start + Vector3(-7.5 + k * 1.5, 0, -9.0)
		holder.add_child(e)
		var label := Label3D.new()
		label.text = CLIPS[k]
		label.position = Vector3(0, 2.1, 0)
		label.pixel_size = 0.004
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		e.add_child(label)
		soldiers.append(e)
	player.global_position = start
	player.rotation.y = 0.0
	player.head.rotation.x = deg_to_rad(-3)
	player.camera.fov = 50.0
	for view: String in ["front_a", "front_b", "side_a", "side_b"]:
		var first := 0 if view.ends_with("a") else 6
		for k in soldiers.size():
			var e := soldiers[k]
			e.visible = k >= first and k < first + 6
			e.position = start + Vector3(-3.25 + (k - first) * 1.3, 0, -5.5)
			e.rotation.y = PI if view.begins_with("front") else PI / 2.0
			var a: Animation = e.anim.get_animation(CLIPS[k])
			e.anim.play(CLIPS[k], 0.0, 0.0)
			e.anim.seek(a.length * at, true)
		for n in 20:
			await physics_frame
			await process_frame
		var img := root.get_texture().get_image()
		img.save_png(shots_dir.path_join("clips_%s.png" % view))
		print("saved clips_", view)
	quit(0)
