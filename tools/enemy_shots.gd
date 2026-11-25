extends SceneTree
## Screenshots of the enemies, for a visual check (needs a window, no --headless):
##   godot --path . --script res://tools/enemy_shots.gd -- --shots <folder> [--maps] [--quality low|medium|high]
## Saves <folder>/enemy_<kind>.png (each type alone, ~4 m away), lineup.png
## (every type side by side) and, with --maps, <folder>/play_<map>.png: a few
## seconds into wave 1-2 on each map.

const Types := preload("res://enemy_types.gd")
const Maps := preload("res://maps.gd")

var shots_dir := ""
var main: Node
var player: Node


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--shots")
	if i < 0 or i + 1 >= args.size():
		print("usage: -- --shots <folder> [--maps] [--quality low|medium|high]")
		quit(1)
		return
	shots_dir = args[i + 1]
	DirAccess.make_dir_recursive_absolute(shots_dir)
	i = args.find("--quality")
	var settings: Node = root.get_node("Settings")
	settings.quality = settings.Quality.HIGH
	if i >= 0 and i + 1 < args.size():
		settings.quality = {"low": 0, "medium": 1, "high": 2}.get(args[i + 1], 2)
	_run.call_deferred(args.has("--maps"))


func seconds(t: float) -> void:
	await create_timer(t, true, true).timeout


func _load(path: String) -> void:
	change_scene_to_file(path)
	await process_frame
	await physics_frame
	while current_scene == null or current_scene.get_node_or_null("Player") == null:
		await process_frame
	for n in 10:
		await physics_frame
	main = current_scene
	player = main.get_node("Player")


func _run(maps: bool) -> void:
	# The Training Arena: open, evenly lit floor in front of the firing line.
	await _load("res://maps/training.tscn")
	main.get_node("HUD").visible = false
	player.invincible = true
	_clear_enemies()
	var start := Vector3(0, 0, -3.0)  # downrange, past the benches
	for kind: String in Types.TYPES:
		var h: float = Types.TYPES[kind].height
		var dist := 3.0 + h * 0.6
		var e := _spawn(kind, start + Vector3(1.3, 0, -dist))
		e.rotation.y = PI - 0.6  # facing the camera, turned a little
		_put_player(start)
		player.rotation.y = 0.0
		player.head.rotation.x = atan2(h * 0.55 - 1.6, dist)
		await seconds(0.8)
		await _screenshot("enemy_" + kind)
		if kind == "soldier":
			e.rotation.y = PI / 2.0  # side on: the rifle
			await seconds(0.3)
			await _screenshot("enemy_soldier_side")
		_clear_enemies()
	_put_player(start)
	player.rotation.y = 0.0
	player.head.rotation.x = deg_to_rad(3)
	var kinds := ["runner", "normal", "soldier", "exploder", "brute", "boss"]
	for i in kinds.size():
		var e := _spawn(kinds[i], start + Vector3(-4.0 + i * 1.9, 0, -8.0 - i * 0.4))
		e.rotation.y = PI
	await seconds(0.8)
	await _screenshot("lineup")
	_clear_enemies()
	if maps:
		for m: Dictionary in Maps.LIST:
			await _load(m.scene)
			main.get_node("HUD").visible = false
			player.invincible = true
			main.revives_left = 0
			# A mixed wave so several types are on screen.
			main.get_node("SpawnTimer").stop()
			main.start_wave(6)
			await seconds(11.0)
			var enemies: Array = main.get_node("Enemies").get_children()
			if not enemies.is_empty():
				var nearest: Node3D = enemies[0]
				for e: Node3D in enemies:
					if e.global_position.distance_to(player.global_position) < nearest.global_position.distance_to(player.global_position):
						nearest = e
				var d: Vector3 = nearest.global_position - player.global_position
				player.rotation.y = atan2(-d.x, -d.z)
				player.head.rotation.x = -0.05
			await seconds(0.3)
			await _screenshot("play_" + str(m.id))
	quit(0)


# A frozen dummy (no AI) so it stays where it was put.
func _spawn(kind: String, pos: Vector3) -> Node3D:
	var e: Node3D = main.ENEMY_SCENE.instantiate()
	e.kind = kind
	e.dummy = true
	e.position = pos
	main.get_node("Enemies").add_child(e)
	return e


func _put_player(pos: Vector3) -> void:
	player.global_position = pos
	player.velocity = Vector3.ZERO


func _clear_enemies() -> void:
	var holder: Node = main.get_node("Enemies")
	for e in holder.get_children():
		holder.remove_child(e)
		e.queue_free()


func _screenshot(file_name: String) -> void:
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	img.save_png(shots_dir.path_join(file_name + ".png"))
	print("saved ", file_name)
