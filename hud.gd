extends CanvasLayer
## On-screen HUD: health, score, weapon and ammo, FPS, crosshair, sniper
## scope, pickup messages and the Game Over screen.
## This layer keeps running while the game is paused so the Restart button works.

signal restart_requested

const MESSAGE_TIME := 1.5   # seconds a pickup message stays on screen

@onready var health_label: Label = $HealthLabel
@onready var score_label: Label = $ScoreLabel
@onready var ammo_label: Label = $AmmoLabel
@onready var weapon_label: Label = $WeaponLabel
@onready var message_label: Label = $MessageLabel
@onready var crosshair: Control = $Crosshair
@onready var scope_overlay: ColorRect = $ScopeOverlay
@onready var touch_controls: Control = $TouchControls
@onready var damage_flash: ColorRect = $DamageFlash
@onready var fps_label: Label = $FpsLabel

var _last_health := -1
var _flash_tween: Tween
var _message_tween: Tween
var _fps_timer := 0.0
@onready var game_over_panel: Control = $GameOverPanel
@onready var final_score_label: Label = $GameOverPanel/Box/FinalScoreLabel
@onready var restart_button: Button = $GameOverPanel/Box/RestartButton


func _ready() -> void:
	game_over_panel.visible = false
	restart_button.pressed.connect(restart_requested.emit)


# Frames per second, refreshed twice a second so the number is readable.
func _process(delta: float) -> void:
	_fps_timer -= delta
	if _fps_timer <= 0.0:
		_fps_timer = 0.5
		fps_label.text = "FPS: %d" % Engine.get_frames_per_second()


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


## reserve = -1 means unlimited spare ammo.
func set_ammo(ammo: int, reserve: int, reloading: bool) -> void:
	if reloading:
		ammo_label.text = "Reloading..."
	else:
		ammo_label.text = "%d / %s" % [ammo, "∞" if reserve < 0 else str(reserve)]


func set_weapon(weapon_name: String) -> void:
	weapon_label.text = weapon_name


## Sniper scope on/off: black lens overlay instead of the normal crosshair.
func set_scoped(scoped: bool) -> void:
	var size := scope_overlay.get_viewport_rect().size
	scope_overlay.material.set_shader_parameter("aspect", size.x / maxf(size.y, 1.0))
	scope_overlay.visible = scoped
	crosshair.visible = not scoped


## A short notice in the middle of the screen, e.g. "Picked up Shotgun".
func show_message(text: String) -> void:
	message_label.text = text
	if _message_tween:
		_message_tween.kill()
	message_label.modulate.a = 1.0
	_message_tween = create_tween()
	_message_tween.tween_interval(MESSAGE_TIME)
	_message_tween.tween_property(message_label, "modulate:a", 0.0, 0.4)


func show_game_over(final_score: int) -> void:
	crosshair.visible = false
	scope_overlay.visible = false
	touch_controls.visible = false
	final_score_label.text = "Score: %d" % final_score
	game_over_panel.visible = true
	restart_button.grab_focus()
