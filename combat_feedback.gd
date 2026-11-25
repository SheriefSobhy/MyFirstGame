extends Control
## Combat "juice" on the HUD (hud.gd adds it): everything that tells the
## player a shot landed or that they are in trouble.
##  - Hit markers round the crosshair: white ticks for a hit, a red X for a kill.
##  - A small "HEADSHOT" popup under the crosshair, with its own sound.
##  - Floating damage numbers (Settings.damage_numbers), from a small pool of labels.
##  - Kill sound, kill-streak popups (Double Kill, Triple Kill...) and a
##    vibration on every kill.
##  - Low health: a pulsing red vignette and a heartbeat that speeds up.
## Sounds are made in code (effects/synth_sounds.gd).

const Synth := preload("res://effects/synth_sounds.gd")
const Haptics := preload("res://effects/haptics.gd")

const MARKER_TIME := 0.22          # seconds a hit marker stays
const KILL_MARKER_TIME := 0.4
const HEADSHOT_TIME := 0.7
const STREAK_WINDOW := 2.5         # seconds between kills that keep a streak going
const STREAK_TIME := 1.4
const STREAK_NAMES := {2: "DOUBLE KILL", 3: "TRIPLE KILL", 4: "MULTI KILL"}
const STREAK_MAX_NAME := "RAMPAGE"  # 5 or more
const NUMBER_POOL := 10
const NUMBER_TIME := 0.7
const NUMBER_RISE := 60.0          # pixels a damage number floats up
const DAMAGE_DISPLAY_SCALE := 10   # damage numbers are shown x10 (a pistol hit shows "20")
const LOW_HEALTH := 35             # at or below this the vignette and heartbeat start
const BEAT_SLOW := 1.05            # seconds between heartbeats at LOW_HEALTH...
const BEAT_FAST := 0.5             # ...and close to 0
const COLOR_HIT := Color(1, 1, 1, 0.95)
const COLOR_KILL := Color(1, 0.15, 0.1, 1)
const COLOR_HEADSHOT := Color(1, 0.8, 0.2)

const VIGNETTE_SHADER := """
shader_type canvas_item;
uniform float intensity = 0.0;
void fragment() {
	vec2 d = UV - vec2(0.5);
	float v = smoothstep(0.2, 0.72, length(d * vec2(1.25, 1.0)));
	COLOR = vec4(0.55, 0.0, 0.0, v * intensity);
}
"""

## For tests: "hit", "kill" or "" (no marker showing).
var marker_kind := ""
var streak := 0
## The text of the last streak popup ("" before any).
var last_streak_text := ""
## Damage numbers even with the setting off (the Training Arena).
var force_numbers := false

var _marker_time := 0.0
var _marker_length := MARKER_TIME
var _time := 0.0                  # game time (stops while paused)
var _last_kill_time := -100.0
var _health := 100
var _beat_timer := 0.0
var _beat_pulse := 0.0
var _numbers: Array[Label] = []
var _number_info: Array[Dictionary] = []   # {pos: Vector3, time: float}
var _next_number := 0
var _headshot_label: Label
var _headshot_tween: Tween
var _streak_label: Label
var _streak_tween: Tween
var _vignette: ColorRect
var _tick_sound: AudioStreamPlayer
var _headshot_sound: AudioStreamPlayer
var _kill_sound: AudioStreamPlayer
var _heart_sound: AudioStreamPlayer


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	process_mode = PROCESS_MODE_PAUSABLE  # the heartbeat stops in the pause menu

	_vignette = ColorRect.new()
	_vignette.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_vignette.mouse_filter = MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = VIGNETTE_SHADER
	_vignette.material = ShaderMaterial.new()
	_vignette.material.shader = shader
	_vignette.visible = false
	add_child(_vignette)

	_headshot_label = _make_label(26, COLOR_HEADSHOT)
	_headshot_label.text = "HEADSHOT"
	_streak_label = _make_label(44, Color(1, 0.35, 0.2))
	for i in NUMBER_POOL:
		_numbers.append(_make_label(26, Color.WHITE))
		_number_info.append({"pos": Vector3.ZERO, "time": 0.0})

	_tick_sound = _make_player(Synth.hit_tick(), -8.0)
	_headshot_sound = _make_player(Synth.headshot(), -3.0)
	_kill_sound = _make_player(Synth.kill(), -1.0)
	_heart_sound = _make_player(Synth.heartbeat(), 0.0)


func _make_label(font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 6)
	l.mouse_filter = MOUSE_FILTER_IGNORE
	l.size = Vector2(400, font_size * 1.6)
	l.pivot_offset = l.size * 0.5
	l.visible = false
	add_child(l)
	return l


func _make_player(stream: AudioStream, volume_db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = volume_db
	add_child(p)
	return p


func _center() -> Vector2:
	return size * 0.5


# --- Hits and kills -----------------------------------------------------------

## A shot hit an enemy (player.gd's enemy_hit signal).
func on_enemy_hit(_enemy: Node3D, damage: int, point: Vector3, headshot: bool, killed: bool) -> void:
	_show_marker("kill" if killed else "hit")
	if not killed:
		_tick_sound.pitch_scale = randf_range(0.95, 1.05)
		_tick_sound.play()
	if headshot:
		_show_headshot()
	if Settings.damage_numbers or force_numbers:
		_show_number(damage * DAMAGE_DISPLAY_SCALE, point, headshot)


## The player killed an enemy (gun, grenade or a blast they set off).
func on_kill() -> void:
	streak = streak + 1 if _time - _last_kill_time <= STREAK_WINDOW else 1
	_last_kill_time = _time
	_kill_sound.pitch_scale = 1.0 + 0.07 * mini(streak - 1, 4)
	_kill_sound.play()
	Haptics.kill()
	if streak >= 2:
		_show_streak(STREAK_NAMES.get(streak, STREAK_MAX_NAME))


func _show_marker(kind: String) -> void:
	# A kill marker isn't replaced by a plain hit straight away (shotgun, LMG).
	if marker_kind == "kill" and kind == "hit" and _marker_time > MARKER_TIME * 0.5:
		return
	marker_kind = kind
	_marker_length = KILL_MARKER_TIME if kind == "kill" else MARKER_TIME
	_marker_time = _marker_length
	queue_redraw()


func _show_headshot() -> void:
	_headshot_sound.play()
	_headshot_label.position = _center() + Vector2(-_headshot_label.size.x * 0.5, 34)
	_headshot_label.visible = true
	_headshot_label.modulate.a = 1.0
	_headshot_label.scale = Vector2.ONE * 1.4
	if _headshot_tween:
		_headshot_tween.kill()
	_headshot_tween = create_tween()
	_headshot_tween.tween_property(_headshot_label, "scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_headshot_tween.tween_interval(HEADSHOT_TIME - 0.35)
	_headshot_tween.tween_property(_headshot_label, "modulate:a", 0.0, 0.23)
	_headshot_tween.tween_callback(_headshot_label.hide)


func _show_streak(text: String) -> void:
	last_streak_text = text
	_streak_label.text = text
	_streak_label.position = _center() + Vector2(-_streak_label.size.x * 0.5, -150)
	_streak_label.visible = true
	_streak_label.modulate.a = 1.0
	_streak_label.scale = Vector2.ONE * 1.6
	if _streak_tween:
		_streak_tween.kill()
	_streak_tween = create_tween()
	_streak_tween.tween_property(_streak_label, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_streak_tween.tween_interval(STREAK_TIME - 0.5)
	_streak_tween.tween_property(_streak_label, "modulate:a", 0.0, 0.32)
	_streak_tween.tween_callback(_streak_label.hide)


func _show_number(value: int, point: Vector3, headshot: bool) -> void:
	var i := _next_number
	_next_number = (_next_number + 1) % NUMBER_POOL
	var l := _numbers[i]
	l.text = str(value)
	l.add_theme_color_override("font_color", COLOR_HEADSHOT if headshot else Color.WHITE)
	l.scale = Vector2.ONE * (1.25 if headshot else 1.0)
	_number_info[i] = {"pos": point + Vector3(randf_range(-0.15, 0.15), 0.25, 0.0), "time": NUMBER_TIME}
	_place_number(i)


## How many damage numbers are on screen (for tests).
func numbers_showing() -> int:
	var n := 0
	for l in _numbers:
		if l.visible:
			n += 1
	return n


func _place_number(i: int) -> void:
	var l := _numbers[i]
	var info := _number_info[i]
	var camera := get_viewport().get_camera_3d()
	if info.time <= 0.0 or camera == null or camera.is_position_behind(info.pos):
		l.visible = false
		return
	var t: float = 1.0 - info.time / NUMBER_TIME
	l.visible = true
	l.position = camera.unproject_position(info.pos) - l.size * 0.5 + Vector2(0, -NUMBER_RISE * t)
	l.modulate.a = clampf(info.time / (NUMBER_TIME * 0.4), 0.0, 1.0)


# --- Low health -----------------------------------------------------------------

## The player's health changed (player.gd's health_changed signal).
func set_health(value: int) -> void:
	_health = value
	if not is_low_health():
		_vignette.visible = false
		_beat_timer = 0.0
	if value <= 0:
		_heart_sound.stop()


func is_low_health() -> bool:
	return _health > 0 and _health <= LOW_HEALTH


## 0 = healthy, 1 = almost dead.
func low_health_amount() -> float:
	if not is_low_health():
		return 0.0
	return clampf(1.0 - float(_health) / LOW_HEALTH, 0.0, 1.0) * 0.45 + 0.55


func vignette_showing() -> bool:
	return _vignette.visible


## Hides everything (Game Over).
func clear() -> void:
	_health = 0
	_vignette.visible = false
	_heart_sound.stop()
	_marker_time = 0.0
	marker_kind = ""
	_headshot_label.visible = false
	_streak_label.visible = false
	for i in NUMBER_POOL:
		_number_info[i].time = 0.0
		_numbers[i].visible = false
	queue_redraw()


## Draws the vignette once while the level loads, so its shader is compiled
## before the player first gets low (see main.gd _prewarm_effects).
func prewarm(on: bool) -> void:
	_vignette.visible = on
	_vignette.material.set_shader_parameter("intensity", 0.01 if on else 0.0)


func _process(delta: float) -> void:
	_time += delta
	if _marker_time > 0.0:
		_marker_time -= delta
		if _marker_time <= 0.0:
			marker_kind = ""
		queue_redraw()
	for i in NUMBER_POOL:
		if _number_info[i].time > 0.0:
			_number_info[i].time -= delta
			_place_number(i)

	var amount := low_health_amount()
	if amount > 0.0:
		_beat_timer -= delta
		if _beat_timer <= 0.0:
			_beat_timer = lerpf(BEAT_SLOW, BEAT_FAST, amount)
			_beat_pulse = 1.0
			_heart_sound.volume_db = lerpf(-8.0, 0.0, amount)
			_heart_sound.play()
		_beat_pulse = move_toward(_beat_pulse, 0.0, delta * 2.5)
		_vignette.visible = true
		_vignette.material.set_shader_parameter("intensity", minf(amount * (0.75 + 0.35 * _beat_pulse), 1.0))
	elif _vignette.visible:
		_vignette.visible = false
		_beat_timer = 0.0


func _draw() -> void:
	if _marker_time <= 0.0:
		return
	var c := _center()
	var t := _marker_time / _marker_length   # 1 -> 0
	var kill := marker_kind == "kill"
	var color := COLOR_KILL if kill else COLOR_HIT
	color.a *= clampf(t * 1.5, 0.0, 1.0)
	var gap := (9.0 if kill else 8.0) + (1.0 - t) * 3.0
	var length := 13.0 if kill else 8.0
	var width := 3.5 if kill else 2.5
	for d: Vector2 in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		var n := d.normalized()
		draw_line(c + n * gap, c + n * (gap + length), color, width, true)
