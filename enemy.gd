extends CharacterBody3D
## An animated enemy. Its `kind` picks the stats, model, colours and sounds
## from enemy_types.gd (set it before adding the enemy to the scene):
##  - normal, runner, brute, boss: walk to the player around obstacles
##    (navmesh), punch when close, stagger when shot (brutes don't), and play
##    a death animation.
##  - soldier: walks to a firing spot 7-15 m from the player (a reachable
##    point on the navmesh with a clear view), then aims (red laser +
##    warning tone) and fires a shot with a visible tracer.
##  - exploder: runs at the player, beeps faster when close and blows up,
##    or blows up when killed. Its blast hurts other enemies too.
##
## Navigation: Brutes and the Boss walk on the large navmesh (layer 2), the
## rest on the small one (enemy_types.gd nav_layer). Avoidance keeps them from
## pushing each other into walls. An enemy that stops making progress first
## recalculates its path (STUCK_REPATH), then sidesteps (STUCK_SLIDE), and
## finally asks main.gd to move it to a hidden spawn point (STUCK_RESPAWN).

signal died
signal health_changed(hp: int, max_hp: int)
## Still stuck after STUCK_RESPAWN seconds: main.gd calls relocate().
signal stuck

enum State { CHASE, ATTACK, HIT, DEAD, AIM, SHOOT, ARMED }

const Types := preload("res://enemy_types.gd")
const Blast := preload("res://effects/blast.gd")
const WeaponModel := preload("res://weapon_model.gd")

const TURN_SPEED := 8.0           # how fast the enemy turns to face its direction
const CORPSE_TIME := 4.0          # seconds the body stays before sinking away
const FLASH_TIME := 0.08

# Navigation.
const REPATH_MOVE := 0.75         # new path as soon as the target moved this far...
const REPATH_TIME := 1.5          # ...and at least this often (not every frame: with two
                                  # equally long ways round an obstacle it kept flipping)
const AVOID_MARGIN := 0.15        # extra avoidance radius around the body
const PROGRESS_CHECK := 0.5       # seconds between "is it getting anywhere?" checks
const PROGRESS_MIN := 0.3         # m/s: slower than this (or half its speed) = barely moving
const STUCK_REPATH := 2.0         # seconds without progress before recalculating the path
const STUCK_SLIDE := 5.0          # ... before sidestepping
const STUCK_RESPAWN := 10.0       # ... before moving to a hidden spawn point
const SLIDE_TIME := 0.8           # length of a sidestep
const NEAR_PLAYER := 1.5          # within attack range + this, crowding isn't "stuck"
const GHOST_TIME := 1.5           # seconds it walks through other enemies to break a jam

# Soldier.
const SOLDIER_MIN_RANGE := 7.0    # backs away if the player is closer
const SOLDIER_MAX_RANGE := 15.0   # walks closer if the player is further
const AIM_TIME := 0.9             # warning laser time before each shot
const SHOT_COOLDOWN := Vector2(1.8, 2.8)
const SHOT_DAMAGE := 8
const SHOT_HIT_CHANCE := 0.75     # standing still at close range
const SHOT_MOVING_PENALTY := 0.3  # less likely to hit a moving player
const SHOT_RANGE := 40.0
const SHOT_TIME := 0.5            # length of the shoot pose after firing
const TRACER_TIME := 0.08
const GUN_SCALE := 0.045          # pistol in the hand (the rig's bones are 100x)
const SIGHT_MASK := 3             # walls and props block the soldier's view and shots
const AIM_POSE_TIME := 0.05       # frame of the shoot animation held while aiming
const GLINT_SIZE := 0.5           # the blinking red warning light at the muzzle (m)
const SPOT_RANGES := [11.0, 8.5, 13.5]  # distances tried for a firing spot
const SPOT_ANGLES := 10           # directions tried around the player
const SPOT_TIME := Vector2(1.5, 3.0)    # seconds before moving to the next spot
const SPOT_PLAYER_MOVE := 3.0     # re-pick when the player moved this far
const SPOT_REACHED := 0.6

# Exploder.
const ARM_TIME := 0.7             # seconds of fast beeping before it blows up
const BLAST_RADIUS := 5.0
const BLAST_ENEMY_DAMAGE := 10
const BLAST_PLAYER_DAMAGE := 45
const DEATH_BLAST_DELAY := 0.2    # killed exploders go off a moment later

const BLOOD_SCENE := preload("res://effects/blood_hit.tscn")
const FLASH_MATERIAL := preload("res://effects/hit_flash_material.tres")  # white overlay for hits
const HIT_SOUNDS := [
	preload("res://assets/sounds/impactPunch_medium_000.ogg"),
	preload("res://assets/sounds/impactPunch_medium_001.ogg"),
	preload("res://assets/sounds/impactPunch_medium_002.ogg"),
]
const PISTOL_MODEL := preload("res://assets/models/quaternius/ultimate_guns/pistol.glb")
const SOLDIER_SHOT := preload("res://assets/sounds/gunshot_pistol.wav")
const SOLDIER_WARNING := preload("res://assets/sounds/enemies/soldier_warning.ogg")
const EXPLODER_BEEP := preload("res://assets/sounds/enemies/exploder_beep.ogg")
const BOSS_ROAR := preload("res://assets/sounds/enemies/brute_roar.wav")

## Which enemy_types.gd entry this is. Set before adding to the scene.
@export var kind := "normal"
## Set by main.gd before spawning: later waves walk faster (1.0 = normal).
var speed_scale := 1.0
## Boss health can be raised by main.gd for later boss waves (0 = from stats).
var hp_override := 0
var stats: Dictionary
var max_hp := 3
var hp := 3
var state := State.CHASE
## true while main.gd draws it once at load to compile shaders (no sounds).
var silent := false
## false when an exploder blew itself up (no points for the player).
var killed_by_player := true
## How stuck it is now (0 fine, 1 re-pathed, 2 sidestepped, 3 relocated), and
## how many times each happened (for tests).
var stuck_level := 0
var stuck_counts := [0, 0, 0, 0]

var _state_time := 0.0
var _attack_landed := false
var _repath_timer := 0.0
var _growl_timer := 0.0
var _flash_timer := 0.0
var _step_timer := 0.0
var _shot_cooldown := 0.0
var _strafe_dir := 1.0            # soldier: which side its next firing spot is on
var _beep_timer := 0.0
var _exploded := false
var _wants_move := false          # set each frame by _walk_to when it is trying to walk
var _speed_mult := 1.0
var _safe_velocity := Vector3.ZERO
var _safe_frame := -100           # physics frame of the last avoidance result
var _progress_from := Vector3.ZERO
var _progress_timer := 0.0
var _stuck_time := 0.0
var _slide_dir := Vector3.ZERO
var _slide_time := 0.0
var _ghost_time := 0.0
var _ghosted: Array[Node] = []    # enemies it is passing through right now
var _spot := Vector3.INF          # soldier's firing spot
var _spot_timer := 0.0
var _spot_player_pos := Vector3.ZERO
var _player: Node3D
var _setup_done := false
var _glow_materials: Array[StandardMaterial3D] = []
var _muzzle: Node3D
var _gun: Node3D
var _skel: Skeleton3D
var _laser: MeshInstance3D
var _glint: MeshInstance3D
var _tracer: MeshInstance3D
var _sfx: AudioStreamPlayer3D

@onready var anim: AnimationPlayer = $Model/AnimationPlayer
@onready var agent: NavigationAgent3D = $NavigationAgent3D
@onready var collision: CollisionShape3D = $CollisionShape3D
@onready var growl_player: AudioStreamPlayer3D = $GrowlPlayer
@onready var hit_player: AudioStreamPlayer3D = $HitPlayer
@onready var meshes: Array[Node] = $Model.find_children("*", "MeshInstance3D", true, false)


# The model is swapped here, before the @onready variables look it up.
func _enter_tree() -> void:
	if _setup_done:
		return
	_setup_done = true
	stats = Types.TYPES[kind]
	max_hp = hp_override if hp_override > 0 else stats.hp
	hp = max_hp
	var model: Node3D = $Model
	if stats.model != null:
		remove_child(model)
		model.free()
		model = stats.model.instantiate()
		model.name = "Model"
		add_child(model)
		move_child(model, 1)
	# The characters face +Z; enemies move along -Z.
	model.transform = Transform3D(Basis(Vector3.UP, PI).scaled(Vector3.ONE * stats.model_scale), Vector3.ZERO)
	var capsule := CapsuleShape3D.new()
	capsule.radius = stats.radius
	capsule.height = stats.height
	$CollisionShape3D.shape = capsule
	$CollisionShape3D.position.y = stats.height * 0.5
	$GrowlPlayer.position.y = stats.height * 0.9
	$HitPlayer.position.y = stats.height * 0.7


func _ready() -> void:
	_player = get_tree().get_first_node_in_group("player")
	_recolor()
	for a: String in [stats.anims.walk, stats.anims.get("idle", "")]:
		if a != "" and anim.has_animation(a):
			anim.get_animation(a).loop_mode = Animation.LOOP_LINEAR
	anim.play(stats.anims.walk, -1, _walk_anim_speed())
	anim.seek(randf() * 1.0)  # so a group of enemies doesn't walk in sync
	_growl_timer = randf_range(1.0, 6.0)
	_sfx = AudioStreamPlayer3D.new()
	_sfx.unit_size = 8.0
	_sfx.max_distance = 50.0
	_sfx.position.y = stats.height * 0.7
	add_child(_sfx)
	_setup_agent()
	if kind == "soldier":
		_add_gun()
		_shot_cooldown = randf_range(0.8, 1.6)
		_strafe_dir = 1.0 if randf() < 0.5 else -1.0
	if kind == "boss" and not silent:
		_sfx.stream = BOSS_ROAR
		_sfx.unit_size = 20.0
		_sfx.play()
	health_changed.emit(hp, max_hp)


func _physics_process(delta: float) -> void:
	_state_time += delta
	_update_flash(delta)
	_update_glow(delta)

	if state == State.DEAD:
		# Lie still, then sink into the ground and disappear.
		if _state_time > CORPSE_TIME - 1.0:
			position.y -= delta * 0.6
		if _state_time > CORPSE_TIME:
			queue_free()
		return

	if not is_on_floor():
		velocity += get_gravity() * delta
	_update_growl(delta)

	_wants_move = false
	match state:
		State.CHASE:
			if kind == "soldier":
				_soldier_move(delta)
			else:
				_chase(delta)
		State.ATTACK:
			_attack(delta)
		State.HIT:
			velocity.x = move_toward(velocity.x, 0.0, 20.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, 20.0 * delta)
			if _state_time > stats.hit_stun:
				_set_state(State.CHASE)
		State.AIM:
			_aim(delta)
		State.SHOOT:
			velocity.x = 0.0
			velocity.z = 0.0
			if _state_time >= SHOT_TIME:
				_set_state(State.CHASE)
		State.ARMED:
			_armed(delta)

	_update_steps(delta)
	if _gun:
		_orient_gun()
	if not _wants_move and agent.avoidance_enabled:
		agent.velocity = Vector3.ZERO  # standing: others still walk around it
	move_and_slide()
	_update_stuck(delta)
	if _ghost_time > 0.0:
		_ghost_time -= delta
		if _ghost_time <= 0.0:
			_end_ghost()


func _walk_anim_speed() -> float:
	return stats.speed * speed_scale / stats.walk_anim_ref


func _player_alive() -> bool:
	return _player != null and not _player.is_dead


# Its navmesh (by size), and avoidance so enemies make room for each other
# instead of shoving each other into walls. Bigger enemies have the right of way.
func _setup_agent() -> void:
	agent.navigation_layers = Types.nav_layer(kind)
	agent.radius = stats.radius + AVOID_MARGIN
	agent.height = stats.height
	agent.path_desired_distance = 0.4  # reach each corner before turning (big ones cut them)
	agent.max_speed = stats.speed * speed_scale * 1.2
	agent.neighbor_distance = 5.0
	agent.max_neighbors = 8
	agent.time_horizon_agents = 1.0
	agent.avoidance_priority = clampf(stats.radius, 0.3, 1.0)  # Boss > Brute > the rest
	agent.avoidance_enabled = not silent
	agent.velocity_computed.connect(_on_velocity_computed)
	_progress_from = global_position


func _on_velocity_computed(safe: Vector3) -> void:
	_safe_velocity = safe
	_safe_frame = Engine.get_physics_frames()


# Walk along the navmesh towards `target` at the type's speed.
func _walk_to(target: Vector3, delta: float, speed_mult := 1.0) -> void:
	_wants_move = true
	_speed_mult = speed_mult
	var dir: Vector3
	var use_avoidance := _slide_time <= 0.0 and _ghost_time <= 0.0
	if _slide_time > 0.0:
		# Sidestepping out of a stuck spot.
		_slide_time -= delta
		dir = _slide_dir
		if _slide_time <= 0.0:
			_repath_timer = 0.0
	else:
		_repath_timer -= delta
		if _repath_timer <= 0.0 or target.distance_to(agent.target_position) > REPATH_MOVE:
			agent.target_position = target
			_repath_timer = REPATH_TIME
		var to_next := agent.get_next_path_position() - global_position
		to_next.y = 0.0
		if agent.is_navigation_finished() or to_next.length() < 0.05:
			# End of the path (or no navmesh yet): the last bit straight at the
			# target, if nothing is in the way. If the path stops short (the
			# target is somewhere too tight for this enemy), wait there for it
			# to come out instead of squeezing in.
			var to_target := target - global_position
			to_target.y = 0.0
			var step := to_target.normalized() * 0.3
			var path_end := agent.get_final_position()
			var short := not agent.get_current_navigation_path().is_empty() \
					and _flat_distance(path_end, target) > maxf(stats.attack_range, 1.0)
			if short or to_target.length() < 0.2 or test_move(global_transform.translated(Vector3.UP * 0.05), step):
				_wants_move = false
				_stop()
				return
			to_next = to_target
			use_avoidance = false  # the agent's avoidance stops once its path is done
		dir = to_next.normalized()
	var desired: Vector3 = dir * stats.speed * speed_scale * speed_mult
	var v := desired
	if agent.avoidance_enabled:
		agent.velocity = desired
	if agent.avoidance_enabled and use_avoidance:
		# Avoidance only knows about the other enemies: never let it steer
		# this one into a wall or a crate (the path itself is clear of them),
		# and don't let a crowd freeze everyone in place (RVO can return ~0
		# for all of them in a narrow spot): then just push on.
		var fresh := Engine.get_physics_frames() - _safe_frame <= 2
		if fresh and _safe_velocity.length() >= desired.length() * 0.2 \
				and _static_normal(_safe_velocity * 0.15) == Vector3.ZERO:
			v = _safe_velocity
	# Walking straight into an obstacle (e.g. shoved off its path next to a
	# crate): go along it instead, on the side of the next waypoint.
	if v.length_squared() > 0.01:
		var n := _static_normal(v.normalized() * 0.2)
		if n != Vector3.ZERO and v.normalized().dot(-n) > 0.7:
			var along := n.cross(Vector3.UP)
			along.y = 0.0
			var side := along.dot(dir)
			if absf(side) < 0.05:
				side = _strafe_dir
			v = along.normalized() * signf(side) * v.length()
	velocity.x = v.x
	velocity.z = v.z
	_turn_towards(dir, delta)


# The normal of the wall/prop it would hit moving by `motion` (zero if none;
# other enemies and the player don't count).
func _static_normal(motion: Vector3) -> Vector3:
	var hit := KinematicCollision3D.new()
	if test_move(global_transform.translated(Vector3.UP * 0.05), motion, hit) and hit.get_collider() is StaticBody3D:
		var n := hit.get_normal()
		n.y = 0.0
		return n.normalized() if n.length_squared() > 0.01 else Vector3.ZERO
	return Vector3.ZERO


func _stop() -> void:
	velocity.x = 0.0
	velocity.z = 0.0


# Every PROGRESS_CHECK seconds while walking: did it cover at least
# PROGRESS_MIN of the distance it should have? If not, the stuck time adds
# up: at STUCK_REPATH it recalculates its path, at STUCK_SLIDE it sidesteps,
# at STUCK_RESPAWN main.gd moves it to a spawn point out of the player's view.
func _update_stuck(delta: float) -> void:
	var walking := _wants_move and (state == State.CHASE or state == State.ARMED)
	if not walking or (_player_alive() and _player_in_range(stats.attack_range + NEAR_PLAYER)):
		# Standing on purpose, or crowding round the player: not stuck.
		_reset_progress()
		return
	_progress_timer += delta
	if _progress_timer < PROGRESS_CHECK:
		return
	var moved := Vector2(global_position.x - _progress_from.x, global_position.z - _progress_from.z).length()
	var speed: float = stats.speed * speed_scale * _speed_mult
	if moved >= minf(PROGRESS_MIN, speed * 0.5) * _progress_timer:
		_stuck_time = 0.0
		stuck_level = 0
	else:
		_stuck_time += _progress_timer
		if _ghost_time <= 0.0 and _pressed_against_enemy():
			_start_ghost()
	_progress_timer = 0.0
	_progress_from = global_position
	if _stuck_time >= STUCK_RESPAWN and stuck_level < 3:
		_set_stuck_level(3)
		stuck.emit()
	elif _stuck_time >= STUCK_SLIDE and stuck_level < 2:
		_set_stuck_level(2)
		_start_slide()
	elif _stuck_time >= STUCK_REPATH and stuck_level < 1:
		_set_stuck_level(1)
		_repath_timer = 0.0  # a new path query on the next step
		_spot = Vector3.INF  # soldiers also pick a new firing spot


# Jammed in with other enemies (e.g. two Brutes meeting in a gap only one of
# them fits through): neither gives way, so this one walks through the others
# for a moment. Walls and the player still stop it.
func _pressed_against_enemy() -> bool:
	for e: Node3D in get_tree().get_nodes_in_group("enemies"):
		if e != self and e is CharacterBody3D:
			var reach: float = stats.radius + e.stats.radius + 0.3
			if Vector2(e.global_position.x - global_position.x, e.global_position.z - global_position.z).length() < reach:
				return true
	return false


func _start_ghost() -> void:
	_ghost_time = GHOST_TIME
	for e in get_tree().get_nodes_in_group("enemies"):
		if e != self and e is PhysicsBody3D:
			add_collision_exception_with(e)
			_ghosted.append(e)


func _end_ghost() -> void:
	_ghost_time = 0.0
	for e in _ghosted:
		if is_instance_valid(e):
			remove_collision_exception_with(e)
	_ghosted.clear()


func _set_stuck_level(level: int) -> void:
	stuck_level = level
	stuck_counts[level] += 1


func _reset_progress() -> void:
	_progress_timer = 0.0
	_progress_from = global_position
	_stuck_time = 0.0
	stuck_level = 0


# Sidestep: left or right of where it was trying to go, whichever is free
# (backwards if both are blocked).
func _start_slide() -> void:
	var forward := agent.get_next_path_position() - global_position
	forward.y = 0.0
	if forward.length_squared() < 0.01:
		forward = -global_basis.z
	forward = forward.normalized()
	var side := forward.cross(Vector3.UP)
	if randf() < 0.5:
		side = -side
	var from := global_transform.translated(Vector3.UP * 0.05)
	var options := [side, -side, (side - forward).normalized(), (-side - forward).normalized(), -forward]
	_slide_dir = -forward
	for o: Vector3 in options:
		if not test_move(from, o * 0.8):
			_slide_dir = o
			break
	_slide_time = SLIDE_TIME


## Called by main.gd when it was stuck for too long: start again from `pos`.
func relocate(pos: Vector3) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	_slide_time = 0.0
	_spot = Vector3.INF
	_repath_timer = 0.0
	_safe_frame = -100
	_reset_progress()
	if state != State.DEAD:
		_set_state(State.CHASE)


## True while it is walking somewhere (not standing to shoot, waiting or attacking).
func is_trying_to_move() -> bool:
	return _wants_move


func _chase(delta: float) -> void:
	if not _player_alive():
		_stop()
		return
	_walk_to(_player.global_position, delta)
	if _player_in_range(stats.attack_range):
		if kind == "exploder":
			_set_state(State.ARMED)
		else:
			_set_state(State.ATTACK)


func _attack(delta: float) -> void:
	_stop()
	_face_player(delta)
	# Deal damage at the moment the punch connects (if the player is still close).
	if not _attack_landed and _state_time >= stats.attack_hit_time:
		_attack_landed = true
		if _player_alive() and _player_in_range(stats.attack_range * 1.3):
			_player.take_damage(stats.attack_damage)
	if _state_time >= stats.attack_duration:
		_set_state(State.CHASE)


## Called by the player's gun and by explosions.
func take_damage(amount: int, hit_position := Vector3.ZERO, hit_normal := Vector3.UP) -> void:
	if state == State.DEAD:
		return
	hp -= amount
	health_changed.emit(maxi(hp, 0), max_hp)
	_spawn_blood(hit_position, hit_normal)
	_flash()
	hit_player.stream = HIT_SOUNDS.pick_random()
	hit_player.pitch_scale = randf_range(0.9, 1.1)
	hit_player.play()

	if hp <= 0:
		_die()
	elif stats.hit_stun > 0.0 and state != State.ARMED:
		_set_state(State.HIT)


func _die() -> void:
	_set_state(State.DEAD)
	velocity = Vector3.ZERO
	collision.set_deferred("disabled", true)  # bullets and the player pass through the body
	agent.avoidance_enabled = false           # the others walk through the body too
	remove_from_group("enemies")
	_hide_laser()
	_growl(0.7)  # a groan
	died.emit()
	if kind == "exploder" and not _exploded:
		# Shot dead: it still goes off a moment later.
		get_tree().create_timer(DEATH_BLAST_DELAY, false).timeout.connect(_explode)


func _set_state(new_state: State) -> void:
	state = new_state
	_state_time = 0.0
	match new_state:
		State.CHASE:
			anim.play(stats.anims.walk, 0.2, _walk_anim_speed())
		State.ATTACK:
			_attack_landed = false
			_play_from_start(stats.anims.attack, 0.1)
		State.HIT:
			_hide_laser()
			_play_from_start(stats.anims.hit, 0.05)
		State.DEAD:
			_play_from_start(stats.anims.death, 0.1)
			if stats.fall_over:
				# Tip over backwards onto the ground (pivots on the feet).
				var tween := create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
				tween.tween_interval(0.15)
				tween.tween_property(self, "rotation:x", deg_to_rad(88.0), 0.45)
				tween.tween_property(self, "rotation:x", deg_to_rad(80.0), 0.1).set_ease(Tween.EASE_OUT)
				tween.tween_property(self, "rotation:x", deg_to_rad(88.0), 0.1)
		State.AIM:
			# Raise the gun and hold it there while the laser shows.
			_play_from_start(stats.anims.shoot, 0.0)
			anim.seek(AIM_POSE_TIME, true)
			anim.pause()
			_sfx.stream = SOLDIER_WARNING
			_sfx.pitch_scale = 1.0
			_sfx.play()
		State.SHOOT:
			_play_from_start(stats.anims.shoot, 0.0)
		State.ARMED:
			_beep_timer = 0.0


func _play_from_start(anim_name: String, blend: float) -> void:
	anim.play(anim_name, blend)
	anim.seek(0.0, true)


func _player_in_range(distance: float) -> bool:
	var offset := _player.global_position - global_position
	return absf(offset.y) < 1.5 and Vector2(offset.x, offset.z).length() < distance


func _flat_distance_to_player() -> float:
	var o := _player.global_position - global_position
	return Vector2(o.x, o.z).length()


# Smoothly rotate so the model faces `dir` (the model looks along -Z).
func _turn_towards(dir: Vector3, delta: float) -> void:
	if dir.length_squared() < 0.001:
		return
	var target_yaw := atan2(-dir.x, -dir.z)
	rotation.y = lerp_angle(rotation.y, target_yaw, clampf(TURN_SPEED * delta, 0.0, 1.0))


func _face_player(delta: float) -> void:
	if _player == null:
		return
	var to_player := _player.global_position - global_position
	to_player.y = 0.0
	_turn_towards(to_player.normalized(), delta)


# --- Soldier ------------------------------------------------------------------

# Walks (along the navmesh) to a firing spot SOLDIER_MIN_RANGE..MAX_RANGE from
# the player with a clear view, and fires from there. Every few seconds it
# moves on to a spot a little to the side, so it doesn't stand still.
func _soldier_move(delta: float) -> void:
	if not _player_alive():
		_stop()
		return
	_shot_cooldown -= delta
	if _player_in_range(stats.attack_range):
		_set_state(State.ATTACK)
		return
	_spot_timer -= delta
	if _spot == Vector3.INF or _spot_timer <= 0.0 or not _spot_still_good():
		_pick_spot()
	var dist := _flat_distance_to_player()
	var in_band := dist >= SOLDIER_MIN_RANGE and dist <= SOLDIER_MAX_RANGE
	if in_band and can_see_player():
		# Good place to shoot from: drift on to the spot, facing the player.
		if _spot != Vector3.INF and _flat_distance(global_position, _spot) > SPOT_REACHED:
			_walk_to(_spot, delta, 0.5)
		else:
			_stop()
		_face_player(delta)
		if _shot_cooldown <= 0.0:
			_set_state(State.AIM)
		return
	if _spot != Vector3.INF and _flat_distance(global_position, _spot) <= SPOT_REACHED:
		_spot_timer = minf(_spot_timer, 0.3)  # here, but the view is gone: find another soon
	_walk_to(_spot if _spot != Vector3.INF else _player.global_position, delta)


func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _spot_still_good() -> bool:
	if _player.global_position.distance_to(_spot_player_pos) > SPOT_PLAYER_MOVE:
		return false
	var d := _flat_distance(_spot, _player.global_position)
	return d >= SOLDIER_MIN_RANGE and d <= SOLDIER_MAX_RANGE


## Picks the firing spot: points around the player, snapped onto this
## soldier's navmesh by asking for a path there (so it is reachable), kept
## only if they are in range and have a clear view of the player. The one
## with the shortest walk wins; the next spot is a little to the side.
func _pick_spot() -> void:
	_spot_timer = randf_range(SPOT_TIME.x, SPOT_TIME.y)
	_spot_player_pos = _player.global_position
	_strafe_dir = -_strafe_dir
	var map := get_world_3d().navigation_map
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		_spot = Vector3.INF  # navmesh not ready yet
		return
	var from_player := global_position - _player.global_position
	from_player.y = 0.0
	var base := atan2(from_player.x, from_player.z) + _strafe_dir * 0.35
	var best := Vector3.INF
	var best_cost := INF
	for r: float in SPOT_RANGES:
		for i in SPOT_ANGLES:
			# Directions alternate either side of `base`, nearest first.
			var step := ceili(i / 2.0) * (1 if i % 2 == 0 else -1)
			var a := base + step * TAU / SPOT_ANGLES
			var wanted := _player.global_position + Vector3(sin(a), 0.0, cos(a)) * r
			var path := NavigationServer3D.map_get_path(map, global_position, wanted, true, agent.navigation_layers)
			if path.is_empty():
				continue
			var p: Vector3 = path[path.size() - 1]
			var d := _flat_distance(p, _player.global_position)
			if _flat_distance(p, wanted) > 1.5 or d < SOLDIER_MIN_RANGE + 0.5 or d > SOLDIER_MAX_RANGE - 0.5:
				continue
			if not _clear_view_from(p):
				continue
			var length := 0.0
			for k in range(1, path.size()):
				length += path[k - 1].distance_to(path[k])
			var cost := length + absf(step) * 0.5
			if cost < best_cost:
				best_cost = cost
				best = p
		if best != Vector3.INF:
			break  # the preferred distance found one
	_spot = best


## True if nothing solid is between the soldier's eyes and the player's chest.
func can_see_player() -> bool:
	return _clear_view_from(global_position)


# The same check as if the soldier stood at `pos`.
func _clear_view_from(pos: Vector3) -> bool:
	if _player == null:
		return false
	var from: Vector3 = pos + Vector3.UP * stats.height * 0.85
	var to := _player.global_position + Vector3.UP * 1.2
	var q := PhysicsRayQueryParameters3D.create(from, to, SIGHT_MASK, _sight_exclusions())
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.is_empty() or hit.collider == _player


func _sight_exclusions() -> Array[RID]:
	var ex: Array[RID] = [get_rid()]
	for e in get_tree().get_nodes_in_group("enemies"):
		if e is CollisionObject3D:
			ex.append((e as CollisionObject3D).get_rid())
	return ex


# Standing still with the laser on the player; fires when the time is up.
func _aim(delta: float) -> void:
	_stop()
	_face_player(delta)
	if not _player_alive():
		_hide_laser()
		_set_state(State.CHASE)
		return
	_show_laser(_player.global_position + Vector3.UP * 1.2)
	if _state_time >= AIM_TIME:
		_hide_laser()
		if can_see_player():
			_fire()
			_set_state(State.SHOOT)
		else:
			_set_state(State.CHASE)
		_shot_cooldown = randf_range(SHOT_COOLDOWN.x, SHOT_COOLDOWN.y)


## Shoots at the player. A miss goes past the player (and leaves a tracer
## that shows where it went). Walls and crates stop the bullet.
func _fire() -> void:
	var from := _muzzle.global_position
	var chest := _player.global_position + Vector3.UP * 1.2
	var chance := SHOT_HIT_CHANCE - _flat_distance_to_player() / 100.0
	var player_speed := Vector2(_player.velocity.x, _player.velocity.z).length()
	if player_speed > 2.0:
		chance -= SHOT_MOVING_PENALTY
	var target := chest
	if randf() > chance:
		# Miss: aim a little to the side of (and over) the player.
		var side := (chest - from).cross(Vector3.UP).normalized()
		target += side * randf_range(0.7, 1.3) * (1.0 if randf() < 0.5 else -1.0) + Vector3.UP * randf_range(0.0, 0.5)
	var dir := (target - from).normalized()
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * SHOT_RANGE, SIGHT_MASK, _sight_exclusions())
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var end := from + dir * SHOT_RANGE
	if not hit.is_empty():
		end = hit.position
		if hit.collider == _player:
			_player.take_damage(SHOT_DAMAGE)
	_show_tracer(from, end)
	_sfx.stream = SOLDIER_SHOT
	_sfx.pitch_scale = randf_range(0.95, 1.05)
	_sfx.play()


# A pistol in the right hand, with a marker at the muzzle, plus the laser
# and tracer meshes (hidden until used).
func _add_gun() -> void:
	_skel = $Model.find_children("*", "Skeleton3D", true, false)[0]
	var hand := BoneAttachment3D.new()
	hand.bone_name = "Fist.R"
	_skel.add_child(hand)
	_gun = PISTOL_MODEL.instantiate()
	_gun.scale = Vector3.ONE * GUN_SCALE
	hand.add_child(_gun)
	WeaponModel.no_shadows(_gun)
	_muzzle = Node3D.new()
	_muzzle.position = WeaponModel.measure(_gun).tip
	_gun.add_child(_muzzle)
	_laser = _beam(Color(1.0, 0.05, 0.05, 0.75), 0.012)
	_glint = _make_glint()
	_tracer = _beam(Color(3.0, 2.4, 1.2, 1.0), 0.03)


func _beam(color: Color, width: float) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = Vector3(width, width, 1.0)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = color
	box.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = box
	mi.top_level = true
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	add_child(mi)
	return mi


# A soft red light that faces the camera: the laser points straight at the
# player, so from their view it is mostly this blinking glint.
# The hand bone doesn't line up with the forearm, so the pistol is turned in
# code: at the player while aiming or shooting, along the forearm otherwise.
func _orient_gun() -> void:
	var dir: Vector3
	if (state == State.AIM or state == State.SHOOT) and _player != null:
		dir = _player.global_position + Vector3.UP * 1.2 - _gun.global_position
	else:
		var fist := _skel.get_bone_global_pose(_skel.find_bone("Fist.R")).origin
		var elbow := _skel.get_bone_global_pose(_skel.find_bone("LowerArm.R")).origin
		dir = _skel.global_basis * (fist - elbow)
	if dir.length_squared() < 1e-6:
		return
	var x := dir.normalized()
	var z := x.cross(Vector3.UP)
	if z.length_squared() < 1e-4:
		z = x.cross(Vector3.FORWARD)
	z = z.normalized()
	var s := _gun.global_basis.get_scale().x
	_gun.global_basis = Basis(x, z.cross(x), z) * Basis.from_scale(Vector3.ONE * s)


func _make_glint() -> MeshInstance3D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 32
	tex.height = 32
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_color = Color(2.5, 0.2, 0.1, 1.0)
	m.albedo_texture = tex
	var quad := QuadMesh.new()
	quad.size = Vector2(GLINT_SIZE, GLINT_SIZE)
	quad.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.top_level = true
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	add_child(mi)
	return mi


func _stretch(beam: MeshInstance3D, from: Vector3, to: Vector3) -> void:
	var length := from.distance_to(to)
	if length < 0.01:
		return
	var up := Vector3.UP if absf((to - from).normalized().y) < 0.99 else Vector3.RIGHT
	# Scale along the beam's own Z axis (its length).
	beam.global_transform = Transform3D(Basis.looking_at(to - from, up) * Basis.from_scale(Vector3(1, 1, length)), (from + to) * 0.5)


func _show_laser(target: Vector3) -> void:
	_stretch(_laser, _muzzle.global_position, target)
	# Blinks faster as the shot gets closer.
	var rate := lerpf(6.0, 18.0, _state_time / AIM_TIME)
	_laser.visible = sin(_state_time * rate * TAU * 0.5) > -0.3
	_glint.global_position = _muzzle.global_position
	_glint.visible = _laser.visible


func _hide_laser() -> void:
	if _laser:
		_laser.visible = false
		_glint.visible = false


## True while the warning laser is on screen (for tests).
func is_aiming() -> bool:
	return state == State.AIM


func _show_tracer(from: Vector3, to: Vector3) -> void:
	_stretch(_tracer, from, to)
	_tracer.visible = true
	get_tree().create_timer(TRACER_TIME, false).timeout.connect(func() -> void:
		if is_instance_valid(_tracer):
			_tracer.visible = false)


# --- Exploder -----------------------------------------------------------------

# Close to the player: keeps coming, beeping fast, then blows up.
func _armed(delta: float) -> void:
	if _player_alive():
		_walk_to(_player.global_position, delta, 0.6)
	else:
		_stop()
	if _state_time >= ARM_TIME:
		killed_by_player = false
		_explode()
		if state != State.DEAD:
			_die()


func _explode() -> void:
	if _exploded:
		return
	_exploded = true
	_hide_laser()
	$Model.visible = false  # blown apart
	Blast.detonate(self, global_position, BLAST_RADIUS, BLAST_ENEMY_DAMAGE,
			_player, BLAST_RADIUS, BLAST_PLAYER_DAMAGE)


## True once an exploder has gone off.
func has_exploded() -> bool:
	return _exploded


# --- Look and sound -----------------------------------------------------------

# Type colours (and glowing parts) on copies of the model's materials.
func _recolor() -> void:
	if stats.colors.is_empty() and stats.glow.is_empty():
		return
	for mi: MeshInstance3D in meshes:
		for s in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(s) as StandardMaterial3D
			if src == null:
				continue
			var key := src.resource_name
			if not stats.colors.has(key) and not stats.glow.has(key):
				continue
			var m := src.duplicate() as StandardMaterial3D
			if stats.colors.has(key):
				m.albedo_color = stats.colors[key]
			if stats.glow.has(key):
				m.emission_enabled = true
				m.emission = stats.glow[key]
				m.emission_energy_multiplier = 1.5
				_glow_materials.append(m)
			mi.set_surface_override_material(s, m)


# Exploders pulse (faster when about to blow up) and beep; the boss's eyes glow steadily.
func _update_glow(delta: float) -> void:
	if kind != "exploder" or _exploded:
		return
	var rate := 9.0 if state == State.ARMED else 2.0
	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 1000.0 * rate * TAU * 0.5)
	for m in _glow_materials:
		m.emission_energy_multiplier = lerpf(0.3, 3.0, pulse)
	if state == State.DEAD:
		return
	_beep_timer -= delta
	if _beep_timer <= 0.0:
		_beep_timer = 0.15 if state == State.ARMED else 1.0
		_sfx.stream = EXPLODER_BEEP
		_sfx.pitch_scale = 1.5 if state == State.ARMED else 1.0
		_sfx.play()


# Heavy types thud on every step.
func _update_steps(delta: float) -> void:
	if stats.steps.is_empty() or state != State.CHASE:
		return
	_step_timer -= delta
	if _step_timer <= 0.0:
		var cycle := anim.get_animation(stats.anims.walk).length
		_step_timer = cycle * 0.5 / maxf(_walk_anim_speed(), 0.1)
		hit_player.stream = stats.steps.pick_random()
		hit_player.pitch_scale = randf_range(0.6, 0.75)
		hit_player.play()
		if kind == "boss" and _player_alive() and _flat_distance_to_player() < 12.0:
			_player.add_shake(0.25)


func _spawn_blood(pos: Vector3, normal: Vector3) -> void:
	var blood := BLOOD_SCENE.instantiate()
	get_tree().current_scene.add_child(blood)
	blood.setup(pos, normal)


# Brief white overlay on every mesh of the model.
func _flash() -> void:
	for mesh: MeshInstance3D in meshes:
		mesh.material_overlay = FLASH_MATERIAL
	_flash_timer = FLASH_TIME


func _update_flash(delta: float) -> void:
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			for mesh: MeshInstance3D in meshes:
				mesh.material_overlay = null


# Every few seconds a growl, moan or shriek (each type has its own voice).
func _update_growl(delta: float) -> void:
	_growl_timer -= delta
	if _growl_timer <= 0.0:
		var p: Vector2 = stats.growl_pitch
		_growl(randf_range(p.x, p.y))
		_growl_timer = randf_range(3.0, 6.0) if kind == "runner" else randf_range(5.0, 10.0)


func _growl(pitch: float) -> void:
	if stats.growls == null:
		# Normal zombies: a short random slice of the moan recording.
		growl_player.pitch_scale = pitch
		growl_player.volume_db = 0.0
		growl_player.play(randf_range(0.0, growl_player.stream.get_length() - 2.0))
		var tween := create_tween()
		tween.tween_interval(1.2)
		tween.tween_property(growl_player, "volume_db", -40.0, 0.5)
		tween.tween_callback(growl_player.stop)
		return
	growl_player.stream = stats.growls.pick_random()
	var p: Vector2 = stats.growl_pitch
	growl_player.pitch_scale = randf_range(p.x, p.y) * (0.8 if state == State.DEAD else 1.0)
	growl_player.volume_db = 0.0
	growl_player.play()
