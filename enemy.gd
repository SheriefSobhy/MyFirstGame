extends CharacterBody3D
## Animated soldier enemy: walks to the player around obstacles (navmesh),
## punches when close, staggers when shot and plays a death animation.

signal died

enum State { CHASE, ATTACK, HIT, DEAD }

const MAX_HP := 3
const WALK_SPEED := 1.4           # metres per second (slow, shambling walk)
## The walk animation was made for about 2.3 m/s; slowing it down to match
## keeps the feet from sliding over the ground.
const WALK_ANIM_SPEED := WALK_SPEED / 2.3
const TURN_SPEED := 8.0           # how fast the enemy turns to face its direction
const ATTACK_RANGE := 1.4         # start punching within this distance
const ATTACK_DAMAGE := 10
const ATTACK_HIT_TIME := 0.4      # when in the punch animation the damage lands
const ATTACK_DURATION := 0.85     # length of one punch
const HIT_STUN_TIME := 0.35       # how long a hit interrupts the enemy
const CORPSE_TIME := 4.0          # seconds the body stays before sinking away
const FLASH_TIME := 0.08

# Animation names inside the Quaternius character model.
const ANIM_WALK := "CharacterArmature|Walk"
const ANIM_IDLE := "CharacterArmature|Idle_Neutral"
const ANIM_ATTACK := "CharacterArmature|Punch_Right"
const ANIM_HIT := "CharacterArmature|HitRecieve"
const ANIM_DEATH := "CharacterArmature|Death"

const BLOOD_SCENE := preload("res://effects/blood_hit.tscn")
const FLASH_MATERIAL := preload("res://effects/hit_flash_material.tres")  # white overlay for hits
const HIT_SOUNDS := [
	preload("res://assets/sounds/impactPunch_medium_000.ogg"),
	preload("res://assets/sounds/impactPunch_medium_001.ogg"),
	preload("res://assets/sounds/impactPunch_medium_002.ogg"),
]

var hp := MAX_HP
var state := State.CHASE
var _state_time := 0.0
var _attack_landed := false
var _repath_timer := 0.0
var _growl_timer := 0.0
var _flash_timer := 0.0
var _player: Node3D

@onready var anim: AnimationPlayer = $Model/AnimationPlayer
@onready var agent: NavigationAgent3D = $NavigationAgent3D
@onready var collision: CollisionShape3D = $CollisionShape3D
@onready var growl_player: AudioStreamPlayer3D = $GrowlPlayer
@onready var hit_player: AudioStreamPlayer3D = $HitPlayer
@onready var meshes: Array[Node] = $Model.find_children("*", "MeshInstance3D", true, false)


func _ready() -> void:
	_player = get_tree().get_first_node_in_group("player")
	# The imported walk/idle animations don't loop by default.
	anim.get_animation(ANIM_WALK).loop_mode = Animation.LOOP_LINEAR
	anim.get_animation(ANIM_IDLE).loop_mode = Animation.LOOP_LINEAR
	anim.play(ANIM_WALK, -1, WALK_ANIM_SPEED)
	anim.seek(randf() * 1.0)  # so a group of enemies doesn't walk in sync
	_growl_timer = randf_range(1.0, 6.0)


func _physics_process(delta: float) -> void:
	_state_time += delta
	_update_flash(delta)

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

	match state:
		State.CHASE:
			_chase(delta)
		State.ATTACK:
			_attack(delta)
		State.HIT:
			velocity.x = move_toward(velocity.x, 0.0, 20.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, 20.0 * delta)
			if _state_time > HIT_STUN_TIME:
				_set_state(State.CHASE)

	move_and_slide()


func _chase(delta: float) -> void:
	if _player == null or _player.is_dead:
		velocity.x = 0.0
		velocity.z = 0.0
		return

	# Ask the navmesh for a new path a few times per second.
	_repath_timer -= delta
	if _repath_timer <= 0.0:
		agent.target_position = _player.global_position
		_repath_timer = 0.25

	var to_target := agent.get_next_path_position() - global_position
	to_target.y = 0.0
	if to_target.length() < 0.05:
		# No path (e.g. navmesh not ready yet): walk straight at the player.
		to_target = _player.global_position - global_position
		to_target.y = 0.0
	var dir := to_target.normalized()
	velocity.x = dir.x * WALK_SPEED
	velocity.z = dir.z * WALK_SPEED
	_turn_towards(dir, delta)

	if _player_in_range(ATTACK_RANGE):
		_set_state(State.ATTACK)


func _attack(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	var to_player := _player.global_position - global_position
	to_player.y = 0.0
	_turn_towards(to_player.normalized(), delta)

	# Deal damage at the moment the punch connects (if the player is still close).
	if not _attack_landed and _state_time >= ATTACK_HIT_TIME:
		_attack_landed = true
		if _player_in_range(ATTACK_RANGE * 1.3):
			_player.take_damage(ATTACK_DAMAGE)
	if _state_time >= ATTACK_DURATION:
		_set_state(State.CHASE)


## Called by the player's gun.
func take_damage(amount: int, hit_position := Vector3.ZERO, hit_normal := Vector3.UP) -> void:
	if state == State.DEAD:
		return
	hp -= amount
	_spawn_blood(hit_position, hit_normal)
	_flash()
	hit_player.stream = HIT_SOUNDS.pick_random()
	hit_player.pitch_scale = randf_range(0.9, 1.1)
	hit_player.play()

	if hp <= 0:
		_die()
	else:
		_set_state(State.HIT)


func _die() -> void:
	_set_state(State.DEAD)
	velocity = Vector3.ZERO
	collision.set_deferred("disabled", true)  # bullets and the player pass through the body
	remove_from_group("enemies")
	_growl(0.7)  # a low groan
	died.emit()


func _set_state(new_state: State) -> void:
	state = new_state
	_state_time = 0.0
	match new_state:
		State.CHASE:
			anim.play(ANIM_WALK, 0.2, WALK_ANIM_SPEED)
		State.ATTACK:
			_attack_landed = false
			_play_from_start(ANIM_ATTACK, 0.1)
		State.HIT:
			_play_from_start(ANIM_HIT, 0.05)
		State.DEAD:
			_play_from_start(ANIM_DEATH, 0.1)


func _play_from_start(anim_name: String, blend: float) -> void:
	anim.play(anim_name, blend)
	anim.seek(0.0, true)


func _player_in_range(distance: float) -> bool:
	var offset := _player.global_position - global_position
	return absf(offset.y) < 1.5 and Vector2(offset.x, offset.z).length() < distance


# Smoothly rotate so the model faces `dir` (the model looks along -Z).
func _turn_towards(dir: Vector3, delta: float) -> void:
	if dir.length_squared() < 0.001:
		return
	var target_yaw := atan2(-dir.x, -dir.z)
	rotation.y = lerp_angle(rotation.y, target_yaw, clampf(TURN_SPEED * delta, 0.0, 1.0))


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


# Every few seconds play a short random slice of the moan recording.
func _update_growl(delta: float) -> void:
	_growl_timer -= delta
	if _growl_timer <= 0.0:
		_growl(randf_range(0.85, 1.1))
		_growl_timer = randf_range(5.0, 10.0)


func _growl(pitch: float) -> void:
	growl_player.pitch_scale = pitch
	growl_player.volume_db = 0.0
	growl_player.play(randf_range(0.0, growl_player.stream.get_length() - 2.0))
	var tween := create_tween()
	tween.tween_interval(1.2)
	tween.tween_property(growl_player, "volume_db", -40.0, 0.5)
	tween.tween_callback(growl_player.stop)
