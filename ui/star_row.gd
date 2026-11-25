extends Control
## A row of `total` stars, the first `filled` of them gold (map stars).
## Drawn as polygons: the default font has no star character on the web.

const GOLD := Color(1.0, 0.8, 0.3)
const EMPTY := Color(1, 1, 1, 0.18)
const OUTLINE := Color(0, 0, 0, 0.7)

var filled := 0:
	set(v):
		filled = v
		queue_redraw()
var total := 3
var star_size := 30.0


func _init(stars := 0, size_px := 30.0) -> void:
	filled = stars
	star_size = size_px
	custom_minimum_size = Vector2(star_size * total + 6.0 * (total - 1), star_size)
	mouse_filter = MOUSE_FILTER_IGNORE


func _draw() -> void:
	for i in total:
		var c := Vector2(star_size * 0.5 + i * (star_size + 6.0), size.y * 0.5)
		var pts := star_points(c, star_size * 0.5, star_size * 0.22)
		draw_colored_polygon(pts, GOLD if i < filled else EMPTY)
		pts.append(pts[0])
		draw_polyline(pts, OUTLINE, 1.5, true)


static func star_points(center: Vector2, outer: float, inner: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in 10:
		var r := outer if k % 2 == 0 else inner
		var a := -PI / 2.0 + k * PI / 5.0
		pts.append(center + Vector2(cos(a), sin(a)) * r)
	return pts
