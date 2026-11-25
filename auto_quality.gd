extends Node
## Graphics "Auto" (Settings.Quality.AUTO): main.gd adds this at the start of
## a match while Auto hasn't picked yet. It counts frames for the first
## MEASURE_TIME seconds of play (after a short warm-up, and not while
## paused), with the frame rate cap lifted, then picks Low, Medium or High
## from the average and saves it in Settings.auto_quality. Choosing Auto
## again in Settings measures again in the next match.

signal picked(quality: int)

const Settings_ := preload("res://settings.gd")
const WARMUP := 2.0          # s: loading hitches and shader compiles don't count
const MEASURE_TIME := 10.0   # s from the start, warm-up included
const TARGET_FPS := 60.0
## Share of TARGET_FPS needed, by the quality it was measured at:
## [for High, for Medium]. Below both: Low.
const SHARES := {
	Settings_.Quality.HIGH: [0.85, 0.55],
	Settings_.Quality.MEDIUM: [0.95, 0.65],
	Settings_.Quality.LOW: [2.0, 0.95],   # can't tell High from Low: at most Medium
}

## The quality being measured (what the match runs at meanwhile).
var measured_at: int = Settings_.Quality.HIGH
var measure_time := MEASURE_TIME
var warmup := WARMUP
var _time := 0.0
var _frames := 0
var _measured := 0.0
var _done := false


## The quality for an average of `fps` frames per second while running at
## `at` quality.
static func pick(fps: float, at: int, target := TARGET_FPS) -> int:
	var share := fps / target
	var need: Array = SHARES.get(at, SHARES[Settings_.Quality.HIGH])
	if share >= need[0]:
		return Settings_.Quality.HIGH
	if share >= need[1]:
		return Settings_.Quality.MEDIUM
	return Settings_.Quality.LOW


func _ready() -> void:
	process_mode = PROCESS_MODE_PAUSABLE
	Engine.max_fps = 0  # measure what the device can do, not the cap


func _process(delta: float) -> void:
	if _done:
		return
	_time += delta
	if _time > warmup:
		_frames += 1
		_measured += delta
	if _time >= measure_time:
		finish()


## The average frame rate counted so far.
func average_fps() -> float:
	return _frames / _measured if _measured > 0.0 else 0.0


func finish() -> void:
	if _done:
		return
	_done = true
	var q := pick(average_fps(), measured_at)
	Settings.auto_quality = q
	Settings.save_settings()
	Settings._apply_fps_cap()
	picked.emit(q)
	queue_free()


func _exit_tree() -> void:
	if not _done:
		# Left the match early: the cap comes back, measure next time.
		Settings._apply_fps_cap()
