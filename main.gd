extends Node3D
## Main game scene: wires the player, enemies and HUD together,
## keeps score, spawns enemies and handles Game Over / Restart.

const ENEMY_SCENE := preload("res://enemy.tscn")
const START_ENEMIES := 5
const MAX_ENEMIES := 12      # cap so the arena (and phones) don't overflow
const SPAWN_SPREAD := 2.0    # random offset around a spawn point

var score := 0

@onready var player: CharacterBody3D = $Player
@onready var hud: CanvasLayer = $HUD
@onready var enemies: Node3D = $Enemies
@onready var spawn_points: Array[Node] = $SpawnPoints.get_children()
@onready var spawn_timer: Timer = $SpawnTimer
@onready var wind: AudioStreamPlayer = $Wind


func _ready() -> void:
	# Enemies walk around obstacles using the pre-baked navmesh in
	# level_navmesh.res. If you change the level, select NavigationRegion3D
	# in the editor and click "Bake NavigationMesh" to update it.

	# Looping ambient wind.
	wind.stream.loop = true
	wind.play()

	# Player -> HUD
	player.health_changed.connect(hud.set_health)
	player.ammo_changed.connect(hud.set_ammo)
	player.died.connect(_on_player_died)
	hud.restart_requested.connect(_on_restart_requested)
	hud.touch_controls.player = player
	spawn_timer.timeout.connect(spawn_enemy)

	hud.set_health(player.health)
	hud.set_ammo(player.ammo, player.MAX_AMMO, false)
	hud.set_score(score)

	for i in START_ENEMIES:
		spawn_enemy()


func spawn_enemy() -> void:
	if enemies.get_child_count() >= MAX_ENEMIES:
		return
	var enemy := ENEMY_SCENE.instantiate()
	var point: Node3D = spawn_points.pick_random()
	var offset := Vector3(randf_range(-SPAWN_SPREAD, SPAWN_SPREAD), 0.0, randf_range(-SPAWN_SPREAD, SPAWN_SPREAD))
	enemy.position = point.position + offset
	enemy.died.connect(_on_enemy_died)
	enemies.add_child(enemy)


func _on_enemy_died() -> void:
	score += 1
	hud.set_score(score)


func _on_player_died() -> void:
	spawn_timer.stop()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	hud.show_game_over(score)
	get_tree().paused = true  # freezes everything except the HUD


func _on_restart_requested() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()
