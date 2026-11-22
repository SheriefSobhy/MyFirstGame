extends CharacterBody3D
## First-person player: movement, mouse/touch look, shooting, reloading and health.
## Also does the "feel" effects: head bob, weapon sway, recoil, camera shake,
## footsteps and the reload animation.

signal health_changed(health: int)
signal ammo_changed(ammo: int, max_ammo: int, reloading: bool)
signal died
signal hit_taken  # god mode: hit without losing health

const WALK_SPEED := 5.0
const RUN_SPEED := 8.5
const JUMP_VELOCITY := 5.0
const MOUSE_SENSITIVITY := 0.002  # radians per pixel of mouse movement
## Walking is turned off for now: the player stands still and can only aim,
## shoot, reload and jump. Set this back to true to bring WASD/joystick back.
const MOVEMENT_ENABLED := false
## God mode for testing: enemy hits still shake the camera and flash the
## screen red, but health never goes down. Set to false for the real game.
const GOD_MODE := true

const MAX_HEALTH := 100
const MAX_AMMO := 30
const DAMAGE := 1           # damage dealt per bullet
const FIRE_DELAY := 0.15    # seconds between shots while holding the button
const RELOAD_TIME := 1.5    # seconds
const FLASH_TIME := 0.05    # how long the muzzle flash stays visible

# Feel tuning.
const BOB_SPEED := 1.6          # head-bob cycles per metre walked
const BOB_HEIGHT := 0.05
const BOB_SIDE := 0.035
const SWAY_AMOUNT := 0.0012     # weapon lag per pixel of look movement
const RECOIL_KICK := 1.0
const SHAKE_ON_SHOT := 0.25
const SHAKE_ON_HIT := 0.8

const BULLET_HOLE_SCENE := preload("res://effects/bullet_hole.tscn")
const IMPACT_SCENE := preload("res://effects/impact_sparks.tscn")
const FOOTSTEP_SOUNDS := [
	preload("res://assets/sounds/footstep_concrete_000.ogg"),
	preload("res://assets/sounds/footstep_concrete_001.ogg"),
	preload("res://assets/sounds/footstep_concrete_002.ogg"),
	preload("res://assets/sounds/footstep_concrete_003.ogg"),
	preload("res://assets/sounds/footstep_concrete_004.ogg"),
]
const RELOAD_OUT_SOUND := preload("res://assets/sounds/metalClick.ogg")
const RELOAD_IN_SOUND := preload("res://assets/sounds/metalLatch.ogg")

var health := MAX_HEALTH
var ammo := MAX_AMMO
var is_dead := false

# Set by the on-screen touch controls (see touch_controls.gd).
var touch_move := Vector2.ZERO   # joystick direction, length 0..1
var touch_shoot := false         # true while the Shoot button is held
var _jump_requested := false

# Countdown timers (in seconds), ticked down every frame.
var _fire_cooldown := 0.0
var _reload_timer := 0.0
var _flash_timer := 0.0

# Feel state.
var _bob_time := 0.0       # advances while walking; drives head bob and footsteps
var _bob_blend := 0.0      # 0 = standing still, 1 = full bob
var _last_step := 0
var _sway := Vector2.ZERO  # recent look movement, makes the gun lag behind
var _recoil := 0.0
var _shake := 0.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var ray: RayCast3D = $Head/Camera3D/RayCast3D
@onready var weapon_sway: Node3D = $Head/Camera3D/WeaponSway
@onready var weapon_reload: Node3D = $Head/Camera3D/WeaponSway/WeaponReload
@onready var weapon_recoil: Node3D = $Head/Camera3D/WeaponSway/WeaponReload/WeaponRecoil
@onready var muzzle_flash: Node3D = $Head/Camera3D/WeaponSway/WeaponReload/WeaponRecoil/Muzzle/MuzzleFlash
@onready var shoot_sound: AudioStreamPlayer = $ShootSound
@onready var reload_sound: AudioStreamPlayer = $ReloadSound
@onready var footstep_sound: AudioStreamPlayer = $FootstepSound
@onready var _weapon_base_position := weapon_sway.position


func _ready() -> void:
	ray.add_exception(self)  # never hit our own body
	muzzle_flash.visible = false
	# The gun is drawn close to the camera; its shadow would look odd.
	for mesh: MeshInstance3D in weapon_recoil.find_children("*", "MeshInstance3D", true, false):
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# On touch devices the mouse is never captured; touch controls are used instead.
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if is_dead:
		return

	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

	if event is InputEventMouseMotion and captured:
		look(event.relative)
	elif event.is_action_pressed("release_mouse"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and not captured \
			and event.device != InputEvent.DEVICE_ID_EMULATION:
		# Clicking the window with a real mouse grabs it again (taps on a touch
		# screen also arrive as "emulated" mouse clicks, which we ignore).
		# The short cooldown stops that same click from also firing a shot.
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_fire_cooldown = 0.2
	elif event.is_action_pressed("reload"):
		start_reload()


func _process(delta: float) -> void:
	# Hide the muzzle flash shortly after a shot.
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			muzzle_flash.visible = false
	_update_feel(delta)


func _physics_process(delta: float) -> void:
	if is_dead:
		return

	# Gravity and jumping.
	if not is_on_floor():
		velocity += get_gravity() * delta
	var wants_jump := Input.is_action_just_pressed("jump") or _jump_requested
	_jump_requested = false
	if wants_jump and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# WASD (or the touch joystick) movement relative to where the player is facing.
	var input_dir := Vector2.ZERO
	if MOVEMENT_ENABLED:
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		input_dir = (input_dir + touch_move).limit_length(1.0)
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	var speed := RUN_SPEED if Input.is_action_pressed("sprint") else WALK_SPEED
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
	move_and_slide()

	# Shooting (hold to fire) and reloading.
	_fire_cooldown -= delta
	if _reload_timer > 0.0:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			ammo = MAX_AMMO
			ammo_changed.emit(ammo, MAX_AMMO, false)
	else:
		var mouse_shoot := Input.is_action_pressed("shoot") \
				and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		if mouse_shoot or touch_shoot:
			shoot()


## Rotate the view by a mouse/finger movement in pixels.
## Turns the body left/right and tilts the head up/down.
func look(relative: Vector2) -> void:
	rotate_y(-relative.x * MOUSE_SENSITIVITY)
	head.rotate_x(-relative.y * MOUSE_SENSITIVITY)
	head.rotation.x = clampf(head.rotation.x, deg_to_rad(-89.0), deg_to_rad(89.0))
	_sway = (_sway + relative).limit_length(60.0)


## Called by the touch Jump button; the jump happens on the next physics frame.
func request_jump() -> void:
	_jump_requested = true


func shoot() -> void:
	if _fire_cooldown > 0.0 or _reload_timer > 0.0:
		return
	if ammo <= 0:
		start_reload()  # out of bullets: reload automatically
		return

	ammo -= 1
	_fire_cooldown = FIRE_DELAY
	ammo_changed.emit(ammo, MAX_AMMO, false)

	# Flash, sound, kick and shake.
	muzzle_flash.visible = true
	muzzle_flash.rotation.z = randf() * TAU
	muzzle_flash.scale = Vector3.ONE * randf_range(0.8, 1.2)
	_flash_timer = FLASH_TIME
	shoot_sound.pitch_scale = randf_range(0.95, 1.05)
	shoot_sound.play()
	_recoil = minf(_recoil + RECOIL_KICK, 1.5)
	_shake = maxf(_shake, SHAKE_ON_SHOT)

	# The ray points straight out of the camera, i.e. through the crosshair.
	ray.force_raycast_update()
	if not ray.is_colliding():
		return
	var target := ray.get_collider()
	var point := ray.get_collision_point()
	var normal := ray.get_collision_normal()
	if target.has_method("take_damage"):
		target.take_damage(DAMAGE, point, normal)  # enemy: blood + hit reaction
	else:
		_spawn_impact(point, normal)               # wall/prop: hole + sparks + dust


func start_reload() -> void:
	if _reload_timer > 0.0 or ammo == MAX_AMMO or is_dead:
		return
	_reload_timer = RELOAD_TIME
	ammo_changed.emit(ammo, MAX_AMMO, true)
	_play_reload_sound(RELOAD_OUT_SOUND)

	# Reload animation: tilt the gun down, pause, bring it back up.
	var tween := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(weapon_reload, "rotation", Vector3(deg_to_rad(-35), deg_to_rad(10), deg_to_rad(30)), 0.3)
	tween.parallel().tween_property(weapon_reload, "position", Vector3(0.0, -0.08, 0.04), 0.3)
	tween.tween_interval(RELOAD_TIME - 0.7)
	tween.tween_callback(_play_reload_sound.bind(RELOAD_IN_SOUND))
	tween.tween_property(weapon_reload, "rotation", Vector3.ZERO, 0.3)
	tween.parallel().tween_property(weapon_reload, "position", Vector3.ZERO, 0.3)


func take_damage(amount: int) -> void:
	if is_dead:
		return
	_shake = maxf(_shake, SHAKE_ON_HIT)
	if GOD_MODE:
		hit_taken.emit()  # red flash only
		return
	health = maxi(health - amount, 0)
	health_changed.emit(health)
	if health == 0:
		is_dead = true
		died.emit()


func _spawn_impact(point: Vector3, normal: Vector3) -> void:
	var scene_root := get_tree().current_scene
	var hole := BULLET_HOLE_SCENE.instantiate()
	scene_root.add_child(hole)
	hole.setup(point, normal)
	var impact := IMPACT_SCENE.instantiate()
	scene_root.add_child(impact)
	impact.setup(point, normal)


func _play_reload_sound(stream: AudioStream) -> void:
	reload_sound.stream = stream
	reload_sound.play()


# Head bob, footsteps, weapon sway, recoil and camera shake.
func _update_feel(delta: float) -> void:
	var speed := Vector2(velocity.x, velocity.z).length()
	var moving := is_on_floor() and speed > 0.5 and not is_dead
	if moving:
		_bob_time += delta * speed * BOB_SPEED
		# One footstep every half bob cycle (each time the head dips).
		var step := int(_bob_time / PI)
		if step != _last_step:
			_last_step = step
			footstep_sound.stream = FOOTSTEP_SOUNDS.pick_random()
			footstep_sound.pitch_scale = randf_range(0.9, 1.1)
			footstep_sound.play()
	_bob_blend = lerpf(_bob_blend, 1.0 if moving else 0.0, clampf(delta * 8.0, 0.0, 1.0))

	# Head bob: the camera dips twice per cycle and sways side to side once.
	var bob := Vector3(cos(_bob_time) * BOB_SIDE, -absf(sin(_bob_time)) * BOB_HEIGHT, 0.0) * _bob_blend
	camera.position = bob

	# Weapon sway: lags behind look movement and bobs a little while walking.
	_sway = _sway.lerp(Vector2.ZERO, clampf(delta * 10.0, 0.0, 1.0))
	weapon_sway.position = _weapon_base_position \
			+ Vector3(-_sway.x * SWAY_AMOUNT, _sway.y * SWAY_AMOUNT, 0.0) \
			+ Vector3(cos(_bob_time) * 0.012, -absf(sin(_bob_time)) * 0.015, 0.0) * _bob_blend
	weapon_sway.rotation = Vector3(_sway.y * 0.002, _sway.x * 0.002, -_sway.x * 0.001)

	# Recoil: the gun kicks back and up, then settles.
	_recoil = lerpf(_recoil, 0.0, clampf(delta * 12.0, 0.0, 1.0))
	weapon_recoil.position = Vector3(0.0, 0.0, _recoil * 0.06)
	weapon_recoil.rotation = Vector3(_recoil * 0.2, 0.0, 0.0)

	# Camera shake: small random rotations that fade out quickly.
	_shake = move_toward(_shake, 0.0, delta * 2.5)
	var s := _shake * _shake * 0.03
	camera.rotation = Vector3(randf_range(-s, s), randf_range(-s, s), randf_range(-s, s) * 0.5)
