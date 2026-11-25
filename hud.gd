extends CanvasLayer
## On-screen HUD: health, score, wave (and the boss health bar), weapon,
## ammo and grenades, FPS, crosshair, sniper scope, pickup messages, the
## wave banner, the pause menu and the Game Over screen (with the XP, coins
## and level the match earned), plus the progression popups: LEVEL UP and
## mission / achievement / map star notices (top right). This layer keeps
## running while the game is paused so its menus work.
##
## Pausing: the II button (top right), Esc, or losing window focus. On a
## computer, the browser giving up the mouse lock (it does that on Esc) also
## pauses the game.

signal retry_requested
signal main_menu_requested
## READY in the shop: start the next wave now.
signal shop_ready

const CombatFeedback := preload("res://combat_feedback.gd")
const ShopMenu := preload("res://ui/shop_menu.gd")
const ReviveScreen := preload("res://ui/revive_screen.gd")
const Economy := preload("res://economy.gd")
const Progression := preload("res://progression_config.gd")
const COLOR_CASH := Color(0.45, 1.0, 0.45)
const CASH_POP_TIME := 0.9
const MESSAGE_TIME := 1.5   # seconds a pickup message stays on screen
const BANNER_TIME := 2.2    # seconds the "Wave X" banner stays up

@onready var health_label: Label = $HealthLabel
@onready var score_label: Label = $ScoreLabel
@onready var wave_label: Label = $WaveLabel
@onready var ammo_label: Label = $AmmoLabel
@onready var weapon_label: Label = $WeaponLabel
@onready var grenade_label: Label = $GrenadeLabel
@onready var boss_bar: ProgressBar = $BossBar
@onready var boss_name: Label = $BossBar/BossName
@onready var message_label: Label = $MessageLabel
@onready var crosshair: Control = $Crosshair
@onready var aim_dot: Control = $AimDot
@onready var scope_overlay: ColorRect = $ScopeOverlay
@onready var touch_controls: Control = $TouchControls
@onready var damage_flash: ColorRect = $DamageFlash
@onready var fps_label: Label = $FpsLabel
@onready var wave_banner: Control = $WaveBanner
@onready var banner_title: Label = $WaveBanner/Title
@onready var banner_sub: Label = $WaveBanner/Sub
@onready var pause_button: Button = $PauseButton
@onready var pause_menu: Control = $PauseMenu
@onready var resume_button: Button = %ResumeButton
@onready var settings_menu: Control = %SettingsMenu
@onready var game_over_panel: Control = $GameOverPanel
@onready var waves_label: Label = %WavesLabel
@onready var kills_label: Label = %KillsLabel
@onready var final_score_label: Label = %FinalScoreLabel
@onready var best_label: Label = %BestLabel
@onready var retry_button: Button = %RetryButton

var is_game_over := false
## Hit markers, headshot / kill streak popups, damage numbers and the
## low-health effects (combat_feedback.gd). Drawn over the 3D view, under
## the touch controls and the rest of the HUD.
var feedback: CombatFeedback
## The between-waves shop (ui/shop_menu.gd); main.gd sets its economy and player.
var shop: ShopMenu
## "Watch ad to revive" when the player dies (ui/revive_screen.gd).
var revive_screen: ReviveScreen
var _touch_was_visible := false
## Shown during the break between waves; opens the shop.
var shop_button: Button
var cash_label: Label
var armor_bar: ProgressBar
var game_over_cash_label: Label
## Game Over: XP and coins earned, the level bar, missions and stars.
var game_over_progress_label: Label
var game_over_level_label: Label
var game_over_level_bar: ProgressBar
## The "LEVEL UP" popup (show_level_up()).
var level_up_panel: PanelContainer
var _level_up_title: Label
var _level_up_sub: Label
var _level_up_tween: Tween
## Mission / achievement / star notices, top right (show_toast()).
var _toast_box: VBoxContainer
var _cash_pop: Label
var _cash_pop_tween: Tween
var _powerup_box: VBoxContainer
var _powerup_labels := {}     # kind -> Label
var _shop_available := false
var _last_health := -1
var _flash_tween: Tween
var _message_tween: Tween
var _banner_tween: Tween
var _fps_timer := 0.0
var _was_captured := false
var _aiming := false
var _sight := "iron"


func _ready() -> void:
	feedback = CombatFeedback.new()
	feedback.name = "CombatFeedback"
	add_child(feedback)
	move_child(feedback, scope_overlay.get_index() + 1)
	_build_economy_hud()
	_build_progress_hud()
	revive_screen = ReviveScreen.new()
	revive_screen.name = "ReviveScreen"
	add_child(revive_screen)
	move_child(revive_screen, level_up_panel.get_index())
	game_over_panel.visible = false
	pause_menu.visible = false
	settings_menu.visible = false
	pause_button.pressed.connect(pause)
	resume_button.pressed.connect(resume)
	%SettingsButton.pressed.connect(_open_settings)
	%MenuButton.pressed.connect(main_menu_requested.emit)
	settings_menu.closed.connect(_on_settings_closed)
	retry_button.pressed.connect(retry_requested.emit)
	%OverMenuButton.pressed.connect(main_menu_requested.emit)
	# Touches on the pause button shouldn't also turn the view.
	touch_controls.blockers.append(pause_button)


func _process(delta: float) -> void:
	# Frames per second, refreshed twice a second so the number is readable.
	_fps_timer -= delta
	if _fps_timer <= 0.0:
		_fps_timer = 0.5
		fps_label.text = "FPS: %d" % Engine.get_frames_per_second()

	# The browser releases the mouse lock on Esc without always passing the
	# key on, so treat losing the lock as a pause request.
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if _was_captured and not captured and not get_tree().paused:
		pause()
	_was_captured = captured


func _unhandled_input(event: InputEvent) -> void:
	if is_game_over or revive_screen.visible:
		return
	# B opens the shop during the break (keyboard).
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_B:
		if shop.visible:
			close_shop()
		elif _shop_available and not get_tree().paused:
			open_shop()
		get_viewport().set_input_as_handled()
		return
	if not event.is_action_pressed("release_mouse"):
		return
	if shop.visible:
		close_shop()
	elif settings_menu.visible:
		settings_menu.close()
	elif get_tree().paused:
		resume()
	else:
		pause()
	get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and DisplayServer.get_name() != "headless":
		pause()


func pause() -> void:
	if is_game_over or get_tree().paused or shop.visible or revive_screen.visible:
		return
	get_tree().paused = true
	touch_controls.reset()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_was_captured = false
	pause_button.visible = false
	pause_menu.visible = true
	_focus(resume_button)


func resume() -> void:
	if is_game_over:
		return
	settings_menu.visible = false
	pause_menu.visible = false
	pause_button.visible = true
	get_tree().paused = false
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func is_paused() -> bool:
	return pause_menu.visible


# --- Revive --------------------------------------------------------------------

## The player died with a revive left: "Watch ad to revive" / "No thanks"
## (main.gd pauses the game meanwhile).
func offer_revive() -> void:
	touch_controls.reset()
	_touch_was_visible = touch_controls.visible
	touch_controls.visible = false
	pause_button.visible = false
	shop_button.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_was_captured = false
	revive_screen.offer()


## Revived: the game controls come back.
func end_revive() -> void:
	touch_controls.visible = _touch_was_visible
	pause_button.visible = true
	shop_button.visible = _shop_available
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# --- Economy: cash, armor, power-ups and the shop ----------------------------

# Built in code: cash (top left, with a "+$" popup), active power-ups under
# it, the armor bar under the health, the SHOP button (bottom middle, during
# the break), the shop itself and the cash line on the Game Over screen.
func _build_economy_hud() -> void:
	cash_label = _hud_label(32, COLOR_CASH)
	cash_label.position = Vector2(16, 40)
	cash_label.text = "$0"
	_cash_pop = _hud_label(26, COLOR_CASH)
	_cash_pop.position = Vector2(16, 80)
	_cash_pop.modulate.a = 0.0
	_powerup_box = VBoxContainer.new()
	_powerup_box.position = Vector2(16, 116)
	_powerup_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_powerup_box)
	for kind: String in ["double_points", "insta_kill"]:
		var l := _hud_label(26, Economy.POWERUP_INFO[kind].color)
		l.visible = false
		remove_child(l)
		_powerup_box.add_child(l)
		_powerup_labels[kind] = l

	armor_bar = ProgressBar.new()
	armor_bar.show_percentage = false
	armor_bar.max_value = Economy.MAX_ARMOR
	armor_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	armor_bar.anchor_top = 1.0
	armor_bar.anchor_bottom = 1.0
	armor_bar.offset_left = 26
	armor_bar.offset_right = 226
	armor_bar.offset_top = -20
	armor_bar.offset_bottom = -8
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.55)
	bg.set_corner_radius_all(3)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.35, 0.7, 1.0)
	fill.set_corner_radius_all(3)
	armor_bar.add_theme_stylebox_override("background", bg)
	armor_bar.add_theme_stylebox_override("fill", fill)
	armor_bar.visible = false
	add_child(armor_bar)
	move_child(armor_bar, health_label.get_index() + 1)

	shop_button = Button.new()
	shop_button.theme = preload("res://ui/theme.tres")
	shop_button.text = "SHOP" if DisplayServer.is_touchscreen_available() else "SHOP  (B)"
	shop_button.add_theme_font_size_override("font_size", 34)
	shop_button.add_theme_color_override("font_color", COLOR_CASH)
	shop_button.focus_mode = Control.FOCUS_NONE
	shop_button.anchor_left = 0.5
	shop_button.anchor_right = 0.5
	shop_button.anchor_top = 1.0
	shop_button.anchor_bottom = 1.0
	shop_button.offset_left = -130
	shop_button.offset_right = 130
	shop_button.offset_top = -200
	shop_button.offset_bottom = -110
	shop_button.visible = false
	shop_button.pressed.connect(open_shop)
	add_child(shop_button)
	move_child(shop_button, pause_button.get_index())

	shop = ShopMenu.new()
	shop.name = "Shop"
	add_child(shop)
	shop.closed.connect(_on_shop_closed)
	shop.ready_pressed.connect(func() -> void:
		_on_shop_closed()
		shop_ready.emit())
	# Touches on the SHOP button and in the shop are for the GUI, not the game.
	touch_controls.blockers.append(shop_button)
	touch_controls.blockers.append(shop)

	game_over_cash_label = Label.new()
	game_over_cash_label.add_theme_font_size_override("font_size", 30)
	game_over_cash_label.add_theme_color_override("font_color", COLOR_CASH)
	game_over_cash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	final_score_label.get_parent().add_child(game_over_cash_label)
	final_score_label.get_parent().move_child(game_over_cash_label, final_score_label.get_index() + 1)


# --- Progression: level-ups, missions, achievements, stars -------------------

const COLOR_GOLD := Color(1.0, 0.8, 0.35)
const LEVEL_UP_TIME := 3.0
const TOAST_TIME := 3.5


func _build_progress_hud() -> void:
	_toast_box = VBoxContainer.new()
	_toast_box.anchor_left = 1.0
	_toast_box.anchor_right = 1.0
	_toast_box.offset_left = -470
	_toast_box.offset_right = -16
	_toast_box.offset_top = 110
	_toast_box.add_theme_constant_override("separation", 8)
	_toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_toast_box)

	level_up_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.06, 0.02, 0.88)
	style.border_color = COLOR_GOLD
	style.set_border_width_all(3)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(18)
	level_up_panel.add_theme_stylebox_override("panel", style)
	level_up_panel.anchor_left = 0.5
	level_up_panel.anchor_right = 0.5
	level_up_panel.offset_left = -260
	level_up_panel.offset_right = 260
	level_up_panel.offset_top = 150
	level_up_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	level_up_panel.visible = false
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	level_up_panel.add_child(box)
	_level_up_title = _popup_label(52, COLOR_GOLD)
	box.add_child(_level_up_title)
	_level_up_sub = _popup_label(24, Color.WHITE)
	_level_up_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_level_up_sub)
	add_child(level_up_panel)  # last: over the Game Over screen too

	# Game Over: under the cash line.
	var parent := final_score_label.get_parent()
	var at := game_over_cash_label.get_index() + 1
	game_over_progress_label = _popup_label(24, COLOR_GOLD)
	game_over_progress_label.mouse_filter = Control.MOUSE_FILTER_PASS
	parent.add_child(game_over_progress_label)
	parent.move_child(game_over_progress_label, at)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	game_over_level_label = _popup_label(24, Color.WHITE)
	row.add_child(game_over_level_label)
	game_over_level_bar = _xp_bar(Vector2(260, 18))
	row.add_child(game_over_level_bar)
	parent.add_child(row)
	parent.move_child(row, at + 1)
	# Room for the extra lines.
	var over_box := parent as Control
	over_box.offset_top = -330
	over_box.offset_bottom = 330


func _popup_label(font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 6)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## A gold XP bar (also used by the main menu).
static func _xp_bar(min_size: Vector2) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.custom_minimum_size = min_size
	bar.show_percentage = false
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.6)
	bg.set_corner_radius_all(4)
	var fill := StyleBoxFlat.new()
	fill.bg_color = COLOR_GOLD
	fill.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fill)
	return bar


## Progress.leveled_up: "LEVEL UP!  Level 5" and what it unlocks.
## On the Game Over screen the summary shows it instead (show_progress()).
func show_level_up(level: int, unlocks: Array) -> void:
	if is_game_over:
		return
	_level_up_title.text = "LEVEL UP!  %d" % level
	var sub := "+%d coins" % Progression.LEVEL_UP_COINS
	if not unlocks.is_empty():
		sub = "Unlocked: %s\n%s" % [", ".join(unlocks), sub]
	_level_up_sub.text = sub
	level_up_panel.visible = true
	level_up_panel.modulate.a = 0.0
	if _level_up_tween:
		_level_up_tween.kill()
	_level_up_tween = create_tween()
	_level_up_tween.tween_property(level_up_panel, "modulate:a", 1.0, 0.2)
	_level_up_tween.tween_interval(LEVEL_UP_TIME)
	_level_up_tween.tween_property(level_up_panel, "modulate:a", 0.0, 0.5)
	_level_up_tween.tween_callback(func() -> void: level_up_panel.visible = false)


func on_mission_completed(text: String, reward: int) -> void:
	show_toast("Mission complete: %s   +%d coins" % [text, reward], COLOR_CASH)


func on_achievement(title: String, reward: int) -> void:
	show_toast("Achievement: %s   +%d coins" % [title, reward], COLOR_GOLD)


func on_star_earned(_map_id: String, stars: int) -> void:
	show_toast("Map star %d of 3 earned!" % stars, COLOR_GOLD)


## A notice that stays a few seconds at the top right (several stack up).
func show_toast(text: String, color := Color.WHITE) -> Label:
	var l := _popup_label(22, color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.text = text
	_toast_box.add_child(l)
	var t := l.create_tween()
	t.tween_interval(TOAST_TIME)
	t.tween_property(l, "modulate:a", 0.0, 0.5)
	t.tween_callback(l.queue_free)
	return l


## Game Over: what the match earned (Progress.end_match()'s summary).
func show_progress(summary: Dictionary) -> void:
	if summary.is_empty():
		game_over_progress_label.text = ""
		return
	var lines := ["+%d XP     +%d coins" % [summary.xp, summary.coins]]
	if summary.stars > summary.stars_before:
		lines.append("Map stars: %d / 3" % summary.stars)
	if not summary.missions.is_empty():
		lines.append("Missions done: %d" % summary.missions.size())
	var lv: int = summary.level
	var up := lv - int(summary.start_level)
	var unlocked := []
	for l in range(int(summary.start_level) + 1, lv + 1):
		unlocked.append_array(Progress.unlocks_at(l))
	if not unlocked.is_empty():
		lines.append("Unlocked: %s" % ", ".join(unlocked))
	game_over_progress_label.text = "\n".join(lines)
	game_over_level_label.text = "Level %d%s" % [lv, "  LEVEL UP!" if up > 0 else ""]
	game_over_level_label.add_theme_color_override("font_color", COLOR_GOLD if up > 0 else Color.WHITE)
	var into := Progress.level_xp()
	game_over_level_bar.max_value = maxi(into.y, 1)
	game_over_level_bar.value = into.x if into.y > 0 else 1


func _hud_label(font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 6)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l


## Cash on the HUD; gained > 0 also shows a "+$" popup under it.
func set_cash(cash: int, gained := 0) -> void:
	cash_label.text = "$%d" % cash
	if shop.visible:
		shop.refresh()
	if gained <= 0:
		return
	_cash_pop.text = "+$%d" % gained
	_cash_pop.position = Vector2(16, 80)
	_cash_pop.modulate.a = 1.0
	if _cash_pop_tween:
		_cash_pop_tween.kill()
	_cash_pop_tween = create_tween().set_parallel()
	_cash_pop_tween.tween_property(_cash_pop, "position:y", 62.0, CASH_POP_TIME).set_ease(Tween.EASE_OUT)
	_cash_pop_tween.tween_property(_cash_pop, "modulate:a", 0.0, CASH_POP_TIME * 0.5).set_delay(CASH_POP_TIME * 0.5)


func set_armor(armor: int) -> void:
	armor_bar.value = armor
	armor_bar.visible = armor > 0


## Timed power-ups with their seconds left (match_economy.gd `active`).
func update_powerups(active: Dictionary) -> void:
	for kind: String in _powerup_labels:
		var l: Label = _powerup_labels[kind]
		l.visible = active.has(kind)
		if l.visible:
			l.text = "%s  %d" % [Economy.POWERUP_INFO[kind].name.to_upper(), ceili(active[kind])]


## The SHOP button shows during the break between waves.
func set_shop_available(on: bool) -> void:
	_shop_available = on
	shop_button.visible = on and not is_game_over
	if not on and shop.visible:
		shop.visible = false
		_on_shop_closed()


func open_shop() -> void:
	if not _shop_available or shop.visible or is_game_over:
		return
	get_tree().paused = true  # the break countdown waits
	touch_controls.reset()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_was_captured = false
	shop_button.visible = false
	pause_button.visible = false
	shop.open()


func close_shop() -> void:
	shop.close()


func _on_shop_closed() -> void:
	shop_button.visible = _shop_available and not is_game_over
	pause_button.visible = not is_game_over
	if not pause_menu.visible:
		get_tree().paused = false
		if not DisplayServer.is_touchscreen_available():
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _open_settings() -> void:
	pause_menu.visible = false
	settings_menu.open()


func _on_settings_closed() -> void:
	if get_tree().paused and not is_game_over:
		pause_menu.visible = true
		_focus(resume_button)


# Keyboard focus for menus; skipped on phones, where the outline looks odd.
func _focus(button: Button) -> void:
	if not DisplayServer.is_touchscreen_available():
		button.grab_focus()


func set_health(value: int) -> void:
	health_label.text = "Health: %d" % value
	feedback.set_health(value)
	# Losing health flashes the screen red.
	if _last_health != -1 and value < _last_health:
		flash_damage()
	_last_health = value


func flash_damage() -> void:
	if _flash_tween:
		_flash_tween.kill()
	damage_flash.color.a = 0.45
	_flash_tween = create_tween()
	_flash_tween.tween_property(damage_flash, "color:a", 0.0, 0.6)


func set_score(value: int) -> void:
	score_label.text = "Score: %d" % value


## Top-of-screen wave status, e.g. "Wave 3 · 7 left".
func set_wave(wave: int, enemies_left: int) -> void:
	wave_label.text = "Wave %d  ·  %d left" % [wave, enemies_left]


## Countdown during the break between waves.
func set_break(next_wave: int, seconds: int) -> void:
	wave_label.text = "Wave %d in %d" % [next_wave, seconds]
	banner_sub.text = "Next wave in %d" % seconds


## Big text in the upper middle of the screen. hold = 0 keeps it up until
## the next banner.
func show_banner(title: String, sub: String, hold := BANNER_TIME) -> void:
	banner_title.text = title
	banner_sub.text = sub
	if _banner_tween:
		_banner_tween.kill()
	_banner_tween = create_tween()
	_banner_tween.tween_property(wave_banner, "modulate:a", 1.0, 0.25)
	if hold > 0.0:
		_banner_tween.tween_interval(hold)
		_banner_tween.tween_property(wave_banner, "modulate:a", 0.0, 0.5)


## reserve = -1 means unlimited spare ammo.
func set_ammo(ammo: int, reserve: int, reloading: bool) -> void:
	if reloading:
		ammo_label.text = "Reloading..."
	else:
		ammo_label.text = "%d / %s" % [ammo, "∞" if reserve < 0 else str(reserve)]


func set_weapon(weapon_name: String) -> void:
	weapon_label.text = weapon_name


func set_grenades(count: int) -> void:
	grenade_label.text = "Grenades: %d" % count


## Boss health bar under the wave counter (shown on boss waves).
func show_boss(title: String, hp: int, max_hp: int) -> void:
	boss_name.text = title.to_upper()
	boss_bar.max_value = max_hp
	boss_bar.value = hp
	boss_bar.visible = true


func set_boss_health(hp: int, max_hp: int) -> void:
	boss_bar.max_value = max_hp
	boss_bar.value = hp


func hide_boss() -> void:
	boss_bar.visible = false


## Sniper scope on/off: black lens overlay instead of the normal crosshair.
func set_scoped(scoped: bool) -> void:
	var size := scope_overlay.get_viewport_rect().size
	scope_overlay.material.set_shader_parameter("aspect", size.x / maxf(size.y, 1.0))
	scope_overlay.visible = scoped
	_update_crosshair()


## Aiming with any weapon: the sights (or the scope) replace the crosshair.
## Iron sights also get a small dot, so the exact aim point stays clear.
func set_aiming(aiming: bool, sight := "iron") -> void:
	_aiming = aiming
	_sight = sight
	_update_crosshair()


func _update_crosshair() -> void:
	crosshair.visible = not _aiming and not scope_overlay.visible and not is_game_over
	aim_dot.visible = _aiming and _sight == "iron" and not is_game_over


## A short notice in the middle of the screen, e.g. "Picked up Shotgun".
func show_message(text: String) -> void:
	message_label.text = text
	if _message_tween:
		_message_tween.kill()
	message_label.modulate.a = 1.0
	_message_tween = create_tween()
	_message_tween.tween_interval(MESSAGE_TIME)
	_message_tween.tween_property(message_label, "modulate:a", 0.0, 0.4)


func show_game_over(waves: int, kills: int, score: int, best: int, new_best: bool, cash_earned := 0) -> void:
	is_game_over = true
	feedback.clear()
	shop.visible = false
	shop_button.visible = false
	level_up_panel.visible = false  # the Game Over screen shows the level instead
	game_over_cash_label.text = "Cash earned: $%d" % cash_earned
	crosshair.visible = false
	scope_overlay.visible = false
	touch_controls.visible = false
	aim_dot.visible = false
	pause_button.visible = false
	pause_menu.visible = false
	settings_menu.visible = false
	wave_banner.modulate.a = 0.0
	boss_bar.visible = false
	waves_label.text = "Waves survived: %d" % waves
	kills_label.text = "Kills: %d" % kills
	final_score_label.text = "Score: %d" % score
	best_label.text = "New best score!" if new_best else "Best: %d" % best
	game_over_panel.visible = true
	_focus(retry_button)
