extends CanvasLayer
## On-screen HUD: health, score, wave (and the boss health bar), weapon,
## ammo and grenades, FPS, crosshair, sniper scope, pickup messages, the
## wave banner, the pause menu and the Game Over screen. This layer keeps
## running while the game is paused so its menus work.
##
## Pausing: the II button (top right), Esc, or losing window focus. On a
## computer, the browser giving up the mouse lock (it does that on Esc) also
## pauses the game.

signal retry_requested
signal main_menu_requested

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
var _last_health := -1
var _flash_tween: Tween
var _message_tween: Tween
var _banner_tween: Tween
var _fps_timer := 0.0
var _was_captured := false
var _aiming := false
var _sight := "iron"


func _ready() -> void:
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
	if is_game_over or not event.is_action_pressed("release_mouse"):
		return
	if settings_menu.visible:
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
	if is_game_over or get_tree().paused:
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


func show_game_over(waves: int, kills: int, score: int, best: int, new_best: bool) -> void:
	is_game_over = true
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
