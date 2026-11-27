extends Control
## Soldiers (Test) mode: red arrows round the crosshair pointing to where the
## shots that hit the player came from. They follow the source as the player
## turns and fade out over INDICATOR_TIME. Several shots from one soldier
## refresh one arrow.

const Cfg := preload("res://soldiers/soldiers_config.gd")
const COLOR := Color(1.0, 0.08, 0.04)

var _hits: Array[Dictionary] = []   # {pos: Vector3, age: float}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## A shot from `from` (world position) hit the player.
func add_hit(from: Vector3) -> void:
	for h in _hits:
		if (h.pos as Vector3).distance_to(from) < 1.5:
			h.pos = from
			h.age = 0.0
			queue_redraw()
			return
	_hits.append({"pos": from, "age": 0.0})
	queue_redraw()


## Arrows on screen now (for tests).
func active_count() -> int:
	return _hits.size()


## Screen angle of a world position: 0 = straight ahead (top of the screen),
## positive = to the right, PI = behind (bottom).
func angle_to(from: Vector3) -> float:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return 0.0
	var local := cam.global_basis.inverse() * (from - cam.global_position)
	return atan2(local.x, -local.z)


func _process(delta: float) -> void:
	if _hits.is_empty():
		return
	for h in _hits:
		h.age += delta
	_hits = _hits.filter(func(h: Dictionary) -> bool: return h.age < Cfg.INDICATOR_TIME)
	queue_redraw()


func _draw() -> void:
	var c := size * 0.5
	var r := Cfg.INDICATOR_RADIUS
	for h in _hits:
		var a := angle_to(h.pos)
		var fade := clampf(1.0 - h.age / Cfg.INDICATOR_TIME, 0.0, 1.0)
		var col := Color(COLOR, 0.85 * fade)
		var dir := Vector2(sin(a), -cos(a))
		var mid := dir.angle()
		draw_arc(c, r, mid - 0.32, mid + 0.32, 18, col, 9.0, true)
		var perp := Vector2(-dir.y, dir.x)
		var tip := c + dir * (r + 28.0)
		var base := c + dir * (r + 7.0)
		draw_colored_polygon(PackedVector2Array([tip, base + perp * 14.0, base - perp * 14.0]), col)
