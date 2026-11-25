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
const Economy := preload("res://economy.gd")
const MatchEconomy := preload("res://match_economy.gd")
const BREAK_TIME := Economy.BREAK_TIME  # seconds between waves (waits while the shop is open)
const WAVE_HEAL := 25            # health given back for clearing a wave
const KILL_POINTS := 10         # normal zombie; other types have their own (enemy_types.gd)
const WAVE_POINTS := 50          # x the wave number, for clearing a wave
const MAX_ENEMIES := 12      # cap so the arena (and phones) don't overflow
const PHONE_MAX_ENEMIES := 8
const SPAWN_SPREAD := 1.0    # random offset around a spawn point
const SPAWN_OFF_MESH := 0.3  # m: further than this from its navmesh = not a place to spawn
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
const Tutorial := preload("res://tutorial.gd")
const AutoQuality := preload("res://auto_quality.gd")
const Atmosphere := preload("res://atmosphere.gd")

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
## Cash, the shop, power-ups (match_economy.gd).
var economy: MatchEconomy
## The first-match tutorial (tutorial.gd), null when not running.
var tutorial: Tutorial
## Graphics Auto measuring the frame rate (auto_quality.gd), null when not.
var auto_quality: AutoQuality
## Colour grade, dust, light shafts, probes, flickering lamps (atmosphere.gd);
## null on maps without one (the Training Arena).
var atmosphere: Node3D
## Revives left this match (economy.gd REVIVES_PER_MATCH).
var revives_left := Economy.REVIVES_PER_MATCH

var _to_spawn := 0     # enemies of this wave not spawned yet
var _spawn_queue: Array[String] = []   # their kinds, in spawn order
var _boss: Node = null
var _alive := 0        # spawned and not dead yet
var _break_left := 0.0
var _break_shown := -1
var _nav_regions := {}       # navigation layer -> its NavigationRegion3D
var _player_start := Vector3.ZERO
var _spawns_by_layer := {}   # navigation layer -> spawn points usable on it
var _nav_iteration_start := 0  # navigation map iteration when this scene loaded
var _nav_ready := false        # see navmesh_ready()

@onready var player: CharacterBody3D = $Player
@onready var hud: CanvasLayer = $HUD
@onready var enemies: Node3D = $Enemies
@onready var spawn_points: Array[Node] = $SpawnPoints.get_children()
@onready var spawn_timer: Timer = $SpawnTimer
@onready var wind: AudioStreamPlayer = $Wind
@onready var sun: DirectionalLight3D = $Sun
@onready var environment: Environment = $WorldEnvironment.environment


func _ready() -> void:
	# Enemies walk around obstacles using the pre-baked navmeshes (made by
	# tools/bake_navmesh.gd), and the yard's static objects are lit by the
	# baked lightmap (main.lmbake). If you change the level, run
	# tools/rebake.bat to bake both again.
	_add_navmeshes()
	# The navigation map belongs to the window, so it is the same one the
	# previous scene (or the last Retry) used: its iteration id is already
	# past 0. Path queries are only trusted after it has synced again.
	_nav_iteration_start = NavigationServer3D.map_get_iteration_id(get_world_3d().navigation_map)
	_player_start = player.global_position

	# Looping ambient wind, and the gameplay music.
	wind.stream.loop = true
	wind.play()
	Music.play_game(music)

	_connect_player_hud()
	hud.retry_requested.connect(_on_retry)
	hud.main_menu_requested.connect(_on_main_menu)
	hud.revive_screen.revived.connect(_on_revived)
	hud.revive_screen.declined.connect(_game_over)
	spawn_timer.wait_time = SPAWN_INTERVAL
	spawn_timer.timeout.connect(_on_spawn_tick)

	hud.set_health(player.health)
	player.emit_status()
	hud.set_score(score)
	_setup_economy()
	_setup_progress()

	if DisplayServer.is_touchscreen_available():
		max_enemies = PHONE_MAX_ENEMIES
	atmosphere = Atmosphere.attach(self, map_id, environment, sun)
	_apply_quality()
	Settings.changed.connect(_apply_quality)
	_prewarm_effects()
	_start_auto_quality()

	# The first match teaches the controls before wave 1 (tutorial.gd).
	if Settings.tutorial_done:
		start_wave(1)
	else:
		start_tutorial()


# Player -> HUD and the touch controls (the Training Arena uses this too).
func _connect_player_hud() -> void:
	player.health_changed.connect(hud.set_health)
	player.ammo_changed.connect(hud.set_ammo)
	player.weapon_changed.connect(hud.set_weapon)
	player.grenades_changed.connect(hud.set_grenades)
	player.scope_changed.connect(hud.set_scoped)
	player.aim_changed.connect(hud.set_aiming)
	player.message.connect(hud.show_message)
	player.died.connect(_on_player_died)
	player.hit_taken.connect(hud.flash_damage)
	player.enemy_hit.connect(hud.feedback.on_enemy_hit)
	# Aim assist only helps the touch controls.
	player.touch_active = hud.touch_controls.visible
	hud.touch_controls.player = player
	# The touch Aim button lights up while aiming.
	player.weapon_changed.connect(func(_name: String) -> void: hud.touch_controls.queue_redraw())
	player.scope_changed.connect(func(_on: bool) -> void: hud.touch_controls.queue_redraw())
	player.aim_changed.connect(func(_on: bool, _sight: String) -> void: hud.touch_controls.queue_redraw())
	player.grenades_changed.connect(func(_n: int) -> void: hud.touch_controls.queue_redraw())


func _process(delta: float) -> void:
	hud.update_powerups(economy.active)
	if phase != Phase.BREAK:
		return
	_break_left -= delta
	var seconds := ceili(_break_left)
	if seconds != _break_shown:
		_break_shown = seconds
		hud.set_break(wave + 1, seconds)
	if _break_left <= 0.0:
		start_wave(wave + 1)


## Shows the tutorial tips (tutorial.gd); wave 1 waits until the basics are
## done or skipped.
func start_tutorial() -> void:
	tutorial = Tutorial.new()
	tutorial.name = "Tutorial"
	tutorial.player = player
	tutorial.hud = hud
	hud.add_child(tutorial)
	hud.move_child(tutorial, hud.shop_button.get_index())  # under the shop and menus
	tutorial.basics_done.connect(func() -> void:
		if wave == 0:
			start_wave(1))
	tutorial.tree_exited.connect(func() -> void: tutorial = null)
	hud.wave_label.text = "Tutorial"


# Graphics Auto: measure the frame rate this match (auto_quality.gd), unless
# it already picked. Not in tests (they set the quality themselves).
func _start_auto_quality() -> void:
	if Settings.quality != Settings.Quality.AUTO or Settings.auto_quality >= 0 \
			or Settings._under_test():
		return
	auto_quality = AutoQuality.new()
	auto_quality.name = "AutoQuality"
	auto_quality.measured_at = Settings.effective_quality()
	add_child(auto_quality)
	auto_quality.picked.connect(func(q: int) -> void:
		auto_quality = null
		_apply_quality()
		hud.show_toast("Graphics: Auto picked %s" % Settings.QUALITY_NAMES[q]))


# Cash, the shop, armor and power-ups. Weapons are bought in the shop now,
# so the maps' weapon pickups are taken out of play (ammo boxes stay).
func _setup_economy() -> void:
	economy = MatchEconomy.new()
	economy.name = "Economy"
	economy.player = player
	add_child(economy)
	economy.cash_changed.connect(hud.set_cash)
	economy.powerup_collected.connect(func(kind: String) -> void:
		hud.show_message(Economy.POWERUP_INFO[kind].name.to_upper() + "!"))
	player.armor_changed.connect(hud.set_armor)
	hud.set_cash(economy.cash)
	hud.set_armor(player.armor)
	hud.shop.economy = economy
	hud.shop.player = player
	hud.shop_ready.connect(_on_shop_ready)
	var pickups := get_node_or_null("Pickups")
	if pickups:
		for p: Node in pickups.get_children():
			if p.kind == p.Kind.WEAPON:
				p.remove_from_play()


# Persistent progression (progress.gd): XP, missions, stars and achievements
# count during the match; the HUD pops up level-ups and the rest.
func _setup_progress() -> void:
	Progress.start_match(map_id)
	Progress.leveled_up.connect(hud.show_level_up)
	Progress.mission_completed.connect(hud.on_mission_completed)
	Progress.achievement_unlocked.connect(hud.on_achievement)
	Progress.star_earned.connect(hud.on_star_earned)


# The match is over (Game Over, or Main Menu from the pause menu).
func _end_progress() -> Dictionary:
	return Progress.end_match(waves_survived, kills, economy.total_earned)


# READY in the shop: skip the rest of the break.
func _on_shop_ready() -> void:
	if phase == Phase.BREAK:
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
	hud.set_shop_available(false)
	economy.new_wave()
	Progress.on_wave_started(n)
	# Exploded barrels come back for the new wave.
	get_tree().call_group("explosive_barrels", "respawn")


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
	var layer := EnemyTypes.nav_layer(enemy.kind)
	var point: Node3D = _pick_spawn_point(layer)
	var offset := Vector3(randf_range(-SPAWN_SPREAD, SPAWN_SPREAD), 0.0, randf_range(-SPAWN_SPREAD, SPAWN_SPREAD))
	var pos := _on_navmesh(point.global_position + offset, layer)
	if off_navmesh(pos, layer) > SPAWN_OFF_MESH:
		# The offset landed somewhere its navmesh doesn't reach (a gap too
		# tight for a big enemy): the spawn point itself instead.
		pos = _on_navmesh(point.global_position, layer)
	enemy.position = pos
	enemy.died.connect(_on_enemy_died.bind(enemy))
	enemy.stuck.connect(_on_enemy_stuck.bind(enemy))
	enemies.add_child(enemy)
	_to_spawn -= 1
	_alive += 1
	if enemy.kind == "boss":
		hud.show_boss(enemy.stats.name, enemy.hp, enemy.max_hp)
		hud.show_message("The Brute Boss is here!")


# A random spawn point that isn't right next to the player, and that enemies
# on navigation `layer` can walk out of.
func _pick_spawn_point(layer := EnemyTypes.NAV_SMALL) -> Node3D:
	var usable := _spawn_points_for(layer)
	var far := usable.filter(func(p: Node3D) -> bool:
		return p.global_position.distance_to(player.global_position) > SAFE_SPAWN_DISTANCE)
	return (far if not far.is_empty() else usable).pick_random()


# Spawn points connected to the player's start on that layer's navmesh (some
# are in corners too tight for the Brute). Worked out once the map is ready.
func _spawn_points_for(layer: int) -> Array[Node]:
	if _spawns_by_layer.has(layer):
		return _spawns_by_layer[layer]
	var map := get_world_3d().navigation_map
	if not navmesh_ready():
		return spawn_points  # navmesh not ready yet (not remembered)
	var ok: Array[Node] = []
	for p: Node3D in spawn_points:
		# The path must start at the spawn point (it isn't in a pocket cut out of
		# this layer's navmesh) and end at the player start.
		var path := NavigationServer3D.map_get_path(map, p.global_position, _player_start, true, layer)
		if not path.is_empty() and path[path.size() - 1].distance_to(_player_start) < 1.5 \
				and Vector2(path[0].x - p.global_position.x, path[0].z - p.global_position.z).length() < SPAWN_SPREAD + 0.5:
			ok.append(p)
	if ok.is_empty():
		push_warning("No spawn point connects to the player start on navigation layer %d" % layer)
		return spawn_points  # not remembered: try again next time
	_spawns_by_layer[layer] = ok
	return ok


## True once the navigation map has synced with this scene's navmeshes (every
## size's region), so path and closest-point queries can be trusted.
## A scene change takes two syncs (the first one doesn't have the new regions'
## polygons yet), so it asks the map itself: a short path on every layer near
## the player start must come back. Once true it stays true.
func navmesh_ready() -> bool:
	if _nav_ready:
		return true
	var map := get_world_3d().navigation_map
	if NavigationServer3D.map_get_iteration_id(map) <= _nav_iteration_start:
		return false
	for layer: int in _nav_regions:
		var region: NavigationRegion3D = _nav_regions[layer]
		var from := NavigationServer3D.region_get_closest_point(region.get_rid(), _player_start)
		var path := NavigationServer3D.map_get_path(map, from, from + Vector3(0.3, 0.0, 0.3), true, layer)
		if path.is_empty():
			return false
	_nav_ready = true
	return true


# The closest point to `pos` on that layer's navmesh (if there is one near).
func _on_navmesh(pos: Vector3, layer: int) -> Vector3:
	if not navmesh_ready():
		return pos
	var region: NavigationRegion3D = _nav_regions.get(layer, $NavigationRegion3D)
	var p := NavigationServer3D.region_get_closest_point(region.get_rid(), pos)
	if Vector2(p.x - pos.x, p.z - pos.z).length() > 2.0:
		return pos
	return Vector3(p.x, pos.y, p.z)


## How far `pos` is from that layer's navmesh (0 when the navmesh isn't ready).
func off_navmesh(pos: Vector3, layer: int) -> float:
	if not navmesh_ready():
		return 0.0
	var region: NavigationRegion3D = _nav_regions.get(layer, $NavigationRegion3D)
	var p := NavigationServer3D.region_get_closest_point(region.get_rid(), pos)
	return Vector2(p.x - pos.x, p.z - pos.z).length()


# The scene's NavigationRegion3D holds the small enemies' navmesh (layer 1).
# The Brute's and the Boss's (<navmesh>_brute.res, _boss.res, see
# enemy_types.gd NAV_MESHES) each go in a region of their own.
func _add_navmeshes() -> void:
	var small: NavigationRegion3D = $NavigationRegion3D
	var base := small.navigation_mesh.resource_path.get_basename()
	for m: Dictionary in EnemyTypes.NAV_MESHES:
		if m.suffix == "":
			small.navigation_layers = m.layer
			_nav_regions[m.layer] = small
			continue
		var path: String = base + m.suffix + ".res"
		if not ResourceLoader.exists(path):
			push_warning("No navmesh at %s: run tools/bake_navmesh.gd" % path)
			continue
		var region := NavigationRegion3D.new()
		region.name = "NavigationRegion" + m.suffix.capitalize().replace(" ", "")
		region.navigation_layers = m.layer
		region.navigation_mesh = load(path)
		add_child(region)
		_nav_regions[m.layer] = region


## The navigation region of a layer (for tests).
func nav_region(layer: int) -> NavigationRegion3D:
	return _nav_regions.get(layer)


# An enemy that couldn't get unstuck: move it to a spawn point the player
# can't see (behind them or behind a wall), the furthest one if none is hidden.
func _on_enemy_stuck(enemy: Node3D) -> void:
	if not is_instance_valid(enemy) or enemy.state == enemy.State.DEAD:
		return
	var camera := get_viewport().get_camera_3d()
	var layer := EnemyTypes.nav_layer(enemy.kind)
	var hidden: Array[Node3D] = []
	var furthest: Node3D = null
	for p: Node3D in _spawn_points_for(layer):
		var d := p.global_position.distance_to(player.global_position)
		if d < SAFE_SPAWN_DISTANCE:
			continue
		if furthest == null or d > furthest.global_position.distance_to(player.global_position):
			furthest = p
		if not _player_can_see(camera, p.global_position + Vector3.UP * 1.2):
			hidden.append(p)
	var point: Node3D = hidden.pick_random() if not hidden.is_empty() else furthest
	if point == null:
		point = _pick_spawn_point(layer)
	enemy.relocate(_on_navmesh(point.global_position, layer))


func _player_can_see(camera: Camera3D, pos: Vector3) -> bool:
	if camera == null:
		return true
	var to := pos - camera.global_position
	if to.normalized().dot(-camera.global_basis.z) < 0.3:
		return false  # outside (roughly) the field of view
	var q := PhysicsRayQueryParameters3D.create(camera.global_position, pos, 3, [player.get_rid()])
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


func _on_enemy_died(enemy: Node) -> void:
	_alive -= 1
	kills += 1
	# Exploders that blow themselves up give no points.
	if enemy.killed_by_player:
		score += enemy.stats.points
		if not enemy.no_reward:  # nuked: no cash, no drop, no streak
			hud.feedback.on_kill()  # kill sound, streak popup, vibration
			economy.award_kill(enemy, hud.feedback.streak)
			economy.maybe_drop(enemy)
			Progress.on_kill(enemy.kind, enemy.last_hit_was_headshot())
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
	economy.award_wave(wave)
	Progress.on_wave_cleared(wave)
	hud.set_shop_available(true)
	hud.show_banner("Wave %d cleared" % wave, "+$%d  ·  Shop open" % Economy.wave_cash(wave), BREAK_TIME - 0.6)


# Graphics quality from the settings screen (Low / Medium / High, or what
# Auto picked, see auto_quality.gd): shadows,
# fog, glow and the resolution the 3D scene is drawn at (it is scaled up to
# the screen; the HUD always stays sharp). Medium matches the old phone setup.
func _apply_quality() -> void:
	var vp := get_viewport()
	if atmosphere:
		atmosphere.apply_quality(Settings.effective_quality())
	var flash_light: Light3D = player.get_node("%FlashLight")
	# Maps can mark some of their lamps as extras that Low quality turns off.
	for lamp: Node in get_tree().get_nodes_in_group("optional_lights"):
		lamp.visible = Settings.effective_quality() != Settings.Quality.LOW
	match Settings.effective_quality():
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
	# A power-up token (glow, emissive coin and its 3D label).
	var token := preload("res://effects/powerup_drop.gd").new()
	token.process_mode = Node.PROCESS_MODE_DISABLED
	add_child(token)
	warm.append(token)
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
	hud.feedback.prewarm(true)  # low-health vignette shader
	# Keep them for a few frames so they are really drawn, then remove them.
	for i in 3:
		await get_tree().process_frame
	muzzle.visible = false
	player.show_all_view_models(false)
	hud.scope_overlay.visible = false
	hud.scope_overlay.self_modulate.a = 1.0
	hud.feedback.prewarm(false)
	for node in warm:
		node.queue_free()


# Dying: a revive is offered first while there is one left this match
# (ui/revive_screen.gd: "Watch ad to revive"), then Game Over.
func _on_player_died() -> void:
	if revives_left > 0:
		revives_left -= 1
		spawn_timer.paused = true
		get_tree().paused = true
		hud.offer_revive()
		return
	_game_over()


## Back with full health after the (placeholder) ad: enemies near the
## player are pushed away and staggered, and a moment of no damage.
func _on_revived() -> void:
	player.revive(Economy.REVIVE_INVULNERABLE)
	push_back_enemies(player.global_position)
	spawn_timer.paused = false
	hud.end_revive()
	get_tree().paused = false
	hud.show_message("Back in the fight!")


## Pushes every living enemy within REVIVE_PUSH_RADIUS away from `from`.
func push_back_enemies(from: Vector3) -> void:
	for e: Node in enemies.get_children():
		if e.state == e.State.DEAD or not e.has_method("shove_from"):
			continue
		if e.global_position.distance_to(from) <= Economy.REVIVE_PUSH_RADIUS:
			e.shove_from(from, Economy.REVIVE_PUSH_SPEED, Economy.REVIVE_STUN)


func _game_over() -> void:
	if phase == Phase.OVER:
		return
	spawn_timer.paused = false
	phase = Phase.OVER
	spawn_timer.stop()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var new_best: bool = Settings.submit_score(score, waves_survived, map_id)
	hud.show_game_over(waves_survived, kills, score, Settings.best_score_for(map_id), new_best, economy.total_earned)
	hud.show_progress(_end_progress())
	get_tree().paused = true  # freezes everything except the HUD and music


func _on_retry() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()


func _on_main_menu() -> void:
	_end_progress()  # leaving mid-match still pays for the waves so far
	get_tree().paused = false
	get_tree().change_scene_to_file(MENU_SCENE)
