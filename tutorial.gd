extends Control
## First-match tutorial (main.gd adds it to the HUD while
## Settings.tutorial_done is false): one short tip at a time, each done when
## the player does it: move, look, shoot, aim, switch weapon, grenade. Then
## `basics_done` (main.gd starts wave 1, so the yard is quiet until then) and,
## at the first break between waves, a last tip about the shop.
## Touch screens get touch tips and the button is pointed at
## (touch_controls.gd `highlight`); computers get keyboard and mouse tips.
## "Skip tutorial" (or Enter) ends it. Settings > Replay Tutorial brings it back.

signal basics_done
signal finished

const STEP_DONE_TIME := 0.9   # the "Nice!" between tips
const LOOK_NEEDED := 1.5      # radians of turning (left/right + up/down)
const MOVE_NEEDED := 2.5      # m walked
const COLOR_GOLD := Color(1.0, 0.8, 0.35)
const COLOR_DONE := Color(0.45, 1.0, 0.45)
const THEME := preload("res://ui/theme.tres")

## id, touch text, computer text, touch button to point at.
const STEPS := [
	{"id": "move", "touch": "Move with the joystick", "pc": "Move with W A S D", "button": "joy"},
	{"id": "look", "touch": "Drag your finger on the screen to look around", "pc": "Move the mouse to look around", "button": ""},
	{"id": "shoot", "touch": "Hold SHOOT to fire", "pc": "Click (left mouse button) to shoot", "button": "shoot"},
	{"id": "aim", "touch": "Tap AIM to aim down the sights", "pc": "Hold the right mouse button to aim", "button": "aim"},
	{"id": "switch", "touch": "Tap SWITCH for your other weapon\n(hold it for the weapon wheel)", "pc": "Press 1 / 2 or scroll the mouse wheel to switch weapon", "button": "switch"},
	{"id": "grenade", "touch": "Hold GRENADE to aim, let go to throw", "pc": "Hold G to aim a grenade, let go to throw", "button": "grenade"},
	{"id": "shop", "touch": "Wave cleared! Tap SHOP to buy weapons, ammo and upgrades", "pc": "Wave cleared! Press B to open the shop: weapons, ammo and upgrades", "button": ""},
]
const SHOP_STEP := 6

var player: Node
var hud: Node
var step := 0
var touch := false
var panel: PanelContainer
var skip_button: Button
var _count_label: Label
var _text_label: Label
var _done_left := 0.0       # > 0 while "Nice!" shows
var _start_pos := Vector3.ZERO
var _start_weapon := 0
var _start_grenades := 0
var _last_ammo := -1
var _last_weapon := -1
var _last_yaw := 0.0
var _last_pitch := 0.0
var _looked := 0.0
var _waiting_for_shop := false
var _over := false


func _init() -> void:
	theme = THEME
	process_mode = PROCESS_MODE_ALWAYS  # the shop tip is done when the (pausing) shop opens
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE


func _ready() -> void:
	touch = hud.touch_controls.visible
	panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.06, 0.82)
	style.border_color = COLOR_GOLD
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", style)
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.offset_left = -340
	panel.offset_right = 340
	panel.offset_top = 150
	panel.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = MOUSE_FILTER_IGNORE
	panel.add_child(box)
	var top := HBoxContainer.new()
	top.mouse_filter = MOUSE_FILTER_IGNORE
	box.add_child(top)
	_count_label = Label.new()
	_count_label.add_theme_font_size_override("font_size", 18)
	_count_label.add_theme_color_override("font_color", COLOR_GOLD)
	_count_label.size_flags_horizontal = SIZE_EXPAND_FILL
	top.add_child(_count_label)
	skip_button = Button.new()
	skip_button.text = "Skip tutorial" if touch else "Skip tutorial  (Enter)"
	skip_button.focus_mode = FOCUS_NONE
	skip_button.add_theme_font_size_override("font_size", 18)
	skip_button.pressed.connect(skip)
	top.add_child(skip_button)
	_text_label = Label.new()
	_text_label.add_theme_font_size_override("font_size", 28)
	_text_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_text_label)
	# Touches on Skip are for the button, not the game.
	hud.touch_controls.blockers.append(skip_button)
	_begin_step(0)


func _exit_tree() -> void:
	if hud != null and is_instance_valid(hud.touch_controls):
		hud.touch_controls.blockers.erase(skip_button)
		hud.touch_controls.highlight = ""


func _unhandled_input(event: InputEvent) -> void:
	if _over or not panel.visible:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode in [KEY_ENTER, KEY_KP_ENTER]:
		skip()
		get_viewport().set_input_as_handled()


func is_running() -> bool:
	return not _over


## The id of the tip on screen ("" when none).
func current_step() -> String:
	return STEPS[step].id if not _over and panel.visible else ""


func _begin_step(index: int) -> void:
	step = index
	_done_left = 0.0
	var s: Dictionary = STEPS[step]
	_count_label.text = ("Welcome!  " if step == 0 else "") + "Tutorial  %d / %d" % [step + 1, STEPS.size()]
	_text_label.text = s.touch if touch else s.pc
	_text_label.add_theme_color_override("font_color", Color.WHITE)
	panel.visible = true
	hud.touch_controls.highlight = s.button if touch else ""
	_start_pos = player.global_position
	_start_weapon = player.weapon_index
	_start_grenades = player.grenades
	_last_ammo = player.ammo()
	_last_weapon = player.weapon_index
	_last_yaw = player.rotation.y
	_last_pitch = player.head.rotation.x
	_looked = 0.0
	# Nothing to throw: skip the grenade tip.
	if s.id == "grenade" and player.grenades <= 0:
		_step_done()


func _process(delta: float) -> void:
	if _over or player == null:
		return
	if _waiting_for_shop:
		if hud._shop_available and not get_tree().paused:
			_waiting_for_shop = false
			_begin_step(SHOP_STEP)
		return
	if _done_left > 0.0:
		_done_left -= delta
		if _done_left <= 0.0:
			_next()
		return
	if get_tree().paused and STEPS[step].id != "shop":
		return
	if _check(STEPS[step].id):
		_step_done()


# Has the player done what the tip says?
func _check(id: String) -> bool:
	match id:
		"move":
			var d: Vector3 = player.global_position - _start_pos
			return Vector2(d.x, d.z).length() >= MOVE_NEEDED
		"look":
			_looked += absf(angle_difference(_last_yaw, player.rotation.y)) \
					+ absf(player.head.rotation.x - _last_pitch)
			_last_yaw = player.rotation.y
			_last_pitch = player.head.rotation.x
			return _looked >= LOOK_NEEDED
		"shoot":
			var shot: bool = player.weapon_index == _last_weapon and player.ammo() < _last_ammo
			_last_ammo = player.ammo()
			_last_weapon = player.weapon_index
			return shot
		"aim":
			return player.is_aiming()
		"switch":
			return player.weapon_index != _start_weapon
		"grenade":
			return player.grenades < _start_grenades
		"shop":
			# Opened the shop, or the break ended without it.
			return hud.shop.visible or not hud._shop_available
	return false


func _step_done() -> void:
	_text_label.text = "Nice!"
	_text_label.add_theme_color_override("font_color", COLOR_DONE)
	hud.touch_controls.highlight = ""
	_done_left = STEP_DONE_TIME
	if STEPS[step].id == "shop":
		_finish()


func _next() -> void:
	if step + 1 == SHOP_STEP:
		# The basics are done: the zombies come; the shop tip waits for the break.
		panel.visible = false
		_waiting_for_shop = true
		Settings.tutorial_done = true
		Settings.save_settings()
		basics_done.emit()
		return
	_begin_step(step + 1)


## Ends the tutorial now (the Skip button, Enter). The waves start if they
## haven't yet.
func skip() -> void:
	if _over:
		return
	var waves_started := _waiting_for_shop or step >= SHOP_STEP
	_finish()
	if not waves_started:
		basics_done.emit()


func _finish() -> void:
	if _over:
		return
	_over = true
	hud.touch_controls.highlight = ""
	Settings.tutorial_done = true
	Settings.save_settings()
	finished.emit()
	# "Nice!" stays a moment after the last tip; a skip hides at once.
	if _done_left > 0.0:
		var t := create_tween()
		t.tween_interval(STEP_DONE_TIME)
		t.tween_callback(queue_free)
	else:
		queue_free()
