extends Control
## The Training Arena's HUD parts (training/training.gd adds it to the HUD):
##  - the hit stats (top left): shots, hits, accuracy, headshots, DPS;
##  - TRAIN (top right, next to the pause button, or T): the training panel,
##    which pauses the game like the pause menu: spawn dummies, dummies
##    walking, unlimited ammo / grenades, reset targets, stats and head
##    zones on/off, the three challenges with their bests, exit;
##  - TAKE <gun> (bottom middle, or E) next to the weapon rack.

const Config := preload("res://training_config.gd")
const EnemyTypes := preload("res://enemy_types.gd")
const Weapons := preload("res://weapon_stats.gd")
const THEME := preload("res://ui/theme.tres")
const COLOR_GOLD := Color(1.0, 0.8, 0.35)
const COLOR_GREEN := Color(0.55, 0.95, 0.55)

## The training scene (set before adding this).
var training: Node
## The rack slot the TAKE button would take (-1 = none in reach).
var take_index := -1
var stats_label: Label
var train_button: Button
var take_button: Button
var panel: Control
var stop_button: Button
var toggles := {}             # name -> CheckButton
var challenge_buttons := {}   # id -> Button
var _stats_timer := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	var hud: CanvasLayer = training.hud
	var touch := DisplayServer.is_touchscreen_available()

	stats_label = Label.new()
	stats_label.position = Vector2(16, 44)
	stats_label.add_theme_font_size_override("font_size", 22)
	stats_label.add_theme_color_override("font_outline_color", Color.BLACK)
	stats_label.add_theme_constant_override("outline_size", 6)
	stats_label.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(stats_label)

	train_button = _button("TRAIN", 22)
	train_button.anchor_left = 1.0
	train_button.anchor_right = 1.0
	train_button.offset_left = -216
	train_button.offset_right = -106
	train_button.offset_top = 16
	train_button.offset_bottom = 96
	train_button.pressed.connect(open_panel)
	add_child(train_button)

	take_button = _button("TAKE", 30)
	take_button.add_theme_color_override("font_color", COLOR_GOLD)
	take_button.anchor_left = 0.5
	take_button.anchor_right = 0.5
	take_button.anchor_top = 1.0
	take_button.anchor_bottom = 1.0
	take_button.offset_left = -170
	take_button.offset_right = 170
	take_button.offset_top = -200
	take_button.offset_bottom = -116
	take_button.visible = false
	# In-game buttons never take keyboard focus (Space would press them).
	train_button.focus_mode = FOCUS_NONE
	take_button.focus_mode = FOCUS_NONE
	take_button.pressed.connect(func() -> void:
		if take_index >= 0:
			training.take_weapon(take_index))
	add_child(take_button)

	_build_panel(touch)
	hud.touch_controls.blockers.append(train_button)
	hud.touch_controls.blockers.append(take_button)
	hud.touch_controls.blockers.append(panel)
	update_stats()


func _process(delta: float) -> void:
	_stats_timer -= delta
	if _stats_timer <= 0.0:
		_stats_timer = 0.1
		update_stats()
	# The pause menu (or Game Over) hides the TRAIN button with the pause button.
	train_button.visible = training.hud.pause_button.visible and not panel.visible


# GUI buttons only hear the first finger (as an emulated mouse), so TAKE with
# another finger (while walking) is handled here.
func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch and event.pressed and event.index > 0 and take_index >= 0 \
			and take_button.is_visible_in_tree() and not get_tree().paused \
			and take_button.get_global_rect().has_point(event.position):
		training.take_weapon(take_index)


func _unhandled_input(event: InputEvent) -> void:
	if panel.visible and (event.is_action_pressed("release_mouse")
			or (event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_T)):
		close_panel()
		get_viewport().set_input_as_handled()


func update_stats() -> void:
	stats_label.visible = toggles.get("stats") == null or toggles.stats.button_pressed
	if not stats_label.visible:
		return
	stats_label.text = "Shots %d   Hits %d\nAccuracy %d%%   Headshots %d%%\nDPS (last target) %d" % [
		training.shots, training.hits, roundi(training.accuracy()), roundi(training.headshot_share()),
		roundi(training.last_dps)]


## The weapon rack slot in reach (-1 = none): shows / hides TAKE.
func set_take(index: int) -> void:
	if index == take_index:
		return
	take_index = index
	take_button.visible = index >= 0
	if index >= 0:
		var n: String = Weapons.LIST[index].name.to_upper()
		take_button.text = "TAKE %s" % n if DisplayServer.is_touchscreen_available() else "TAKE %s  (E)" % n


# --- The panel ---------------------------------------------------------------------

## Opens the training panel (pauses the game, like the pause menu).
func open_panel() -> void:
	var hud: CanvasLayer = training.hud
	if panel.visible or get_tree().paused or hud.is_game_over:
		return
	get_tree().paused = true
	hud.touch_controls.reset()
	training.player.cancel_grenade()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	hud._was_captured = false
	hud.pause_button.visible = false
	refresh()
	panel.visible = true
	if not DisplayServer.is_touchscreen_available():
		(panel.find_child("Resume", true, false) as Button).grab_focus()


func close_panel() -> void:
	if not panel.visible:
		return
	panel.visible = false
	training.hud.pause_button.visible = true
	get_tree().paused = false
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Toggles and the challenge bests from the training state.
func refresh() -> void:
	toggles.walk.set_pressed_no_signal(training.dummies_walk)
	toggles.ammo.set_pressed_no_signal(training.player.infinite_ammo)
	toggles.grenades.set_pressed_no_signal(training.player.infinite_grenades)
	toggles.zones.set_pressed_no_signal(training.show_zones)
	for id: String in challenge_buttons:
		var c: Dictionary = Config.CHALLENGES[id]
		var best := Config.format_best(id, Settings.training_best(id))
		challenge_buttons[id].text = "%s\nBest: %s" % [c.name, best]
	stop_button.visible = training.challenge != ""


func _build_panel(touch: bool) -> void:
	panel = Control.new()
	panel.name = "TrainingPanel"
	panel.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	panel.theme = THEME
	panel.visible = false
	add_child(panel)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	panel.add_child(dim)
	var frame := PanelContainer.new()
	frame.set_anchors_and_offsets_preset(PRESET_CENTER)
	frame.offset_left = -600
	frame.offset_right = 600
	frame.offset_top = -340
	frame.offset_bottom = 340
	panel.add_child(frame)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	frame.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 10)
	scroll.add_child(box)

	var title := _label("Training", 40, COLOR_GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var sub := _label("Practice only: no XP, coins, missions or achievements here.", 18, Color(1, 1, 1, 0.7))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 22)
	box.add_child(cols)

	# Dummies.
	var dummies := _column(cols, "Dummies")
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	dummies.add_child(grid)
	for kind: String in Config.DUMMY_KINDS:
		var b := _button("+ " + EnemyTypes.TYPES[kind].name, 20)
		b.name = "Spawn_" + kind
		b.custom_minimum_size = Vector2(170, 50)
		b.pressed.connect(func() -> void: training.spawn_dummy_random(kind))
		grid.add_child(b)
	toggles.walk = _toggle(dummies, "Dummies walk", func(on: bool) -> void: training.set_dummies_walk(on))
	toggles.zones = _toggle(dummies, "Show head zones", func(on: bool) -> void: training.set_show_zones(on))
	var clear := _button("Remove spawned dummies", 20)
	clear.pressed.connect(training.clear_spawned_dummies)
	dummies.add_child(clear)

	# Options.
	var options := _column(cols, "Options")
	toggles.ammo = _toggle(options, "Unlimited ammo", func(on: bool) -> void: training.set_infinite_ammo(on))
	toggles.grenades = _toggle(options, "Infinite grenades", func(on: bool) -> void: training.set_infinite_grenades(on))
	toggles.stats = _toggle(options, "Show hit stats", func(_on: bool) -> void: update_stats())
	toggles.stats.button_pressed = true
	var reset := _button("Reset targets", 22)
	reset.name = "ResetTargets"
	reset.pressed.connect(training.reset_targets)
	options.add_child(reset)
	var reset_stats := _button("Reset stats", 22)
	reset_stats.pressed.connect(func() -> void:
		training.reset_stats()
		update_stats())
	options.add_child(reset_stats)

	# Challenges.
	var challenges := _column(cols, "Challenges")
	for id: String in Config.CHALLENGES:
		var b := _button("", 20)
		b.name = "Challenge_" + id
		b.custom_minimum_size = Vector2(0, 66)
		b.tooltip_text = Config.CHALLENGES[id].info
		b.pressed.connect(func() -> void:
			training.start_challenge(id)
			close_panel())
		challenges.add_child(b)
		challenge_buttons[id] = b
		var info := _label(Config.CHALLENGES[id].info, 16, Color(1, 1, 1, 0.65))
		info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		challenges.add_child(info)
	stop_button = _button("Stop challenge", 20)
	stop_button.pressed.connect(func() -> void:
		training.stop_challenge()
		refresh())
	challenges.add_child(stop_button)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 24)
	box.add_child(row)
	var resume := _button("Resume", 26)
	resume.name = "Resume"
	resume.custom_minimum_size = Vector2(260, 60)
	resume.pressed.connect(close_panel)
	row.add_child(resume)
	var leave := _button("Exit to Main Menu", 26)
	leave.name = "Exit"
	leave.custom_minimum_size = Vector2(300, 60)
	leave.pressed.connect(training.exit_to_menu)
	row.add_child(leave)
	if not touch:
		var keys := _label("T: this panel   E: take a gun from the rack   1-8: weapons", 16, Color(1, 1, 1, 0.55))
		keys.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(keys)


func _column(parent: Container, heading: String) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 8)
	parent.add_child(col)
	col.add_child(_label(heading, 26, COLOR_GREEN))
	return col


func _toggle(parent: Container, text: String, on_toggle: Callable) -> CheckButton:
	var t := CheckButton.new()
	t.text = text
	t.add_theme_font_size_override("font_size", 21)
	t.custom_minimum_size = Vector2(0, 48)
	t.toggled.connect(on_toggle)
	parent.add_child(t)
	return t


func _button(text: String, font_size: int) -> Button:
	var b := Button.new()
	b.theme = THEME
	b.text = text
	b.add_theme_font_size_override("font_size", font_size)
	b.custom_minimum_size = Vector2(0, 52)
	if DisplayServer.is_touchscreen_available():
		b.focus_mode = FOCUS_NONE
	return b


func _label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l
