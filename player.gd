extends CharacterBody3D
## First-person player: movement, mouse/touch look, weapons and health.
## The weapons' stats live in weapon_stats.gd. This script handles shooting,
## reloading, switching, the sniper scope and pickups, plus the "feel"
## effects: head bob, weapon sway, recoil, camera shake and footsteps.

signal health_changed(health: int)
## reserve is -1 when the weapon has unlimited spare ammo.
signal ammo_changed(ammo: int, reserve: int, reloading: bool)
signal weapon_changed(weapon_name: String)
signal scope_changed(scoped: bool)
signal message(text: String)  # short HUD notice, e.g. "Picked up Shotgun"
signal died
signal hit_taken  # god mode: hit without losing health

const Weapons := preload("res://weapon_stats.gd")
const WeaponModel := preload("res://weapon_model.gd")

const WALK_SPEED := 5.0
const RUN_SPEED := 8.5
const JUMP_VELOCITY := 5.0
const MOUSE_SENSITIVITY := 0.002  # radians per pixel of mouse movement
## Walking is needed to reach the weapon and ammo pickups. Set this to false
## to stand still and only aim, shoot, reload and jump.
const MOVEMENT_ENABLED := true
## God mode for testing: enemy hits still shake the camera and flash the
## screen red, but health never goes down. Set to false for the real game.
const GOD_MODE := false

const MAX_HEALTH := 100
const FLASH_TIME := 0.05    # how long the muzzle flash stays visible
const BASE_FOV := 75.0
const SHOT_MASK := 1        # physics layers bullets can hit
const MAX_SPARKS_PER_SHOT := 2  # shotgun: limit wall sparks (phones)
const SWITCH_DOWN_TIME := 0.15
const SWITCH_UP_TIME := 0.2
const DRY_FIRE_SOUND := preload("res://assets/sounds/metalClick.ogg")

# Feel tuning.
const BOB_SPEED := 1.6          # head-bob cycles per metre walked
const BOB_HEIGHT := 0.05
const BOB_SIDE := 0.035
const SWAY_AMOUNT := 0.0012     # weapon lag per pixel of look movement
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

var health := MAX_HEALTH
var is_dead := false
var weapon_index := 0       # slot in Weapons.LIST

# Set by the on-screen touch controls (see touch_controls.gd).
var touch_move := Vector2.ZERO   # joystick direction, length 0..1
var touch_shoot := false         # true while the Shoot button is held
var _jump_requested := false

# Per-weapon state, indexed like Weapons.LIST.
var _owned: Array[bool] = []
var _mag: Array[int] = []        # rounds in the magazine
var _reserve: Array[int] = []    # spare rounds (-1 = unlimited)
var _views: Array[Node3D] = []   # first-person models (only the current one is shown)
var _muzzles: Array[Vector3] = []

# Countdown timers (in seconds), ticked down every frame.
var _fire_cooldown := 0.0
var _reload_timer := 0.0
var _flash_timer := 0.0

var _trigger_ready := true   # semi-auto: the trigger was released since the last shot
var _reload_queued := false  # reload pressed while pumping / cycling the bolt
var _switching := false
var _aim_wanted := false     # right mouse held, or the touch AIM button toggled on
var _scoped := false
var _spread := 0.0           # extra spread from sustained fire (degrees)
var _weapon_tween: Tween     # reload / switch / pump animation
var _sound_tween: Tween      # reload sounds
var _fov_tween: Tween

# Feel state.
var _bob_time := 0.0       # advances while walking; drives head bob and footsteps
var _bob_blend := 0.0      # 0 = standing still, 1 = full bob
var _last_step := 0
var _sway := Vector2.ZERO  # recent look movement, makes the gun lag behind
var _recoil := 0.0
var _shake := 0.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var weapon_sway: Node3D = $Head/Camera3D/WeaponSway
@onready var weapon_reload: Node3D = $Head/Camera3D/WeaponSway/WeaponReload
@onready var weapon_recoil: Node3D = $Head/Camera3D/WeaponSway/WeaponReload/WeaponRecoil
@onready var gun_holder: Node3D = %Gun
@onready var arms: Node3D = $Head/Camera3D/WeaponSway/WeaponReload/WeaponRecoil/Arms
@onready var muzzle: Node3D = $Head/Camera3D/WeaponSway/WeaponReload/WeaponRecoil/Muzzle
@onready var muzzle_flash: Node3D = %MuzzleFlash
@onready var shoot_sound: AudioStreamPlayer = $ShootSound
@onready var reload_sound: AudioStreamPlayer = $ReloadSound
@onready var cycle_sound: AudioStreamPlayer = $CycleSound
@onready var footstep_sound: AudioStreamPlayer = $FootstepSound
@onready var _weapon_base_position := weapon_sway.position


func _ready() -> void:
	muzzle_flash.visible = false
	for i in Weapons.LIST.size():
		var w: Dictionary = Weapons.LIST[i]
		_owned.append(i == 0)  # start with the pistol only
		_mag.append(w.mag_size)
		_reserve.append(w.reserve)
		_add_view_model(w)
	# The gun is drawn close to the camera; its shadow would look odd.
	WeaponModel.no_shadows(weapon_recoil)
	_show_weapon(0)
	# On touch devices the mouse is never captured; touch controls are used instead.
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# Builds the first-person model for one weapon: scaled to view_length, barrel
# pointing forward (-Z), and remembers where its muzzle is.
func _add_view_model(w: Dictionary) -> void:
	var model: Node3D = w.model.instantiate()
	var info := WeaponModel.measure(model)
	var aabb: AABB = info.aabb
	var s: float = w.view_length / aabb.size.x
	model.transform = Transform3D(Basis(Vector3.UP, PI / 2.0).scaled(Vector3.ONE * s), w.view_offset)
	model.visible = false
	gun_holder.add_child(model)
	_views.append(model)
	_muzzles.append(model.transform * info.tip)


func _unhandled_input(event: InputEvent) -> void:
	if is_dead:
		return

	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

	if event is InputEventMouseMotion and captured:
		look(event.relative)
	elif event.is_action_pressed("release_mouse"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and not captured \
			and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT] \
			and event.device != InputEvent.DEVICE_ID_EMULATION:
		# Clicking the window with a real mouse grabs it again (taps on a touch
		# screen also arrive as "emulated" mouse clicks, which we ignore).
		# The short cooldown stops that same click from also firing a shot.
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_fire_cooldown = maxf(_fire_cooldown, 0.2)
		_trigger_ready = false
	elif event.is_action_pressed("reload"):
		start_reload()
	elif event.is_action_pressed("weapon_next"):
		next_weapon(1)
	elif event.is_action_pressed("weapon_prev"):
		next_weapon(-1)
	elif event.is_action_pressed("aim"):
		_aim_wanted = true
	elif event.is_action_released("aim"):
		_aim_wanted = false
	else:
		for i in Weapons.LIST.size():
			if event.is_action_pressed("weapon_%d" % (i + 1)):
				switch_to(i)


func _process(delta: float) -> void:
	# Hide the muzzle flash shortly after a shot.
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			muzzle_flash.visible = false
	var want_scope := _aim_wanted and can_aim() and not is_dead \
			and not _switching and _reload_timer <= 0.0
	if want_scope != _scoped:
		_set_scoped(want_scope)
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

	# Shooting (hold to fire for automatic weapons) and reloading.
	var w := current_weapon()
	_fire_cooldown -= delta
	# Spread from sustained fire shrinks once you stop shooting for a moment.
	if _fire_cooldown < -0.1:
		_spread = move_toward(_spread, 0.0, w.spread_recovery * delta)
	if _reload_timer > 0.0:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			_finish_reload()
	elif _reload_queued and _fire_cooldown <= 0.0:
		_reload_queued = false
		start_reload()
	var mouse_shoot := Input.is_action_pressed("shoot") \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if mouse_shoot or touch_shoot:
		shoot()
	else:
		_trigger_ready = true


## Rotate the view by a mouse/finger movement in pixels.
## Turns the body left/right and tilts the head up/down. Slower while scoped.
## Scaled by the look sensitivity from the settings screen.
func look(relative: Vector2) -> void:
	relative *= camera.fov / BASE_FOV * Settings.look_sensitivity
	rotate_y(-relative.x * MOUSE_SENSITIVITY)
	head.rotate_x(-relative.y * MOUSE_SENSITIVITY)
	head.rotation.x = clampf(head.rotation.x, deg_to_rad(-89.0), deg_to_rad(89.0))
	_sway = (_sway + relative).limit_length(60.0)


## Called by the touch Jump button; the jump happens on the next physics frame.
func request_jump() -> void:
	_jump_requested = true


func current_weapon() -> Dictionary:
	return Weapons.LIST[weapon_index]


func ammo() -> int:
	return _mag[weapon_index]


func reserve() -> int:
	return _reserve[weapon_index]


func has_weapon(index: int) -> bool:
	return _owned[index]


func is_reloading() -> bool:
	return _reload_timer > 0.0


func is_scoped() -> bool:
	return _scoped


## True for weapons with a scope (the sniper).
func can_aim() -> bool:
	return current_weapon().zoom_fov > 0.0


## Touch AIM button: scope in / out.
func toggle_aim() -> void:
	_aim_wanted = not _scoped


# --- Shooting ---------------------------------------------------------------

func shoot() -> void:
	if _switching or _fire_cooldown > 0.0 or _reload_timer > 0.0:
		return
	var w := current_weapon()
	if not w.automatic and not _trigger_ready:
		return
	_trigger_ready = false
	if _mag[weapon_index] <= 0:
		if _reserve[weapon_index] != 0:
			start_reload()  # out of rounds: reload automatically
		else:
			_play_reload_sound(DRY_FIRE_SOUND)  # nothing left: click
			_fire_cooldown = 0.3
		return

	_mag[weapon_index] -= 1
	_fire_cooldown = w.fire_delay
	_emit_ammo()

	# Flash, sound, kick and shake.
	muzzle_flash.visible = true
	muzzle_flash.rotation.z = randf() * TAU
	muzzle_flash.scale = Vector3.ONE * w.flash_size * randf_range(0.8, 1.2)
	_flash_timer = FLASH_TIME
	shoot_sound.pitch_scale = randf_range(0.95, 1.05)
	shoot_sound.play()
	_recoil = minf(_recoil + w.recoil, maxf(1.5, w.recoil))
	_shake = maxf(_shake, w.shake)
	if w.cycle_sound:
		_play_cycle(w)

	# Bullets go out of the camera, i.e. through the crosshair, with some
	# random spread. Pellets that hit the same enemy are added together so it
	# takes one hit (one blood splash, one stagger) per shot.
	var spread: float = (w.scoped_spread if _scoped else w.spread) + _spread
	_spread = minf(_spread + w.spread_per_shot, w.max_spread)
	var enemy_hits := {}
	var sparks := 0
	for i in w.pellets:
		var hit := _fire_ray(_spread_direction(spread), w.range)
		if hit.is_empty():
			continue
		var target: Object = hit.collider
		if target.has_method("take_damage"):
			if enemy_hits.has(target):
				enemy_hits[target].damage += w.damage
			else:
				enemy_hits[target] = {"damage": w.damage, "point": hit.position, "normal": hit.normal}
		else:
			_spawn_impact(hit.position, hit.normal, sparks < MAX_SPARKS_PER_SHOT)
			sparks += 1
	for target: Object in enemy_hits:
		var h: Dictionary = enemy_hits[target]
		target.take_damage(h.damage, h.point, h.normal)  # enemy: blood + hit reaction

	# The view climbs a little (after the bullets left, so they go where you aimed).
	head.rotation.x = minf(head.rotation.x + deg_to_rad(w.view_kick), deg_to_rad(89.0))


func _fire_ray(dir: Vector3, length: float) -> Dictionary:
	var from := camera.global_position
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * length, SHOT_MASK, [get_rid()])
	return get_world_3d().direct_space_state.intersect_ray(query)


# A random direction inside a cone of `degrees` around where the camera looks.
func _spread_direction(degrees: float) -> Vector3:
	var b := camera.global_basis
	if degrees <= 0.0:
		return -b.z
	var angle := randf() * TAU
	var radius := tan(deg_to_rad(degrees)) * sqrt(randf())
	return (-b.z + (b.x * cos(angle) + b.y * sin(angle)) * radius).normalized()


# Pump / bolt after a shot: a sound and a small pull-back of the gun.
func _play_cycle(w: Dictionary) -> void:
	_kill_weapon_tween()
	_weapon_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_weapon_tween.tween_interval(w.cycle_delay)
	_weapon_tween.tween_callback(func() -> void:
		cycle_sound.stream = w.cycle_sound
		cycle_sound.play())
	_weapon_tween.tween_property(weapon_reload, "position", Vector3(0.0, -0.015, 0.05), 0.15)
	_weapon_tween.parallel().tween_property(weapon_reload, "rotation", Vector3(0.0, 0.0, deg_to_rad(12)), 0.15)
	_weapon_tween.tween_property(weapon_reload, "position", Vector3.ZERO, 0.2)
	_weapon_tween.parallel().tween_property(weapon_reload, "rotation", Vector3.ZERO, 0.2)


# --- Reloading --------------------------------------------------------------

func start_reload() -> void:
	if is_dead or _switching or _reload_timer > 0.0:
		return
	var w := current_weapon()
	if _mag[weapon_index] >= w.mag_size or _reserve[weapon_index] == 0:
		return
	if _fire_cooldown > 0.0:
		_reload_queued = true  # still pumping / cycling the bolt: reload right after
		return
	_aim_wanted = false
	_reload_timer = w.reload_time
	_emit_ammo()

	_sound_tween = create_tween()
	for entry: Array in w.reload_sounds:
		_sound_tween.parallel().tween_callback(_play_reload_sound.bind(entry[1])).set_delay(entry[0])

	# Reload animation: tilt the gun down, pause, bring it back up.
	_kill_weapon_tween()
	var t: float = w.reload_time
	_weapon_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_weapon_tween.tween_property(weapon_reload, "rotation", Vector3(deg_to_rad(-35), deg_to_rad(10), deg_to_rad(30)), 0.3)
	_weapon_tween.parallel().tween_property(weapon_reload, "position", Vector3(0.0, -0.08, 0.04), 0.3)
	_weapon_tween.tween_interval(maxf(t - 0.7, 0.0))
	_weapon_tween.tween_property(weapon_reload, "rotation", Vector3.ZERO, 0.3)
	_weapon_tween.parallel().tween_property(weapon_reload, "position", Vector3.ZERO, 0.3)


func _finish_reload() -> void:
	var w := current_weapon()
	var need: int = w.mag_size - _mag[weapon_index]
	if _reserve[weapon_index] >= 0:
		need = mini(need, _reserve[weapon_index])
		_reserve[weapon_index] -= need
	_mag[weapon_index] += need
	_emit_ammo()


func _cancel_reload() -> void:
	_reload_timer = 0.0
	_reload_queued = false
	if _sound_tween:
		_sound_tween.kill()


# --- Switching --------------------------------------------------------------

## Switch to the weapon in `index` (0-based slot) if the player has it.
func switch_to(index: int) -> void:
	if index == weapon_index or index < 0 or index >= _owned.size() \
			or not _owned[index] or is_dead:
		return
	_cancel_reload()
	_aim_wanted = false
	_set_scoped(false)
	_switching = true
	_emit_ammo()
	# Lower the current gun, swap models, raise the new one.
	_kill_weapon_tween()
	_weapon_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_weapon_tween.tween_property(weapon_reload, "position", Vector3(0.0, -0.25, 0.05), SWITCH_DOWN_TIME)
	_weapon_tween.parallel().tween_property(weapon_reload, "rotation", Vector3(deg_to_rad(-40), 0.0, 0.0), SWITCH_DOWN_TIME)
	_weapon_tween.tween_callback(_show_weapon.bind(index))
	_weapon_tween.tween_property(weapon_reload, "position", Vector3.ZERO, SWITCH_UP_TIME)
	_weapon_tween.parallel().tween_property(weapon_reload, "rotation", Vector3.ZERO, SWITCH_UP_TIME)
	_weapon_tween.tween_callback(func() -> void: _switching = false)


## Cycle through the weapons the player owns (+1 = next, -1 = previous).
func next_weapon(direction: int) -> void:
	var count := _owned.size()
	var i := weapon_index
	for step in count - 1:
		i = posmod(i + direction, count)
		if _owned[i]:
			switch_to(i)
			return


func _show_weapon(index: int) -> void:
	weapon_index = index
	var w := current_weapon()
	for i in _views.size():
		_views[i].visible = i == index
	muzzle.position = _muzzles[index]
	shoot_sound.stream = w.shot_sound
	shoot_sound.volume_db = w.shot_volume_db
	_spread = 0.0
	arms.grip(w.arms_offset, w.left_hand, w.left_hand_forward, w.left_hand_back)
	weapon_changed.emit(w.name)
	_emit_ammo()


func _kill_weapon_tween() -> void:
	if _weapon_tween:
		_weapon_tween.kill()
	weapon_reload.position = Vector3.ZERO
	weapon_reload.rotation = Vector3.ZERO


# --- Scope ------------------------------------------------------------------

func _set_scoped(on: bool) -> void:
	if on == _scoped:
		return
	_scoped = on
	var fov: float = current_weapon().zoom_fov if on else BASE_FOV
	if _fov_tween:
		_fov_tween.kill()
	_fov_tween = create_tween()
	_fov_tween.tween_property(camera, "fov", fov, 0.12)
	weapon_sway.visible = not on  # the gun would block the scope view
	scope_changed.emit(on)


# --- Pickups ----------------------------------------------------------------

## Called by weapon pickups. Returns true if the pickup was used.
func give_weapon(index: int) -> bool:
	if is_dead:
		return false
	var w: Dictionary = Weapons.LIST[index]
	if _owned[index]:
		return _add_reserve(index)
	_owned[index] = true
	_mag[index] = w.mag_size
	_reserve[index] = w.reserve
	message.emit("Picked up %s" % w.name)
	switch_to(index)
	return true


## Called by ammo boxes: spare ammo for every weapon the player owns.
## Returns false (and the box stays) if everything is already full.
func give_ammo() -> bool:
	if is_dead:
		return false
	var added := false
	for i in _owned.size():
		if _owned[i] and _add_reserve(i):
			added = true
	if added:
		message.emit("+ Ammo")
		_emit_ammo()
	return added


func _add_reserve(index: int) -> bool:
	var w: Dictionary = Weapons.LIST[index]
	if w.max_reserve < 0 or _reserve[index] >= w.max_reserve:
		return false
	_reserve[index] = mini(_reserve[index] + w.ammo_box, w.max_reserve)
	return true


## Sends the current weapon and ammo to the HUD.
func emit_status() -> void:
	weapon_changed.emit(current_weapon().name)
	_emit_ammo()


func _emit_ammo() -> void:
	ammo_changed.emit(_mag[weapon_index], _reserve[weapon_index], _reload_timer > 0.0)


## Shows every gun model for a moment so their shaders compile while the
## level loads (see main.gd), then goes back to the current one.
func show_all_view_models(on: bool) -> void:
	for i in _views.size():
		_views[i].visible = on or i == weapon_index


# --- Health -----------------------------------------------------------------

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
		_set_scoped(false)
		died.emit()


## Restores health (e.g. after clearing a wave), up to MAX_HEALTH.
func heal(amount: int) -> void:
	if is_dead:
		return
	health = mini(health + amount, MAX_HEALTH)
	health_changed.emit(health)


func _spawn_impact(point: Vector3, normal: Vector3, with_sparks: bool) -> void:
	var scene_root := get_tree().current_scene
	var hole := BULLET_HOLE_SCENE.instantiate()
	scene_root.add_child(hole)
	hole.setup(point, normal)
	if with_sparks:
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
