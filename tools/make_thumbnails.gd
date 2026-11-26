extends SceneTree
## Renders the pictures on the map selection cards and the Training Arena
## (ui/thumbnails/<id>.jpg, also shown by the loading screen):
## each map seen from where the player starts, without the HUD or the gun.
## Needs a window (not --headless):
##   godot --path . --script res://tools/make_thumbnails.gd [-- --only <id>]

const Maps := preload("res://maps.gd")
const SIZE := Vector2i(480, 270)
## Extra look per map: [yaw offset (deg), pitch (deg)] from the start view.
const VIEWS := {"yard": [10.0, -4.0], "town": [0.0, 2.0], "warehouse": [0.0, 0.0], "training": [8.0, -2.0]}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://ui/thumbnails"))
	root.size = Vector2i(1280, 720)
	var args := OS.get_cmdline_user_args()
	var only: String = args[args.find("--only") + 1] if args.find("--only") >= 0 and args.find("--only") + 1 < args.size() else ""
	for m: Dictionary in Maps.LIST + [Maps.TRAINING]:
		if only != "" and m.id != only:
			continue
		change_scene_to_file(m.scene)
		for i in 10:
			await process_frame
		var main := current_scene
		main.get_node("SpawnTimer").stop()
		for e in main.get_node("Enemies").get_children():
			e.queue_free()
		main.get_node("HUD").visible = false
		var player: Node3D = main.get_node("Player")
		player.get_node("Head/Camera3D/ViewModel").visible = false
		var view: Array = VIEWS.get(m.id, [0.0, 0.0])
		player.rotation.y += deg_to_rad(view[0])
		player.get_node("Head").rotation.x = deg_to_rad(view[1])
		for i in 90:
			await process_frame
		var img := root.get_texture().get_image()
		img.resize(SIZE.x, SIZE.y, Image.INTERPOLATE_LANCZOS)
		var path := "res://ui/thumbnails/%s.jpg" % m.id
		img.save_jpg(ProjectSettings.globalize_path(path), 0.85)
		print("saved ", path)
	quit()
