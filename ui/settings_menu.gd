extends Control
## Settings screen, shared by the main menu and the pause menu.
## Changes apply right away; they are saved when the screen closes.
## The frame rate row, Left-handed, Customize Controls and Replay Tutorial
## are built in code (under the on/off toggles).

signal closed

const ControlsEditor := preload("res://ui/controls_editor.gd")

var _reset_armed := false
## Customize Controls (made the first time it opens).
var controls_editor: ControlsEditor
var fps_buttons: Array[Button] = []
var left_handed_button: CheckButton
var customize_button: Button
var tutorial_button: Button

const QUALITY_HINTS := [
	"No shadows, no fog, half resolution. Fastest.",
	"Hard shadows, fog, reduced resolution.",
	"Soft shadows, fog, glow, full resolution.",
	"Picks Low, Medium or High from your frame rate when a match starts.",
]

@onready var master_slider: HSlider = %MasterSlider
@onready var music_slider: HSlider = %MusicSlider
@onready var sensitivity_slider: HSlider = %SensitivitySlider
@onready var master_value: Label = %MasterValue
@onready var music_value: Label = %MusicValue
@onready var sensitivity_value: Label = %SensitivityValue
@onready var quality_hint: Label = %QualityHint
@onready var back_button: Button = %BackButton
## Index = Settings.Quality (Low, Medium, High, Auto).
@onready var quality_buttons: Array[Button] = [%Low, %Medium, %High, %Auto]
## On/off settings: the button and the Settings variable it switches.
@onready var toggles := {
	"damage_numbers": %DamageNumbers as CheckButton,
	"haptics": %Vibration as CheckButton,
	"aim_assist": %AimAssist as CheckButton,
	"debug_unlock_all": %DebugUnlock as CheckButton,
}


func _ready() -> void:
	_build_extra_rows()
	sensitivity_slider.min_value = Settings.MIN_SENSITIVITY
	sensitivity_slider.max_value = Settings.MAX_SENSITIVITY
	var group := ButtonGroup.new()
	for i in quality_buttons.size():
		quality_buttons[i].button_group = group
		quality_buttons[i].pressed.connect(_on_quality.bind(i))
	master_slider.value_changed.connect(func(v: float) -> void:
		Settings.set_value("master_volume", v / 100.0)
		_refresh_labels())
	music_slider.value_changed.connect(func(v: float) -> void:
		Settings.set_value("music_volume", v / 100.0)
		_refresh_labels())
	sensitivity_slider.value_changed.connect(func(v: float) -> void:
		Settings.set_value("look_sensitivity", v)
		_refresh_labels())
	for key: String in toggles:
		var button: CheckButton = toggles[key]
		button.toggled.connect(func(on: bool) -> void: Settings.set_value(key, on))
	%AimAssist.tooltip_text = "Touch controls only: slower turning over enemies, and a gentle pull towards them when you aim"
	%DebugUnlock.tooltip_text = "For testing: start the next match with every weapon, and every level unlock (weapons, maps)"
	%DebugReset.tooltip_text = "For testing: back to level 1 with no coins, upgrades, skins, stars, achievements or best scores"
	%DebugReset.pressed.connect(_on_debug_reset)
	back_button.pressed.connect(close)
	visibility_changed.connect(func() -> void:
		if visible:
			_refresh())
	_refresh()


# Frame rate cap + Left-handed, then Customize Controls + Replay Tutorial.
func _build_extra_rows() -> void:
	var box: VBoxContainer = %QualityHint.get_parent()
	var fps_row := HBoxContainer.new()
	fps_row.name = "FpsRow"
	fps_row.add_theme_constant_override("separation", 14)
	var fps_label := Label.new()
	fps_label.text = "Frame Rate"
	fps_label.size_flags_horizontal = SIZE_EXPAND_FILL
	fps_row.add_child(fps_label)
	var group := ButtonGroup.new()
	for cap: int in Settings.FPS_CAPS:
		var b := Button.new()
		b.text = "%d FPS" % cap
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(130, 60)
		b.tooltip_text = "Saves battery" if cap == 30 else "Smoother"
		b.pressed.connect(func() -> void: Settings.set_value("fps_cap", cap))
		fps_row.add_child(b)
		fps_buttons.append(b)
	left_handed_button = CheckButton.new()
	left_handed_button.text = "Left-handed"
	left_handed_button.custom_minimum_size = Vector2(0, 56)
	left_handed_button.add_theme_font_size_override("font_size", 24)
	left_handed_button.tooltip_text = "Touch controls mirrored: joystick on the right, buttons on the left"
	left_handed_button.toggled.connect(func(on: bool) -> void: Settings.set_value("left_handed", on))
	fps_row.add_child(left_handed_button)
	box.add_child(fps_row)
	box.move_child(fps_row, box.get_node("ToggleRow").get_index() + 1)

	var controls_row := HBoxContainer.new()
	controls_row.name = "ControlsRow"
	controls_row.alignment = BoxContainer.ALIGNMENT_CENTER
	controls_row.add_theme_constant_override("separation", 18)
	customize_button = Button.new()
	customize_button.text = "Customize Controls"
	customize_button.custom_minimum_size = Vector2(300, 60)
	customize_button.tooltip_text = "Move and resize the touch buttons, change their opacity"
	customize_button.pressed.connect(open_controls_editor)
	controls_row.add_child(customize_button)
	tutorial_button = Button.new()
	tutorial_button.custom_minimum_size = Vector2(300, 60)
	tutorial_button.pressed.connect(_on_replay_tutorial)
	controls_row.add_child(tutorial_button)
	box.add_child(controls_row)
	box.move_child(controls_row, fps_row.get_index() + 1)


func open() -> void:
	visible = true
	if not DisplayServer.is_touchscreen_available():
		back_button.grab_focus()


func close() -> void:
	if not visible:
		return
	if controls_editor != null and controls_editor.visible:
		controls_editor.close()
	Settings.save_settings()
	visible = false
	closed.emit()


func open_controls_editor() -> void:
	if controls_editor == null:
		controls_editor = ControlsEditor.new()
		controls_editor.name = "ControlsEditor"
		add_child(controls_editor)
		controls_editor.closed.connect(func() -> void:
			if not DisplayServer.is_touchscreen_available():
				customize_button.grab_focus())
	controls_editor.open()


# The tutorial plays again at the start of the next match.
func _on_replay_tutorial() -> void:
	Settings.set_value("tutorial_done", false)
	Settings.save_settings()
	_refresh_labels()


# Two presses: the first asks, the second (within a few seconds) resets.
func _on_debug_reset() -> void:
	var button: Button = %DebugReset
	if not _reset_armed:
		_reset_armed = true
		button.text = "Press again to reset!"
		get_tree().create_timer(3.0, true).timeout.connect(_disarm_reset)
		return
	Progress.reset_all()
	_reset_armed = false
	button.text = "Progress reset"


func _disarm_reset() -> void:
	_reset_armed = false
	if is_instance_valid(self):
		(%DebugReset as Button).text = "Debug: reset progress"


func _on_quality(index: int) -> void:
	Settings.set_value("quality", index)
	_refresh_labels()


# Shows the saved values without triggering the change handlers.
func _refresh() -> void:
	master_slider.set_value_no_signal(roundf(Settings.master_volume * 100.0))
	music_slider.set_value_no_signal(roundf(Settings.music_volume * 100.0))
	sensitivity_slider.set_value_no_signal(Settings.look_sensitivity)
	for i in quality_buttons.size():
		quality_buttons[i].set_pressed_no_signal(i == Settings.quality)
	for key: String in toggles:
		(toggles[key] as CheckButton).set_pressed_no_signal(Settings.get(key))
	for i in fps_buttons.size():
		fps_buttons[i].set_pressed_no_signal(Settings.FPS_CAPS[i] == Settings.fps_cap)
	left_handed_button.set_pressed_no_signal(Settings.left_handed)
	# Resetting is for the menus, not the middle of a match.
	(%DebugReset as Button).visible = not Progress.in_match()
	_refresh_labels()


func _refresh_labels() -> void:
	master_value.text = "%d%%" % roundi(Settings.master_volume * 100.0)
	music_value.text = "%d%%" % roundi(Settings.music_volume * 100.0)
	sensitivity_value.text = "%.2fx" % Settings.look_sensitivity
	var hint: String = QUALITY_HINTS[Settings.quality]
	if Settings.quality == Settings.Quality.AUTO:
		if Settings.auto_quality >= 0:
			hint += "  Now: %s." % Settings.QUALITY_NAMES[Settings.auto_quality]
		else:
			hint += "  Measured in your next match."
	quality_hint.text = hint
	tutorial_button.text = "Tutorial: next match" if not Settings.tutorial_done else "Replay Tutorial"
	tutorial_button.disabled = not Settings.tutorial_done
