extends Node
## Debug builds only: a frame-rate benchmark of a map on a phone.
## If user://map_bench exists, the main menu goes straight into the Zombies
## mode on the Yard and main.gd adds this node. The player can't be hurt and
## the waves run as normal (zombies come for the player). For Low, Medium
## and High it stands at each of VIEWS (one per zone) for WARM + MEASURE s and
## records the frame times; at Medium it also saves a screenshot of each
## zone to user://bench/<view>.png. Then it writes user://map_bench.txt,
## puts the quality setting back and quits. The flag is deleted at the start.
##   adb shell run-as <package> touch files/map_bench
##   adb exec-out run-as <package> cat files/map_bench.txt
##   adb exec-out run-as <package> tar c files/bench > bench.tar

const FLAG := "user://map_bench"
const REPORT := "user://map_bench.txt"
const SHOTS := "user://bench"
const WARM := 1.5
const MEASURE := 4.0
## [name, player position, look-at point]: the Yard's zones.
const VIEWS := [
	["yard", Vector3(4.0, 0.0, 8.0), Vector3(-4.0, 1.5, -6.0)],
	["storage", Vector3(14.5, 0.0, 1.5), Vector3(25.0, 1.5, -6.0)],
	["backlot", Vector3(26.0, 0.0, -14.5), Vector3(-10.0, 1.5, -19.0)],
	["roof", Vector3(-7.0, 2.8, -21.6), Vector3(6.0, 0.5, -8.0)],
	["alley", Vector3(-14.5, 0.0, 2.5), Vector3(-14.5, 1.5, -14.0)],
	["gate", Vector3(3.5, 0.0, -9.0), Vector3(3.5, 1.5, -22.0)],
]

var _main: Node
var _player: Node
var _current: Array = VIEWS[0]  # the view being held


static func requested() -> bool:
	return OS.is_debug_build() and FileAccess.file_exists(FLAG)


func _ready() -> void:
	DirAccess.remove_absolute(FLAG)
	DirAccess.make_dir_recursive_absolute(SHOTS)
	_main = get_parent()
	_player = _main.player
	_player.invincible = true
	_run.call_deferred()


func _run() -> void:
	var saved: int = Settings.quality
	var lines := PackedStringArray(["map %s, model %s, screen %s, fps cap %d" % [_main.map_id, OS.get_model_name(),
			DisplayServer.window_get_size(), Engine.max_fps]])
	lines.append("quality  view      avg fps   1%% low fps   median ms   95%% ms   draw calls")
	for q in [Settings.Quality.LOW, Settings.Quality.MEDIUM, Settings.Quality.HIGH]:
		Settings.quality = q
		Settings.changed.emit()
		var all := PackedFloat32Array()
		for v: Array in VIEWS:
			_place(v)
			await _wait(WARM)
			if q == Settings.Quality.MEDIUM:
				get_viewport().get_texture().get_image().save_png(SHOTS.path_join("%s.png" % v[0]))
			var times := PackedFloat32Array()
			var draws := 0.0
			var t := 0.0
			while t < MEASURE:
				_place(v)
				await get_tree().process_frame
				var dt := get_process_delta_time()
				t += dt
				times.append(dt * 1000.0)
				draws += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
			all.append_array(times)
			lines.append(_line(Settings.QUALITY_NAMES[q], v[0], times, draws / times.size()))
		lines.append(_line(Settings.QUALITY_NAMES[q], "ALL", all, 0.0))
	Settings.quality = saved
	Settings.changed.emit()
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(lines) + "\n")
		f.close()
	print("\n".join(lines))
	get_tree().quit()


func _line(quality: String, view: String, times: PackedFloat32Array, draws: float) -> String:
	var sorted := times.duplicate()
	sorted.sort()
	var n := maxi(sorted.size(), 1)
	var total := 0.0
	for t in sorted:
		total += t
	var worst := 0.0  # the slowest 1% of frames, as fps
	for i in range(n * 99 / 100, n):
		worst += sorted[i]
	worst /= maxi(n - n * 99 / 100, 1)
	return "%-8s %-9s %7.1f %12.1f %11.1f %8.1f %12.0f" % [quality, view, 1000.0 * n / maxf(total, 1.0),
			1000.0 / maxf(worst, 0.01), sorted[n / 2], sorted[n * 95 / 100], draws]


# Holds the player at the view's spot, looking at its point (the waves go
# on around it).
func _place(v: Array) -> void:
	_current = v
	_player.global_position = v[1] + Vector3.UP * 0.05
	_player.velocity = Vector3.ZERO
	_player._turn_towards(v[2], 1.0)
	if _player.health < 50:
		_player.heal(100)


func _wait(seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		_place(_current)
		await get_tree().process_frame
		t += get_process_delta_time()