extends Control
## The achievements screen (from the main menu): every achievement in
## progression_config.gd with its progress bar and coin reward. Unlocked ones
## are gold and say DONE (the coins were paid when it was unlocked).

signal closed

const Config := preload("res://progression_config.gd")
const THEME := preload("res://ui/theme.tres")
const COLOR_GOLD := Color(1.0, 0.8, 0.35)
const COLOR_DIM := Color(1, 1, 1, 0.6)

var _title: Label
var _list: VBoxContainer
var _back_button: Button
## Row per achievement id (for the tests): {"panel", "bar", "count", "reward"}.
var rows := {}


func _ready() -> void:
	theme = THEME
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(dim)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(PRESET_CENTER)
	panel.offset_left = -520
	panel.offset_right = 520
	panel.offset_top = -340
	panel.offset_bottom = 340
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 38)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_list)
	for a: Dictionary in Config.ACHIEVEMENTS:
		_list.add_child(_make_row(a))

	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(footer)
	_back_button = Button.new()
	_back_button.text = "Back"
	_back_button.custom_minimum_size = Vector2(260, 62)
	_back_button.pressed.connect(close)
	footer.add_child(_back_button)
	Progress.changed.connect(refresh)
	refresh()


func open() -> void:
	visible = true
	refresh()
	if not DisplayServer.is_touchscreen_available():
		_back_button.grab_focus()


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("release_mouse"):
		close()
		get_viewport().set_input_as_handled()


func _make_row(a: Dictionary) -> Control:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.11, 0.9)
	style.set_corner_radius_all(8)
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	panel.add_child(row)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 0)
	row.add_child(text)
	var title := Label.new()
	title.name = "Title"
	title.text = a.name
	title.add_theme_font_size_override("font_size", 26)
	text.add_child(title)
	var desc := Label.new()
	desc.text = a.text
	desc.add_theme_font_size_override("font_size", 18)
	desc.add_theme_color_override("font_color", COLOR_DIM)
	text.add_child(desc)

	var progress := VBoxContainer.new()
	progress.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(progress)
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(220, 16)
	bar.show_percentage = false
	bar.max_value = a.target
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.6)
	bg.set_corner_radius_all(4)
	var fill := StyleBoxFlat.new()
	fill.bg_color = COLOR_GOLD
	fill.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fill)
	progress.add_child(bar)
	var count := Label.new()
	count.add_theme_font_size_override("font_size", 18)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	progress.add_child(count)

	var reward := Label.new()
	reward.custom_minimum_size = Vector2(150, 0)
	reward.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	reward.add_theme_font_size_override("font_size", 22)
	row.add_child(reward)
	rows[a.id] = {"panel": panel, "style": style, "title": title, "bar": bar, "count": count, "reward": reward}
	return panel


func refresh() -> void:
	var done := 0
	for a: Dictionary in Config.ACHIEVEMENTS:
		var r: Dictionary = rows[a.id]
		var got := Progress.is_achieved(a.id)
		var value := mini(Progress.stat_value(a.stat), a.target)
		if got:
			done += 1
			value = a.target
		r.bar.value = value
		r.count.text = "%d / %d" % [value, a.target]
		r.reward.text = "DONE" if got else "+%d coins" % a.reward
		r.reward.add_theme_color_override("font_color", COLOR_GOLD if got else COLOR_DIM)
		r.title.add_theme_color_override("font_color", COLOR_GOLD if got else Color.WHITE)
		r.style.border_color = COLOR_GOLD if got else Color(1, 1, 1, 0.12)
	_title.text = "Achievements   %d / %d" % [done, Config.ACHIEVEMENTS.size()]


## How many are unlocked (for tests).
func unlocked_count() -> int:
	var n := 0
	for a: Dictionary in Config.ACHIEVEMENTS:
		if Progress.is_achieved(a.id):
			n += 1
	return n
