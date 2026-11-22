extends CanvasLayer
## On-screen HUD: health, score, ammo, FPS, crosshair and the Game Over screen.
## This layer keeps running while the game is paused so the Restart button works.

signal restart_requested

@onready var health_label: Label = $HealthLabel
@onready var score_label: Label = $ScoreLabel
@onready var ammo_label: Label = $AmmoLabel
@onready var crosshair: Control = $Crosshair
@onready var touch_controls: Control = $TouchControls
@onready var damage_flash: ColorRect = $DamageFlash
@onready var fps_label: Label = $FpsLabel

var _last_health := -1
var _flash_tween: Tween
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


func set_ammo(ammo: int, max_ammo: int, reloading: bool) -> void:
	if reloading:
		ammo_label.text = "Reloading..."
	else:
		ammo_label.text = "Ammo: %d / %d" % [ammo, max_ammo]


func show_game_over(final_score: int) -> void:
	crosshair.visible = false
	touch_controls.visible = false
	final_score_label.text = "Score: %d" % final_score
	game_over_panel.visible = true
	restart_button.grab_focus()
