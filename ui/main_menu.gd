extends Control
## Main menu: Play, Settings and Quit.
## The title shown here is the project name (Project Settings >
## Application > Config > Name, in project.godot), which is also the window
## and browser tab title. Change it there to rename the game.

const GAME_SCENE := "res://main.tscn"

@onready var title_label: Label = %Title
@onready var best_label: Label = %Best
@onready var play_button: Button = %PlayButton
@onready var settings_button: Button = %SettingsButton
@onready var quit_button: Button = %QuitButton
@onready var loading_label: Label = %Loading
@onready var settings_menu: Control = %SettingsMenu


func _ready() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	title_label.text = ProjectSettings.get_setting("application/config/name", "Last Stand")
	if Settings.best_score > 0:
		best_label.text = "Best: %d   (wave %d)" % [Settings.best_score, Settings.best_wave]
	else:
		best_label.text = ""
	# A web page can't close itself, so there's no Quit button in the browser.
	quit_button.visible = not OS.has_feature("web")

	play_button.pressed.connect(_on_play)
	settings_button.pressed.connect(settings_menu.open)
	quit_button.pressed.connect(get_tree().quit)
	settings_menu.closed.connect(_focus_default)
	Music.play_menu()
	_focus_default()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("release_mouse") and settings_menu.visible:
		settings_menu.close()
		get_viewport().set_input_as_handled()


func _focus_default() -> void:
	# Keyboard/gamepad focus; skipped on phones, where the outline just looks odd.
	if not DisplayServer.is_touchscreen_available():
		play_button.grab_focus()


func _on_play() -> void:
	for button: Button in [play_button, settings_button, quit_button]:
		button.disabled = true
	loading_label.visible = true
	# Let "Loading..." draw before the level loads (that takes a moment).
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().change_scene_to_file(GAME_SCENE)
