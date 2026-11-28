extends Control
## Combat missions: everything on screen for a mission, over the HUD (built
## in code, added by missions/mission_mode.gd):
##  - the objective tracker (top middle): objective text, a progress bar and
##    a line under it (timer, capture %, ...), plus a second bar (the
##    hostage's health) when one is set;
##  - the objective marker: a diamond with the distance over the objective
##    when it is on screen, an arrow at the screen edge pointing to it when not;
##  - the USE button (bottom middle, phones; "Hold E" prompt on PC), only
##    near an interactable, with a ring that fills while held;
##  - the briefing card before the start, and the success / fail screen.
## Drawing is cheap: one _draw for the marker, labels/bars otherwise.

signal start_pressed
signal retry_pressed
signal next_pressed
signal missions_pressed
signal menu_pressed

const M := preload("res://missions/missions_config.gd")
const StarRow := preload("res://ui/star_row.gd")
const THEME := preload("res://ui/theme.tres")
const GOLD := Color(1.0, 0.8, 0.35)
const MARKER_COLOR := Color(1.0, 0.85, 0.3)
const USE_RADIUS := 64.0
const USE_DRIFT := 250.0   # a held USE finger may slide this far before lifting

## Interactable in reach: text on the USE button ("" = hidden).
var use_text := ""
## True while USE is held (touch, mouse on the button, or E).
var use_held := false
## 0..1 of the current hold.
var use_progress := 0.0
var marker_pos := Vector3.INF
var marker_text := ""
var camera: Camera3D

var tracker: PanelContainer
var tracker_title: Label
var tracker_bar: ProgressBar
var tracker_sub: Label
var health_box: HBoxContainer
var health_label: Label
var health_bar: ProgressBar
var use_button: Control
var briefing: Control
var result: Control
var result_title: Label
var result_reason: Label
var result_stars: StarRow
var result_lines: Label
var next_button: Button
var retry_button: Button
var start_button: Button
var _marker_layer: Control
var _use_touch := -1
var _touch := false


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	theme = THEME
	_touch = DisplayServer.is_touchscreen_available()
	_marker_layer = Control.new()
	_marker_layer.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_marker_layer.mouse_filter = MOUSE_FILTER_IGNORE
	_marker_layer.draw.connect(_draw_marker)
	add_child(_marker_layer)
	_build_tracker()
	_build_use_button()


func _process(_delta: float) -> void:
	_marker_layer.queue_redraw()
	use_button.visible = use_text != "" and not is_overlay_open()
	if use_button.visible:
		use_button.queue_redraw()
	elif _use_touch >= 0 or use_held:
		_use_touch = -1
		use_held = false
	if not _touch:
		# PC: hold E (only while the game runs).
		var e := Input.is_physical_key_pressed(KEY_E) and use_text != "" and not get_tree().paused
		if _use_touch < 0:
			use_held = e


func _input(event: InputEvent) -> void:
	if not use_button.is_visible_in_tree():
		return
	var rect := use_button.get_global_rect()
	if event is InputEventScreenTouch:
		if event.pressed and rect.has_point(event.position) and _use_touch < 0:
			_use_touch = event.index
			use_held = true
		# By position too: browsers renumber fingers when one lifts, so a
		# far-away finger with USE's old index must not let go of it.
		elif not event.pressed and (rect.has_point(event.position) or (event.index == _use_touch
				and rect.get_center().distance_to(event.position) < USE_DRIFT)):
			_use_touch = -1
			use_held = false
	elif event is InputEventMouseButton and not _touch and event.button_index == MOUSE_BUTTON_LEFT \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		if event.pressed and rect.has_point(event.position):
			_use_touch = 99
			use_held = true
		elif not event.pressed and _use_touch == 99:
			_use_touch = -1
			use_held = false


func is_overlay_open() -> bool:
	return (briefing != null and briefing.visible) or (result != null and result.visible)


# --- Tracker ----------------------------------------------------------------------

func _build_tracker() -> void:
	tracker = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.5)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(10)
	tracker.add_theme_stylebox_override("panel", style)
	tracker.anchor_left = 0.5
	tracker.anchor_right = 0.5
	tracker.offset_left = -250
	tracker.offset_right = 250
	tracker.offset_top = 8
	tracker.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(tracker)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.mouse_filter = MOUSE_FILTER_IGNORE
	tracker.add_child(box)
	tracker_title = _label(24, Color.WHITE)
	box.add_child(tracker_title)
	tracker_bar = _bar(Vector2(0, 14), MARKER_COLOR)
	box.add_child(tracker_bar)
	tracker_sub = _label(20, Color(1, 1, 1, 0.85))
	box.add_child(tracker_sub)
	health_box = HBoxContainer.new()
	health_box.add_theme_constant_override("separation", 10)
	health_box.visible = false
	box.add_child(health_box)
	health_label = _label(18, Color(0.6, 0.9, 1.0))
	health_box.add_child(health_label)
	health_bar = _bar(Vector2(0, 12), Color(0.35, 0.85, 1.0))
	health_bar.size_flags_horizontal = SIZE_EXPAND_FILL
	health_box.add_child(health_bar)


## The objective line, its progress (0..1; < 0 hides the bar), the line
## under it and the bar's colour.
func set_tracker(title: String, progress: float, sub: String, color := MARKER_COLOR) -> void:
	tracker_title.text = title
	tracker_bar.visible = progress >= 0.0
	tracker_bar.value = clampf(progress, 0.0, 1.0)
	(tracker_bar.get_theme_stylebox("fill") as StyleBoxFlat).bg_color = color
	tracker_sub.text = sub
	tracker_sub.visible = sub != ""


## The second bar (e.g. "HOSTAGE" health); max <= 0 hides it.
func set_health(text: String, value: float, max_value: float) -> void:
	health_box.visible = max_value > 0.0
	health_label.text = text
	health_bar.max_value = maxf(max_value, 1.0)
	health_bar.value = value
	var share := value / maxf(max_value, 1.0)
	(health_bar.get_theme_stylebox("fill") as StyleBoxFlat).bg_color = \
			Color(0.35, 0.85, 1.0) if share > 0.5 else (Color(1.0, 0.75, 0.2) if share > 0.25 else Color(1.0, 0.25, 0.2))


# --- Marker -----------------------------------------------------------------------

func set_marker(pos: Vector3, text := "") -> void:
	marker_pos = pos
	marker_text = text


## Where the marker is drawn: {pos, on_screen, angle} ({} = no marker).
func marker_screen() -> Dictionary:
	if marker_pos == Vector3.INF or camera == null or is_overlay_open():
		return {}
	var rect := get_viewport_rect().size
	var p := marker_pos + Vector3.UP * 2.2
	var center := rect * 0.5
	var margin := M.MARKER_EDGE
	# In camera space: in front is -Z. Behind (or level with) the camera,
	# the arrow points the way to turn (left / right, down for straight behind).
	var local := camera.global_transform.affine_inverse() * p
	var dir: Vector2
	if local.z < -0.1:
		var s := camera.unproject_position(p)
		if s.x > margin and s.x < rect.x - margin and s.y > margin and s.y < rect.y - margin:
			return {"pos": s, "on_screen": true, "angle": 0.0}
		dir = s - center
	else:
		dir = Vector2(local.x, maxf(-local.y, 0.0) + absf(local.x) * 0.01)
		if absf(local.x) < 0.5:
			dir = Vector2.DOWN
	if dir.length_squared() < 1e-6:
		dir = Vector2.DOWN
	# Onto the screen edge (an inset rectangle) along that direction.
	var half := center - Vector2(margin, margin)
	var k := minf(half.x / maxf(absf(dir.x), 0.001), half.y / maxf(absf(dir.y), 0.001))
	return {"pos": center + dir * k, "on_screen": false, "angle": dir.angle()}


func _draw_marker() -> void:
	var m := marker_screen()
	if m.is_empty():
		return
	var p: Vector2 = m.pos
	var font := get_theme_default_font()
	var dist := camera.global_position.distance_to(marker_pos)
	if m.on_screen:
		var d := 14.0
		var pts := PackedVector2Array([p + Vector2(0, -d), p + Vector2(d, 0), p + Vector2(0, d), p + Vector2(-d, 0)])
		_marker_layer.draw_colored_polygon(pts, Color(MARKER_COLOR, 0.85))
		pts.append(pts[0])
		_marker_layer.draw_polyline(pts, Color.BLACK, 2.0, true)
	else:
		var a: float = m.angle
		var tip := p + Vector2.from_angle(a) * 22.0
		var l := p + Vector2.from_angle(a + 2.5) * 18.0
		var r := p + Vector2.from_angle(a - 2.5) * 18.0
		_marker_layer.draw_colored_polygon(PackedVector2Array([tip, l, p, r]), Color(MARKER_COLOR, 0.9))
		_marker_layer.draw_polyline(PackedVector2Array([tip, l, p, r, tip]), Color.BLACK, 2.0, true)
	var text := "%dm" % roundi(dist)
	if marker_text != "":
		text = "%s  %s" % [marker_text, text]
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
	var at := p + Vector2(-w * 0.5, -22.0 if m.on_screen else 44.0)
	at.x = clampf(at.x, 8.0, get_viewport_rect().size.x - w - 8.0)
	_marker_layer.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, 6, Color.BLACK)
	_marker_layer.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, MARKER_COLOR)


# --- USE button -------------------------------------------------------------------

func _build_use_button() -> void:
	use_button = Control.new()
	use_button.name = "UseButton"
	use_button.mouse_filter = MOUSE_FILTER_IGNORE
	use_button.anchor_left = 0.5
	use_button.anchor_right = 0.5
	use_button.anchor_top = 1.0
	use_button.anchor_bottom = 1.0
	if _touch:
		use_button.offset_left = -USE_RADIUS
		use_button.offset_right = USE_RADIUS
		use_button.offset_top = -170 - USE_RADIUS * 2.0
		use_button.offset_bottom = -170
	else:
		use_button.offset_left = -220
		use_button.offset_right = 220
		use_button.offset_top = -330
		use_button.offset_bottom = -250
	use_button.visible = false
	use_button.draw.connect(_draw_use)
	add_child(use_button)


func _draw_use() -> void:
	var font := get_theme_default_font()
	var sz := use_button.size
	if _touch:
		var c := sz * 0.5
		draw_circle_on(use_button, c, USE_RADIUS, Color(0, 0, 0, 0.55 if not use_held else 0.75))
		use_button.draw_arc(c, USE_RADIUS - 3.0, 0.0, TAU, 48, Color(1, 1, 1, 0.5), 3.0, true)
		if use_progress > 0.0:
			use_button.draw_arc(c, USE_RADIUS - 4.0, -PI / 2.0, -PI / 2.0 + TAU * use_progress, 48, MARKER_COLOR, 8.0, true)
		var t := "USE"
		var w := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 28).x
		use_button.draw_string(font, c + Vector2(-w * 0.5, 4), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 28, Color.WHITE)
		var w2 := font.get_string_size(use_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
		use_button.draw_string(font, c + Vector2(-w2 * 0.5, 26), use_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1, 1, 1, 0.8))
	else:
		var c := Vector2(40, sz.y * 0.5)
		use_button.draw_circle(c, 30.0, Color(0, 0, 0, 0.55))
		use_button.draw_arc(c, 28.0, 0.0, TAU, 40, Color(1, 1, 1, 0.5), 2.0, true)
		if use_progress > 0.0:
			use_button.draw_arc(c, 27.0, -PI / 2.0, -PI / 2.0 + TAU * use_progress, 40, MARKER_COLOR, 6.0, true)
		use_button.draw_string(font, c + Vector2(-8, 9), "E", HORIZONTAL_ALIGNMENT_LEFT, -1, 26, Color.WHITE)
		var t := "Hold: %s" % use_text
		use_button.draw_string_outline(font, c + Vector2(44, 9), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, 6, Color.BLACK)
		use_button.draw_string(font, c + Vector2(44, 9), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, Color.WHITE)


static func draw_circle_on(ci: CanvasItem, c: Vector2, r: float, color: Color) -> void:
	ci.draw_circle(c, r, color)


# --- Briefing ---------------------------------------------------------------------

## The briefing card: mission name, type, objective, a tip, the 3 star goals
## and Start. The game waits (paused) until Start.
func show_briefing(m: Dictionary, best: int) -> void:
	briefing = _card(m.get("map_color", GOLD))
	var box: VBoxContainer = briefing.get_child(0).get_child(0)
	box.add_child(_label(34, GOLD, "%s: %s" % [M.TYPE_NAMES[m.type].to_upper(), m.name]))
	var obj := _label(24, Color.WHITE, m.objective)
	obj.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(obj)
	var tip := _label(20, Color(0.7, 0.9, 1.0), "Tip: " + m.tip)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(tip)
	for n in range(1, 4):
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 10)
		var star := StarRow.new(1 if best >= n else 0, 22.0)
		star.total = 1
		star.custom_minimum_size = Vector2(22, 22)
		row.add_child(star)
		row.add_child(_label(19, Color(1, 1, 1, 0.85), M.star_text(m, n)))
		box.add_child(row)
	start_button = _button("START", 34)
	start_button.pressed.connect(func() -> void:
		briefing.visible = false
		start_pressed.emit())
	box.add_child(start_button)
	var back := _button("Back", 22)
	back.pressed.connect(missions_pressed.emit)
	box.add_child(back)
	if not _touch:
		start_button.grab_focus()


# --- Result -----------------------------------------------------------------------

## Success or failure: title, reason, stars (with what each was for), the
## reward, and Retry / Next mission / Missions / Main Menu.
func show_result(won: bool, reason: String, stars: Array, m: Dictionary, reward: Dictionary,
		time: float, has_next: bool) -> void:
	result = _card(Color(0.4, 1.0, 0.5) if won else Color(1.0, 0.35, 0.3))
	var box: VBoxContainer = result.get_child(0).get_child(0)
	result_title = _label(52, Color(0.5, 1.0, 0.55) if won else Color(1.0, 0.4, 0.35),
			"MISSION COMPLETE" if won else "MISSION FAILED")
	box.add_child(result_title)
	result_reason = _label(24, Color.WHITE, reason)
	result_reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(result_reason)
	var count := stars.count(true)
	result_stars = StarRow.new(count, 44.0)
	var star_row := HBoxContainer.new()
	star_row.alignment = BoxContainer.ALIGNMENT_CENTER
	star_row.add_child(result_stars)
	box.add_child(star_row)
	var lines: Array[String] = []
	for n in 3:
		lines.append("%s  %s" % ["[x]" if stars[n] else "[  ]", M.star_text(m, n + 1)])
	lines.append("Time: %s" % M.time_text(time))
	if won:
		lines.append("%s+%d coins   +%d XP" % ["FIRST CLEAR!  " if reward.get("first", false) else "",
				reward.get("coins", 0), reward.get("xp", 0)])
		if reward.get("best", 0) > reward.get("best_before", 0) and reward.get("best_before", 0) > 0:
			lines.append("New best: %d stars" % reward.best)
	result_lines = _label(20, Color(1, 1, 1, 0.85), "\n".join(lines))
	box.add_child(result_lines)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	box.add_child(row)
	retry_button = _button("Retry", 26)
	retry_button.pressed.connect(retry_pressed.emit)
	row.add_child(retry_button)
	if won and has_next:
		next_button = _button("Next Mission", 26)
		next_button.pressed.connect(next_pressed.emit)
		row.add_child(next_button)
	var list := _button("Missions", 26)
	list.pressed.connect(missions_pressed.emit)
	row.add_child(list)
	var menu := _button("Main Menu", 26)
	menu.pressed.connect(menu_pressed.emit)
	row.add_child(menu)
	if not _touch:
		(next_button if next_button else retry_button).grab_focus()


# --- Helpers ----------------------------------------------------------------------

# A centred card on a dark backdrop: returns the backdrop (card > box inside).
func _card(color: Color) -> Control:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	dim.mouse_filter = MOUSE_FILTER_STOP
	add_child(dim)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.05, 0.05, 0.95)
	style.border_color = color
	style.set_border_width_all(3)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(22)
	panel.add_theme_stylebox_override("panel", style)
	panel.set_anchors_preset(PRESET_CENTER)
	panel.custom_minimum_size = Vector2(680, 0)
	panel.grow_horizontal = GROW_DIRECTION_BOTH
	panel.grow_vertical = GROW_DIRECTION_BOTH
	dim.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	return dim


func _label(font_size: int, color: Color, text := "") -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 5)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = MOUSE_FILTER_IGNORE
	return l


func _button(text: String, font_size: int) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(150, 58)
	b.add_theme_font_size_override("font_size", font_size)
	return b


func _bar(min_size: Vector2, color: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.custom_minimum_size = min_size
	bar.show_percentage = false
	bar.max_value = 1.0
	bar.mouse_filter = MOUSE_FILTER_IGNORE
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.6)
	bg.set_corner_radius_all(4)
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	fill.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fill)
	return bar
