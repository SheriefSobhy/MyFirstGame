extends SceneTree
## Screenshots of every map from a few fixed viewpoints, and a rendering
## benchmark per graphics quality (FPS, draw calls, triangles).
## Needs a window (not --headless):
##   godot --path . --script res://tools/map_shots.gd -- --shots <folder> [--bench]
## --shots: saves <folder>/<map>_<view>.png (High quality, no HUD/gun).
## --bench: for each map and Low/Medium/High, looks around from each view
##   for a while and prints average FPS, draw calls and triangles. Desktop
##   FPS isn't phone FPS: the draw calls / triangles are the numbers to compare.

const Maps := preload("res://maps.gd")
## Per map: [name, camera position, look-at point].
const VIEWS := {
	"yard": [
		["start", Vector3(4.0, 1.7, 8.0), Vector3(-4.0, 1.8, -6.0)],
		["shed", Vector3(4.5, 1.7, 3.0), Vector3(-7.0, 2.5, -9.0)],
		["walls", Vector3(-3.0, 1.7, 6.0), Vector3(12.5, 2.0, -10.0)],
	],
	"town": [
		["start", Vector3(0.0, 1.7, 7.0), Vector3(0.0, 1.8, -6.0)],
		["street", Vector3(-3.0, 1.7, -2.0), Vector3(18.0, 2.2, 3.0)],
		["edge", Vector3(8.0, 1.7, 2.0), Vector3(-22.0, 1.8, -3.0)],
	],
	"warehouse": [
		["inside", Vector3(5.0, 1.7, 0.5), Vector3(-14.0, 2.6, 0.0)],
		["aisle", Vector3(-1.0, 1.7, -8.0), Vector3(-15.0, 3.0, -8.0)],
		["yard", Vector3(-2.0, 1.7, 2.0), Vector3(20.0, 2.0, -6.0)],
		["outside", Vector3(19.0, 1.7, 10.0), Vector3(8.0, 3.5, -2.0)],
	],
}

var shots_dir := ""
var bench := false
var S: Node
const Q_LOW := 0
const Q_MEDIUM := 1
const Q_HIGH := 2


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--shots")
	if i >= 0 and i + 1 < args.size():
		shots_dir = args[i + 1]
		DirAccess.make_dir_recursive_absolute(shots_dir)
	bench = args.has("--bench")
	S = root.get_node("Settings")
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var saved_quality: int = S.quality
	var results := []
	for m: Dictionary in Maps.LIST:
		var cam := await _open(m)
		if shots_dir != "":
			for q: int in [Q_HIGH, Q_LOW]:
				S.quality = q
				S.changed.emit()
				for v: Array in VIEWS[m.id]:
					_aim(cam, v)
					for f in 30:
						await process_frame
					var path := shots_dir.path_join("%s_%s_%s.png" % [m.id, v[0], "high" if q == Q_HIGH else "low"])
					root.get_texture().get_image().save_png(path)
					print("saved ", path)
		if bench:
			for q: int in [Q_LOW, Q_MEDIUM, Q_HIGH]:
				S.quality = q
				S.changed.emit()
				results.append(await _bench(m.id, q, cam))
	S.quality = saved_quality
	if bench:
		print("BENCH map        quality   fps   draw_calls  triangles")
		for r: String in results:
			print("BENCH ", r)
	quit()


func _open(m: Dictionary) -> Camera3D:
	change_scene_to_file(m.scene)
	for i in 10:
		await process_frame
		await physics_frame
	var main := current_scene
	main.get_node("SpawnTimer").stop()
	main.set_process(false)
	for e in main.get_node("Enemies").get_children():
		e.queue_free()
	main.get_node("HUD").visible = false
	var player: Node3D = main.get_node("Player")
	player.process_mode = Node.PROCESS_MODE_DISABLED
	player.get_node("Head/Camera3D/ViewModel").visible = false
	var cam := Camera3D.new()
	cam.fov = (player.get_node("Head/Camera3D") as Camera3D).fov
	cam.far = 200.0
	main.add_child(cam)
	cam.make_current()
	return cam


func _aim(cam: Camera3D, v: Array) -> void:
	cam.global_position = v[1]
	cam.look_at(v[2], Vector3.UP)


func _bench(id: String, q: int, cam: Camera3D) -> String:
	var fps_sum := 0.0
	var dc_sum := 0.0
	var tri_sum := 0.0
	var n := 0
	for v: Array in VIEWS[id]:
		_aim(cam, v)
		for f in 20:
			await process_frame
		# Sweep the view left and right a little while measuring.
		var t0 := Time.get_ticks_usec()
		var frames := 0
		for f in 90:
			cam.rotate_y(sin(f * 0.07) * 0.01)
			await process_frame
			frames += 1
			dc_sum += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
			tri_sum += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
			n += 1
		fps_sum += frames / ((Time.get_ticks_usec() - t0) / 1000000.0)
	var qn: String = ["Low", "Medium", "High"][q]
	return "%-11s %-8s %5.0f %8.0f %12.0f" % [id, qn, fps_sum / VIEWS[id].size(), dc_sum / n, tri_sum / n]
