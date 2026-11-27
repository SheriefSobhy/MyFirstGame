extends Control
## Main menu: Play (goes on to the map selection screen), Armory,
## Achievements, Settings and Quit, with the player's level bar and coins,
## and today's daily missions on the right. The first visit of the day shows
## the daily login reward (a 7-day streak).
## The title shown here is the project name (Project Settings >
## Application > Config > Name, in project.godot), which is also the window
## and browser tab title. Change it there to rename the game.

const MAP_SELECT_SCENE := "res://ui/map_select.tscn"
const Config := preload("res://progression_config.gd")
const ArmoryMenu := preload("res://ui/armory_menu.gd")
const LoadingScreen := preload("res://ui/loading_screen.gd")
const WeaponTour := preload("res://weapon_tour.gd")
const SoldiersDemo := preload("res://soldiers/soldiers_demo.gd")
const Maps := preload("res://maps.gd")
const AchievementsMenu := preload("res://ui/achievements_menu.gd")
const COLOR_GOLD := Color(1.0, 0.8, 0.35)
const COLOR_DONE := Color(0.45, 1.0, 0.45)

@onready var title_label: Label = %Title
@onready var best_label: Label = %Best
@onready var play_button: Button = %PlayButton
@onready var training_button: Button = %TrainingButton
@onready var armory_button: Button = %ArmoryButton
@onready var achievements_button: Button = %AchievementsButton
@onready var settings_button: Button = %SettingsButton
@onready var quit_button: Button = %QuitButton
@onready var loading_label: Label = %Loading
@onready var settings_menu: Control = %SettingsMenu
@onready var level_label: Label = %LevelLabel
@onready var xp_bar: ProgressBar = %XpBar
@onready var xp_label: Label = %XpLabel
@onready var coins_label: Label = %CoinsLabel
@onready var mission_list: VBoxContainer = %MissionList
@onready var reset_label: Label = %ResetLabel
@onready var login_label: Label = %LoginLabel

## Soldiers (Test) mode (soldiers/soldiers_mode.gd), under Training.
var soldiers_button: Button
var armory: ArmoryMenu
var achievements: AchievementsMenu
## The daily login reward popup (shown once a day).
var login_popup: Control
var login_claim_button: Button
var _login_box: VBoxContainer
var _reset_timer := 0.0


func _ready() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	title_label.text = ProjectSettings.get_setting("application/config/name", "Dead Perimeter")
	# A web page can't close itself, so there's no Quit button in the browser.
	quit_button.visible = not OS.has_feature("web")
	if WeaponTour.requested():  # debug builds: weapon_tour.gd
		LoadingScreen.go.call_deferred(get_tree(), Maps.LIST[0])
		return
	if SoldiersDemo.requested():  # debug builds: soldiers/soldiers_demo.gd
		LoadingScreen.go.call_deferred(get_tree(), Maps.SOLDIERS)
		return

	armory = ArmoryMenu.new()
	armory.name = "Armory"
	add_child(armory)
	achievements = AchievementsMenu.new()
	achievements.name = "Achievements"
	add_child(achievements)
	move_child(settings_menu, -1)
	_build_login_popup()

	soldiers_button = training_button.duplicate()
	soldiers_button.name = "SoldiersButton"
	soldiers_button.text = "Soldiers (Test)"
	training_button.add_sibling(soldiers_button)
	_compact_buttons()
	play_button.pressed.connect(_on_play)
	training_button.pressed.connect(_on_training)
	soldiers_button.pressed.connect(_on_soldiers)
	armory_button.pressed.connect(armory.open)
	achievements_button.pressed.connect(achievements.open)
	settings_button.pressed.connect(settings_menu.open)
	quit_button.pressed.connect(get_tree().quit)
	for overlay: Control in [settings_menu, armory, achievements]:
		overlay.closed.connect(_focus_default)
	Progress.changed.connect(refresh)
	Music.play_menu()
	Progress.refresh_daily()
	refresh()
	if Progress.login_reward_ready():
		show_login_popup()
	else:
		_focus_default()


func _process(delta: float) -> void:
	_reset_timer -= delta
	if _reset_timer <= 0.0:
		_reset_timer = 1.0
		Progress.refresh_daily()  # past midnight: new missions
		_update_reset_label()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("release_mouse") and settings_menu.visible:
		settings_menu.close()
		get_viewport().set_input_as_handled()


func _focus_default() -> void:
	# Keyboard/gamepad focus; skipped on phones, where the outline just looks odd.
	if not DisplayServer.is_touchscreen_available():
		play_button.grab_focus()


## Level bar, coins, best score and the missions.
func refresh() -> void:
	if Settings.best_score > 0:
		# The best over all maps; each map's own best is on the map screen.
		best_label.text = "Best: %d   (wave %d)" % [Settings.best_score, Settings.best_wave]
	else:
		best_label.text = ""
	var lv := Progress.level()
	level_label.text = "Level %d" % lv
	var into := Progress.level_xp()
	if into.y > 0:
		xp_bar.max_value = into.y
		xp_bar.value = into.x
		xp_label.text = "%d / %d XP" % [into.x, into.y]
	else:
		xp_bar.max_value = 1
		xp_bar.value = 1
		xp_label.text = "MAX LEVEL"
	coins_label.text = "%d coins" % Progress.coins
	_refresh_missions()
	var day := Progress.login_day()
	login_label.text = "Login streak: day %d of %d" % [day, Config.LOGIN_REWARDS.size()]


func _refresh_missions() -> void:
	for c in mission_list.get_children():
		mission_list.remove_child(c)
		c.queue_free()
	for m: Dictionary in Progress.missions():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		var left := VBoxContainer.new()
		left.size_flags_horizontal = SIZE_EXPAND_FILL
		left.add_theme_constant_override("separation", 4)
		row.add_child(left)
		var text := Label.new()
		text.text = "%s    %d / %d" % [m.text, m.progress, m.target]
		text.add_theme_font_size_override("font_size", 21)
		if m.done:
			text.add_theme_color_override("font_color", COLOR_DONE)
		left.add_child(text)
		var bar := ProgressBar.new()
		bar.custom_minimum_size = Vector2(0, 12)
		bar.show_percentage = false
		bar.max_value = m.target
		bar.value = m.progress
		bar.add_theme_stylebox_override("background", xp_bar.get_theme_stylebox("background"))
		bar.add_theme_stylebox_override("fill", xp_bar.get_theme_stylebox("fill"))
		left.add_child(bar)
		var reward := Label.new()
		reward.custom_minimum_size = Vector2(120, 0)
		reward.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		reward.text = "DONE" if m.done else "+%d coins" % m.reward
		reward.add_theme_font_size_override("font_size", 20)
		reward.add_theme_color_override("font_color", COLOR_DONE if m.done else COLOR_GOLD)
		row.add_child(reward)
		mission_list.add_child(row)


func _update_reset_label() -> void:
	var t := Time.get_time_dict_from_system()
	var left: int = 86400 - (t.hour * 3600 + t.minute * 60 + t.second)
	reset_label.text = "New in %dh %02dm" % [left / 3600, (left % 3600) / 60]


# --- Daily login reward -----------------------------------------------------------

func _build_login_popup() -> void:
	login_popup = Control.new()
	login_popup.name = "LoginPopup"
	login_popup.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	login_popup.visible = false
	add_child(login_popup)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	login_popup.add_child(dim)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(PRESET_CENTER)
	panel.offset_left = -440
	panel.offset_right = 440
	panel.offset_top = -200
	panel.offset_bottom = 200
	login_popup.add_child(panel)
	var box := VBoxContainer.new()
	box.name = "Box"
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)
	_login_box = box
	var title := Label.new()
	title.text = "Daily Reward"
	title.add_theme_font_size_override("font_size", 44)
	title.add_theme_color_override("font_color", COLOR_GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var sub := Label.new()
	sub.name = "Sub"
	sub.add_theme_font_size_override("font_size", 22)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)
	var days := HBoxContainer.new()
	days.name = "Days"
	days.alignment = BoxContainer.ALIGNMENT_CENTER
	days.add_theme_constant_override("separation", 10)
	box.add_child(days)
	for i in Config.LOGIN_REWARDS.size():
		var cell := PanelContainer.new()
		cell.custom_minimum_size = Vector2(104, 96)
		var l := Label.new()
		l.text = "Day %d\n%d" % [i + 1, Config.LOGIN_REWARDS[i]]
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", 22)
		cell.add_child(l)
		days.add_child(cell)
	login_claim_button = Button.new()
	login_claim_button.custom_minimum_size = Vector2(340, 68)
	login_claim_button.size_flags_horizontal = SIZE_SHRINK_CENTER
	login_claim_button.add_theme_color_override("font_color", COLOR_GOLD)
	login_claim_button.pressed.connect(_claim_login)
	box.add_child(login_claim_button)


func show_login_popup() -> void:
	var day := Progress.login_day()
	var reward := Config.login_reward(day)
	var box := _login_box
	(box.get_node("Sub") as Label).text = "Day %d of %d: come back every day for bigger rewards" % [day, Config.LOGIN_REWARDS.size()]
	var cells := box.get_node("Days").get_children()
	for i in cells.size():
		var cell: PanelContainer = cells[i]
		var style := StyleBoxFlat.new()
		style.set_corner_radius_all(8)
		style.set_border_width_all(3)
		if i + 1 == day:
			style.bg_color = Color(0.3, 0.22, 0.06, 0.95)
			style.border_color = COLOR_GOLD
		elif i + 1 < day:
			style.bg_color = Color(0.1, 0.18, 0.1, 0.9)
			style.border_color = Color(0.45, 1.0, 0.45, 0.6)
		else:
			style.bg_color = Color(0.1, 0.1, 0.11, 0.9)
			style.border_color = Color(1, 1, 1, 0.15)
		cell.add_theme_stylebox_override("panel", style)
	login_claim_button.text = "Claim +%d coins" % reward
	login_popup.visible = true
	if not DisplayServer.is_touchscreen_available():
		login_claim_button.grab_focus()


func _claim_login() -> void:
	Progress.claim_login_reward()
	login_popup.visible = false
	refresh()
	_focus_default()


func _on_play() -> void:
	_disable_buttons()
	get_tree().change_scene_to_file(MAP_SELECT_SCENE)


## The Training Arena (always unlocked, earns nothing), through the loading screen.
func _on_training() -> void:
	_disable_buttons()
	LoadingScreen.go(get_tree(), Maps.TRAINING)


func _on_soldiers() -> void:
	_disable_buttons()
	LoadingScreen.go(get_tree(), Maps.SOLDIERS)


# The buttons under Play: a little smaller, so all six fit on a 720 px screen.
func _compact_buttons() -> void:
	for b: Button in [training_button, soldiers_button, armory_button, achievements_button, settings_button, quit_button]:
		b.add_theme_font_size_override("font_size", 27)
		for state in ["normal", "hover", "pressed", "focus", "disabled", "hover_pressed"]:
			var sb := b.get_theme_stylebox(state)
			if sb == null:
				continue
			sb = sb.duplicate()
			sb.content_margin_top = 6.0
			sb.content_margin_bottom = 6.0
			b.add_theme_stylebox_override(state, sb)


func _disable_buttons() -> void:
	for button: Button in [play_button, training_button, soldiers_button, armory_button, achievements_button, settings_button, quit_button]:
		button.disabled = true
