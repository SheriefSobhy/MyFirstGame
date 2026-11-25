extends Control
## Customize Controls (opened from Settings): the touch buttons drawn where
## they are in a match. Drag a button to move it; the one picked last can be
## resized with the Size slider. Opacity fades every button and the joystick.
## Changes apply at once (Settings.touch_layout / touch_opacity) and are saved
## on Done; "Reset to default" puts everything back. Works with a mouse too.

signal closed

const TOUCH_SCENE := preload("res://touch_controls.tscn")
const THEME := preload("res://ui/theme.tres")
const BUTTON_NAMES := {
	"shoot": "Shoot", "aim": "Aim", "jump": "Jump",
	"reload": "Reload", "switch": "Switch weapon", "grenade": "Grenade",
}

## The preview (touch_controls.gd in edit mode).
var touch: Control
var size_slider: HSlider
var opacity_slider: HSlider
var selected_label: Label
var done_button: Button
var reset_button: Button
var _dragging := false
var _drag_offset := Vector2.ZERO


func _init() -> void:
	theme = THEME
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_STOP
	visible = false


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.08, 0.92)
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	bg.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(bg)

	touch = TOUCH_SCENE.instantiate()
	touch.force_show = true
	touch.edit_mode = true
	touch.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(touch)

	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.offset_left = -280
	panel.offset_right = 280
	panel.offset_top = 16
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	var title := Label.new()
	title.text = "Customize Controls"
	title.add_theme_font_size_override("font_size", 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	selected_label = Label.new()
	selected_label.add_theme_font_size_override("font_size", 20)
	selected_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	selected_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(selected_label)
	size_slider = _slider_row(box, "Size", Settings.MIN_BUTTON_SCALE, Settings.MAX_BUTTON_SCALE)
	size_slider.value_changed.connect(_on_size)
	opacity_slider = _slider_row(box, "Opacity", Settings.MIN_TOUCH_OPACITY, 1.0)
	opacity_slider.value_changed.connect(func(v: float) -> void: Settings.set_value("touch_opacity", v))
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	box.add_child(row)
	reset_button = Button.new()
	reset_button.text = "Reset to default"
	reset_button.custom_minimum_size = Vector2(240, 56)
	reset_button.pressed.connect(reset_layout)
	row.add_child(reset_button)
	done_button = Button.new()
	done_button.text = "Done"
	done_button.custom_minimum_size = Vector2(200, 56)
	done_button.pressed.connect(close)
	row.add_child(done_button)


func _slider_row(box: VBoxContainer, text: String, lo: float, hi: float) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(110, 0)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 0.05
	s.custom_minimum_size = Vector2(0, 44)
	s.size_flags_horizontal = SIZE_EXPAND_FILL
	s.size_flags_vertical = SIZE_SHRINK_CENTER
	row.add_child(s)
	box.add_child(row)
	return s


func open() -> void:
	visible = true
	select("shoot")
	opacity_slider.set_value_no_signal(Settings.touch_opacity)
	if not DisplayServer.is_touchscreen_available():
		done_button.grab_focus()


func close() -> void:
	if not visible:
		return
	_dragging = false
	Settings.save_settings()
	visible = false
	closed.emit()


func reset_layout() -> void:
	Settings.reset_touch_layout()
	opacity_slider.set_value_no_signal(Settings.touch_opacity)
	select(touch.edit_selected)


## Picks the button the Size slider changes.
func select(button_name: String) -> void:
	touch.edit_selected = button_name
	size_slider.set_value_no_signal(touch._button_scale(button_name))
	selected_label.text = "%s  ·  drag any button to move it" % BUTTON_NAMES.get(button_name, button_name)
	touch.queue_redraw()


func _on_size(value: float) -> void:
	var b: String = touch.edit_selected
	if b != "":
		touch.place_button(b, touch._button_center(b), value)


## Moves a button so its centre is at `pos` (screen coordinates).
func move_button(button_name: String, pos: Vector2) -> void:
	touch.place_button(button_name, pos, touch._button_scale(button_name))


# Touches arrive as emulated mouse events, so this handles both.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var b: String = touch._button_at(event.position)
			if b != "":
				select(b)
				_dragging = true
				_drag_offset = touch._button_center(b) - event.position
		else:
			_dragging = false
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		move_button(touch.edit_selected, event.position + _drag_offset)
		accept_event()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("release_mouse"):
		close()
		get_viewport().set_input_as_handled()
