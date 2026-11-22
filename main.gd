extends Node3D
## Main game scene: wires the player, enemies and HUD together,
## keeps score, spawns enemies and handles Game Over / Restart.

const ENEMY_SCENE := preload("res://enemy.tscn")
const START_ENEMIES := 5
const MAX_ENEMIES := 12      # cap so the arena (and phones) don't overflow
const SPAWN_SPREAD := 1.0    # random offset around a spawn point
const PHONE_MAX_ENEMIES := 8
const PHONE_RENDER_SCALE := 0.6  # 3D resolution on phones (1.0 = full)
const BULLET_HOLE_SCENE := preload("res://effects/bullet_hole.tscn")
const SPARKS_SCENE := preload("res://effects/impact_sparks.tscn")
const BLOOD_SCENE := preload("res://effects/blood_hit.tscn")
const HIT_FLASH_MATERIAL := preload("res://effects/hit_flash_material.tres")

var score := 0
var max_enemies := MAX_ENEMIES

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
	player.hit_taken.connect(hud.flash_damage)
	hud.restart_requested.connect(_on_restart_requested)
	hud.touch_controls.player = player
	spawn_timer.timeout.connect(spawn_enemy)

	hud.set_health(player.health)
	hud.set_ammo(player.ammo, player.MAX_AMMO, false)
	hud.set_score(score)

	if DisplayServer.is_touchscreen_available():
		_use_phone_settings()
	_prewarm_effects()

	for i in START_ENEMIES:
		spawn_enemy()


# Cheaper rendering for phones: the 3D scene is drawn at a lower resolution
# and scaled up (the HUD stays sharp), shadows are smaller and hard-edged,
# glow is off, and the muzzle flash no longer lights up the scene.
func _use_phone_settings() -> void:
	get_viewport().scaling_3d_scale = PHONE_RENDER_SCALE
	RenderingServer.directional_shadow_atlas_set_size(1024, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_HARD)
	var sun: DirectionalLight3D = $Sun
	sun.directional_shadow_max_distance = 25.0
	$WorldEnvironment.environment.glow_enabled = false
	player.get_node("%FlashLight").visible = false
	max_enemies = PHONE_MAX_ENEMIES


# The first time an effect is drawn, the browser has to compile its shaders,
# which froze the game for a moment on the first shot or hit. Drawing each
# effect once, tiny and in front of the camera, while the level loads moves
# that pause to the start of the game.
func _prewarm_effects() -> void:
	var camera := get_viewport().get_camera_3d()
	var spot := camera.global_position - camera.global_basis.z * 2.0
	var warm: Array[Node3D] = []
	for scene: PackedScene in [BULLET_HOLE_SCENE, SPARKS_SCENE, BLOOD_SCENE]:
		var node: Node3D = scene.instantiate()
		add_child(node)
		warm.append(node)
	var flash_quad := MeshInstance3D.new()
	flash_quad.mesh = QuadMesh.new()
	flash_quad.material_override = HIT_FLASH_MATERIAL
	add_child(flash_quad)
	warm.append(flash_quad)
	for node in warm:
		node.global_position = spot
		node.scale = Vector3.ONE * 0.01
		for particles in node.find_children("*", "CPUParticles3D", true, false):
			particles.restart()
	var muzzle: Node3D = player.get_node("%MuzzleFlash")
	muzzle.visible = true
	# Keep them for a few frames so they are really drawn, then remove them.
	for i in 3:
		await get_tree().process_frame
	muzzle.visible = false
	for node in warm:
		node.queue_free()


func spawn_enemy() -> void:
	if enemies.get_child_count() >= max_enemies:
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
