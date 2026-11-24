extends Node3D
## Main game scene: wires the player, enemies and HUD together, runs the
## waves, keeps score, applies the graphics settings and handles Game Over,
## Retry and going back to the main menu.
##
## Waves: wave 1 has START_ENEMIES enemies and every wave adds
## ENEMIES_PER_WAVE more, each a little faster. New enemy types join the mix
## as the waves go on (see wave_kinds()), and every BOSS_EVERY-th wave is a
## boss wave with one Brute Boss (with a health bar on the HUD). Enemies spawn one at a time,
## with at most max_enemies in the yard at once. After a wave is cleared the
## player gets a short break (and some health back) before the next one.

const ENEMY_SCENE := preload("res://enemy.tscn")
const MENU_SCENE := "res://ui/main_menu.tscn"
const START_ENEMIES := 5
const ENEMIES_PER_WAVE := 2      # extra enemies each wave
const SPEED_PER_WAVE := 0.08     # +8% walking speed each wave...
const MAX_SPEED_SCALE := 2.0     # ...up to twice the wave 1 speed
const SPAWN_INTERVAL := 1.2      # seconds between spawns within a wave
const BREAK_TIME := 6.0          # seconds between waves
const WAVE_HEAL := 25            # health given back for clearing a wave
const KILL_POINTS := 10         # normal zombie; other types have their own (enemy_types.gd)
const WAVE_POINTS := 50          # x the wave number, for clearing a wave
const MAX_ENEMIES := 12      # cap so the arena (and phones) don't overflow
const PHONE_MAX_ENEMIES := 8
const SPAWN_SPREAD := 1.0    # random offset around a spawn point
const SAFE_SPAWN_DISTANCE := 10.0  # no spawning closer than this to the player
const BULLET_HOLE_SCENE := preload("res://effects/bullet_hole.tscn")
const SPARKS_SCENE := preload("res://effects/impact_sparks.tscn")
const BLOOD_SCENE := preload("res://effects/blood_hit.tscn")
const HIT_FLASH_MATERIAL := preload("res://effects/hit_flash_material.tres")
const EnemyTypes := preload("res://enemy_types.gd")

# When each enemy type starts to appear.
const RUNNER_WAVE := 3
const SOLDIER_WAVE := 4
const BRUTE_WAVE := 5           # the first brute is wave 5's boss
const EXPLODER_WAVE := 6
const BOSS_EVERY := 5
const BOSS_HP_PER_WAVE := 40    # extra boss health for each later boss wave
const BOSS_WAVE_SHARE := 0.6    # boss waves have fewer other enemies
const Explosion := preload("res://effects/explosion.gd")
const Grenade := preload("res://effects/grenade.gd")

enum Phase { FIGHT, BREAK, OVER }

## Which map this scene is (maps.gd id): the best score is saved per map.
@export var map_id := "yard"
## Gameplay music for this map (empty = the default track).
@export var music: AudioStream

var score := 0
var kills := 0
var wave := 0
var waves_survived := 0
var phase := Phase.FIGHT
var max_enemies := MAX_ENEMIES

var _to_spawn := 0     # enemies of this wave not spawned yet
var _spawn_queue: Array[String] = []   # their kinds, in spawn order
var _boss: Node = null
var _alive := 0        # spawned and not dead yet
var _break_left := 0.0
var _break_shown := -1

@onready var player: CharacterBody3D = $Player
@onready var hud: CanvasLayer = $HUD
@onready var enemies: Node3D = $Enemies
@onready var spawn_points: Array[Node] = $SpawnPoints.get_children()
@onready var spawn_timer: Timer = $SpawnTimer
@onready var wind: AudioStreamPlayer = $Wind
@onready var sun: DirectionalLight3D = $Sun
@onready var environment: Environment = $WorldEnvironment.environment


func _ready() -> void:
	# Enemies walk around obstacles using the pre-baked navmesh in
	# level_navmesh.res, and static objects are lit by the baked lightmap
	# (main.lmbake). If you change the level, run tools/rebake.bat to bake
	# both again.

	# Looping ambient wind, and the gameplay music.
	wind.stream.loop = true
	wind.play()
	Music.play_game(music)

	# Player -> HUD
	player.health_changed.connect(hud.set_health)
	player.ammo_changed.connect(hud.set_ammo)
	player.weapon_changed.connect(hud.set_weapon)
	player.grenades_changed.connect(hud.set_grenades)
	player.scope_changed.connect(hud.set_scoped)
	player.aim_changed.connect(hud.set_aiming)
	player.message.connect(hud.show_message)
	player.died.connect(_on_player_died)
	player.hit_taken.connect(hud.flash_damage)
	hud.retry_requested.connect(_on_retry)
	hud.main_menu_requested.connect(_on_main_menu)
	hud.touch_controls.player = player
	# The touch Aim button lights up while aiming.
	player.weapon_changed.connect(func(_name: String) -> void: hud.touch_controls.queue_redraw())
	player.scope_changed.connect(func(_on: bool) -> void: hud.touch_controls.queue_redraw())
	player.aim_changed.connect(func(_on: bool, _sight: String) -> void: hud.touch_controls.queue_redraw())
	player.grenades_changed.connect(func(_n: int) -> void: hud.touch_controls.queue_redraw())
	spawn_timer.wait_time = SPAWN_INTERVAL
	spawn_timer.timeout.connect(_on_spawn_tick)

	hud.set_health(player.health)
	player.emit_status()
	hud.set_score(score)

	if DisplayServer.is_touchscreen_available():
		max_enemies = PHONE_MAX_ENEMIES
	_apply_quality()
	Settings.changed.connect(_apply_quality)
	_prewarm_effects()

	start_wave(1)


func _process(delta: float) -> void:
	if phase != Phase.BREAK:
		return
	_break_left -= delta
	var seconds := ceili(_break_left)
	if seconds != _break_shown:
		_break_shown = seconds
		hud.set_break(wave + 1, seconds)
	if _break_left <= 0.0:
		start_wave(wave + 1)


static func enemies_in_wave(n: int) -> int:
	return START_ENEMIES + ENEMIES_PER_WAVE * (n - 1)


static func speed_in_wave(n: int) -> float:
	return minf(1.0 + SPEED_PER_WAVE * (n - 1), MAX_SPEED_SCALE)


## The enemy kinds in wave n (in spawn order): mostly normal zombies, with
## runners from wave 3, soldiers from 4, brutes from 5 (as the boss) and
## exploders from 6. Every 5th wave starts with the Brute Boss.
static func wave_kinds(n: int) -> Array[String]:
	var boss := is_boss_wave(n)
	var count := enemies_in_wave(n)
	if boss:
		count = ceili(count * BOSS_WAVE_SHARE)
	var special: Array[String] = []
	if n >= RUNNER_WAVE:
		for i in maxi(1, int(count * 0.3)):
			special.append("runner")
	if n >= SOLDIER_WAVE:
		for i in mini(1 + (n - SOLDIER_WAVE) / 2, 4):
			special.append("soldier")
	if n > BRUTE_WAVE and not boss:
		for i in mini(1 + (n - BRUTE_WAVE - 1) / 4, 3):
			special.append("brute")
	if n >= EXPLODER_WAVE:
		for i in mini(1 + (n - EXPLODER_WAVE) / 2, 4):
			special.append("exploder")
	var kinds: Array[String] = special
	for i in maxi(count - special.size(), 2):
		kinds.append("normal")
	kinds.shuffle()
	if boss:
		kinds.push_front("boss")
	return kinds


static func is_boss_wave(n: int) -> bool:
	return n % BOSS_EVERY == 0


static func boss_hp(n: int) -> int:
	return EnemyTypes.TYPES.boss.hp + BOSS_HP_PER_WAVE * (n / BOSS_EVERY - 1)


func start_wave(n: int) -> void:
	wave = n
	phase = Phase.FIGHT
	_spawn_queue = wave_kinds(n)
	_to_spawn = _spawn_queue.size()
	if is_boss_wave(n):
		hud.show_banner("Wave %d" % n, "BOSS WAVE  ·  %d enemies" % _to_spawn)
	else:
		hud.show_banner("Wave %d" % n, "%d enemies" % _to_spawn)
	hud.set_wave(wave, _to_spawn + _alive)
	spawn_timer.start()


func _on_spawn_tick() -> void:
	if _to_spawn <= 0:
		spawn_timer.stop()
		return
	# Dead bodies count too until they sink away, which keeps phones smooth.
	if enemies.get_child_count() >= max_enemies:
		return
	spawn_enemy()


func spawn_enemy() -> void:
	var enemy := ENEMY_SCENE.instantiate()
	enemy.kind = _spawn_queue.pop_front() if not _spawn_queue.is_empty() else "normal"
	enemy.speed_scale = speed_in_wave(wave)
	if enemy.kind == "boss":
		enemy.hp_override = boss_hp(wave)
		enemy.health_changed.connect(hud.set_boss_health)
		_boss = enemy
	var point: Node3D = _pick_spawn_point()
	var offset := Vector3(randf_range(-SPAWN_SPREAD, SPAWN_SPREAD), 0.0, randf_range(-SPAWN_SPREAD, SPAWN_SPREAD))
	enemy.position = point.position + offset
	enemy.died.connect(_on_enemy_died.bind(enemy))
	enemies.add_child(enemy)
	_to_spawn -= 1
	_alive += 1
	if enemy.kind == "boss":
		hud.show_boss(enemy.stats.name, enemy.hp, enemy.max_hp)
		hud.show_message("The Brute Boss is here!")


# A random spawn point that isn't right next to the player.
func _pick_spawn_point() -> Node3D:
	var far := spawn_points.filter(func(p: Node3D) -> bool:
		return p.global_position.distance_to(player.global_position) > SAFE_SPAWN_DISTANCE)
	return (far if not far.is_empty() else spawn_points).pick_random()


func _on_enemy_died(enemy: Node) -> void:
	_alive -= 1
	kills += 1
	# Exploders that blow themselves up give no points.
	if enemy.killed_by_player:
		score += enemy.stats.points
	hud.set_score(score)
	if enemy == _boss:
		_boss = null
		hud.show_message("Boss down!  +%d" % enemy.stats.points)
		get_tree().create_timer(1.0, false).timeout.connect(hud.hide_boss)
	if phase != Phase.FIGHT:
		return
	hud.set_wave(wave, _to_spawn + _alive)
	if _to_spawn <= 0 and _alive <= 0:
		_wave_cleared()


func _wave_cleared() -> void:
	waves_survived = wave
	score += WAVE_POINTS * wave
	hud.set_score(score)
	player.heal(WAVE_HEAL)
	hud.show_message("+%d health" % WAVE_HEAL)
	phase = Phase.BREAK
	_break_left = BREAK_TIME
	_break_shown = -1
	hud.show_banner("Wave %d cleared" % wave, "", BREAK_TIME - 0.6)


# Graphics quality from the settings screen (Low / Medium / High): shadows,
# fog, glow and the resolution the 3D scene is drawn at (it is scaled up to
# the screen; the HUD always stays sharp). Medium matches the old phone setup.
func _apply_quality() -> void:
	var vp := get_viewport()
	var flash_light: Light3D = player.get_node("%FlashLight")
	# Maps can mark some of their lamps as extras that Low quality turns off.
	for lamp: Node in get_tree().get_nodes_in_group("optional_lights"):
		lamp.visible = Settings.quality != Settings.Quality.LOW
	match Settings.quality:
		Settings.Quality.LOW:
			vp.scaling_3d_scale = 0.5
			vp.mesh_lod_threshold = 4.0
			sun.shadow_enabled = false
			environment.fog_enabled = false
			environment.glow_enabled = false
			flash_light.visible = false
		Settings.Quality.MEDIUM:
			vp.scaling_3d_scale = 0.6
			vp.mesh_lod_threshold = 4.0
			sun.shadow_enabled = true
			sun.directional_shadow_max_distance = 25.0
			RenderingServer.directional_shadow_atlas_set_size(1024, true)
			RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_HARD)
			environment.fog_enabled = true
			environment.glow_enabled = false
			flash_light.visible = false
		_:
			vp.scaling_3d_scale = 1.0
			vp.mesh_lod_threshold = 1.0
			sun.shadow_enabled = true
			sun.directional_shadow_max_distance = 30.0
			RenderingServer.directional_shadow_atlas_set_size(
					ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/size"), true)
			RenderingServer.directional_soft_shadow_filter_set_quality(
					ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality"))
			environment.fog_enabled = true
			environment.glow_enabled = true
			flash_light.visible = true


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
	# Grenade explosion (no sound or scorch mark) and the grenade model.
	var blast := Explosion.new()
	blast.with_sound = false
	add_child(blast)
	warm.append(blast)
	var grenade_model := Grenade.build_model()
	add_child(grenade_model)
	warm.append(grenade_model)
	# Every enemy type (models, colours and glow), outside the enemy group.
	for kind: String in EnemyTypes.TYPES:
		if kind == "normal":
			continue
		var e: Node3D = ENEMY_SCENE.instantiate()
		e.kind = kind
		e.silent = true
		e.remove_from_group("enemies")
		e.process_mode = Node.PROCESS_MODE_DISABLED
		e.get_node("CollisionShape3D").disabled = true
		add_child(e)
		warm.append(e)
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
	# All the gun models, and the sniper scope overlay (almost invisible).
	player.show_all_view_models(true)
	hud.scope_overlay.self_modulate.a = 0.02
	hud.scope_overlay.visible = true
	# Keep them for a few frames so they are really drawn, then remove them.
	for i in 3:
		await get_tree().process_frame
	muzzle.visible = false
	player.show_all_view_models(false)
	hud.scope_overlay.visible = false
	hud.scope_overlay.self_modulate.a = 1.0
	for node in warm:
		node.queue_free()


func _on_player_died() -> void:
	phase = Phase.OVER
	spawn_timer.stop()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var new_best: bool = Settings.submit_score(score, waves_survived, map_id)
	hud.show_game_over(waves_survived, kills, score, Settings.best_score_for(map_id), new_best)
	get_tree().paused = true  # freezes everything except the HUD and music


func _on_retry() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()


func _on_main_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file(MENU_SCENE)
