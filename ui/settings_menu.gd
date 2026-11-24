extends Control
## Settings screen, shared by the main menu and the pause menu.
## Changes apply right away; they are saved when the screen closes.

signal closed

const QUALITY_HINTS := [
	"No shadows, no fog, half resolution. Fastest.",
	"Hard shadows, fog, reduced resolution.",
	"Soft shadows, fog, glow, full resolution.",
]

@onready var master_slider: HSlider = %MasterSlider
@onready var music_slider: HSlider = %MusicSlider
@onready var sensitivity_slider: HSlider = %SensitivitySlider
@onready var master_value: Label = %MasterValue
@onready var music_value: Label = %MusicValue
@onready var sensitivity_value: Label = %SensitivityValue
@onready var quality_hint: Label = %QualityHint
@onready var back_button: Button = %BackButton
@onready var quality_buttons: Array[Button] = [%Low, %Medium, %High]
## On/off settings: the button and the Settings variable it switches.
@onready var toggles := {
	"damage_numbers": %DamageNumbers as CheckButton,
	"haptics": %Vibration as CheckButton,
	"aim_assist": %AimAssist as CheckButton,
}


func _ready() -> void:
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
	back_button.pressed.connect(close)
	visibility_changed.connect(func() -> void:
		if visible:
			_refresh())
	_refresh()


func open() -> void:
	visible = true
	if not DisplayServer.is_touchscreen_available():
		back_button.grab_focus()


func close() -> void:
	if not visible:
		return
	Settings.save_settings()
	visible = false
	closed.emit()


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
	_refresh_labels()


func _refresh_labels() -> void:
	master_value.text = "%d%%" % roundi(Settings.master_volume * 100.0)
	music_value.text = "%d%%" % roundi(Settings.music_volume * 100.0)
	sensitivity_value.text = "%.2fx" % Settings.look_sensitivity
	quality_hint.text = QUALITY_HINTS[Settings.quality]
