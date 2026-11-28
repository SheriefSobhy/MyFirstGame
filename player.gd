extends CharacterBody3D
## First-person player: movement, mouse/touch look, weapons and health.
## The weapons' stats live in weapon_stats.gd. This script handles shooting
## (with headshots), reloading, switching, aiming (down the sights, or the
## sniper scope), throwing grenades and pickups, plus the "feel" effects:
## head bob, weapon sway, recoil, camera shake, footsteps, phone vibration
## (effects/haptics.gd), spent casings and the touch-only aim assist.
##
## The first-person view: Camera3D/ViewModel holds the arms (fp_arms.gd) and
## the guns (one weapon_view.gd each, real size). ViewModel is scaled by
## VIEW_SCALE about the eye: the picture is the same as life size, but the
## gun reaches half as far, so it pokes into walls no more than before.
## Positions below that are "view space" are in ViewModel's (life-size) metres.
## A weapon can set its own "view_scale" (smaller = the gun stays further from
## walls) and "view_fov": the gun and arms are then drawn as if through a
## camera with that FOV (ViewModel is also scaled sideways and up by
## tan(fov / 2) / tan(view_fov / 2), the same picture as a second projection,
## without the cost), so a wide phone screen doesn't stretch them.

signal health_changed(health: int)
## reserve is -1 when the weapon has unlimited spare ammo.
signal ammo_changed(ammo: int, reserve: int, reloading: bool)
signal weapon_changed(weapon_name: String)
signal scope_changed(scoped: bool)   # sniper scope overlay on/off
## Any aiming: sights or scope. sight is the weapon's "iron", "red_dot" or "scope".
signal aim_changed(aiming: bool, sight: String)
signal grenades_changed(count: int)
signal message(text: String)  # short HUD notice, e.g. "Picked up Shotgun"
signal died
signal hit_taken  # god mode: hit without losing health
signal armor_changed(armor: int)
## A shot hit an enemy (all pellets on it added up). For the hit marker and
## damage numbers. killed = this shot killed it.
signal enemy_hit(enemy: Node3D, damage: int, point: Vector3, headshot: bool, killed: bool)
## A shot left the gun (before its bullets hit anything): the Training
## Arena's accuracy stats.
signal fired

const Weapons := preload("res://weapon_stats.gd")
const Haptics := preload("res://effects/haptics.gd")
const Economy := preload("res://economy.gd")
const WeaponModel := preload("res://weapon_model.gd")
const WeaponView := preload("res://weapon_view.gd")
const Casings := preload("res://effects/casings.gd")
const FpArms := preload("res://fp_arms.gd")
const Progression := preload("res://progression_config.gd")
const Grenade := preload("res://effects/grenade.gd")

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
const SWITCH_DOWN_TIME := 0.16
const SWITCH_UP_TIME := 0.24
const VIEW_SCALE := 0.5     # ViewModel's scale (see above) unless the weapon sets "view_scale"
const DRY_FIRE_SOUND := preload("res://assets/sounds/metalClick.ogg")

# Grenades.
const START_GRENADES := 3
const MAX_GRENADES := 5
const THROW_SPEED := 15.0       # m/s along the throw direction
const THROW_UP_ANGLE := 12.0    # degrees above where the camera looks
const THROW_COOLDOWN := 0.8
const PREVIEW_DOTS := 36        # dots drawn along the throw arc
const PREVIEW_STEP := 0.02      # seconds of flight between arc samples
const PREVIEW_MAX_TIME := 3.0
const PIN_SOUND := preload("res://assets/sounds/metalClick.ogg")

# Feel tuning.
const BOB_SPEED := 1.6          # head-bob cycles per metre walked
const BOB_HEIGHT := 0.05
const BOB_SIDE := 0.035
const SWAY_AMOUNT := 0.0024     # weapon lag per pixel of look movement (view space)
const GUN_BOB := Vector2(0.024, 0.03)  # gun bob while walking, side / down (view space)
const HIP_TURN := Vector3(3.0, 3.0, -2.0)  # gun turned a little at the hip (degrees): muzzle up, inwards, canted
const RECOIL_BACK := 0.11       # m (view space) per unit of the weapon's recoil
const RECOIL_PITCH := 0.2       # rad per unit
# Sprinting: the gun swings down and across.
const SPRINT_POS := Vector3(-0.05, -0.07, 0.05)
const SPRINT_TURN := Vector3(-24.0, 38.0, 14.0)  # degrees
const SPRINT_BLEND := 7.0       # 1/s, how fast it goes in and out
const CASING_SPEED := Vector3(1.6, 1.3, 0.35)  # right, up, back (m/s)
# Weapons with "recoil_spring" (the Pistol): the kick springs back with a
# little overshoot instead of fading out.
const SPRING_RATE := 26.0       # 1/s (angular frequency)
const SPRING_DAMPING := 0.5     # 1 = no overshoot
# Weapons with "breath" (the Pistol): idle breathing sway and a walk roll.
const BREATH_RATE := 1.55       # rad/s (one breath ~4 s)
const BREATH_MOVE := Vector3(0.0016, 0.0024, 0.0)   # view space, m
const BREATH_TURN := Vector3(0.35, 0.25, 0.3)       # degrees
const WALK_ROLL := 1.6          # degrees of roll per bob step
const SHAKE_ON_HIT := 0.8
const HEADSHOT_MULTIPLIER := 2

# Aim assist (touch controls only, Settings.aim_assist).
const ASSIST_SLOW := 0.5         # look speed while the crosshair is on an enemy
const ASSIST_CONE := 12.0        # degrees: aiming in pulls towards enemies this close to the crosshair
const ASSIST_RANGE := 45.0       # m
const ASSIST_SNAP_TIME := 0.25   # s after aiming in with the stronger pull...
const ASSIST_SNAP_RATE := 5.0    # ...which closes this share (1/s, exponential) of the gap
const ASSIST_TRACK_RATE := 1.2   # then a gentle pull that follows a moving target
const ASSIST_OVER_MARGIN := 1.3  # x the enemy's radius counts as "on" it
const ASSIST_MASK := 3           # walls and props hide enemies from the assist

# Aiming down the sights.
const ADS_TIME := 0.18          # seconds to raise the sights / lower them again
const ADS_MOVE_SCALE := 0.6     # walking speed while aiming
const ADS_SWAY := 0.3           # sway and bob left while aiming (1 = all)
const ADS_SIGHT_DROP := 0.002   # iron sights sit this far (m, view space) below the screen centre

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
var _invulnerable := 0.0     # seconds left of no damage (after a revive)
var weapon_index := 0       # slot in Weapons.LIST
var grenades := START_GRENADES
## Absorbs part of each hit (economy.gd ARMOR_ABSORB) until it runs out.
var armor := 0
## Insta-Kill power-up: every bullet kills (except the Boss). Set by match_economy.gd.
var insta_kill := false
## Training Arena (training/training.gd): no damage at all, spare ammo never
## runs out (reloads still happen) and grenades are never used up.
var invincible := false
var infinite_ammo := false
var infinite_grenades := false

# Set by the on-screen touch controls (see touch_controls.gd).
var touch_move := Vector2.ZERO   # joystick direction, length 0..1
var touch_shoot := false         # true while the Shoot button is held
## true while the touch controls are in use (set by main.gd): aim assist only works then.
var touch_active := false
var _jump_requested := false

# Aim assist state, updated every physics frame.
var _assist_over: Node3D = null    # enemy under the crosshair
var _assist_target: Node3D = null  # enemy aiming in pulls towards
var _aim_time := 0.0               # seconds since aiming in

# Per-weapon state, indexed like Weapons.LIST.
var _owned: Array[bool] = []
var _upgrades: Array[Dictionary] = []  # shop upgrade levels: {"damage", "mag", "reload"}
var _mag: Array[int] = []        # rounds in the magazine
var _reserve: Array[int] = []    # spare rounds (-1 = unlimited)
var _views: Array[Node3D] = []   # first-person models, weapon_view.gd (only the current one is shown)
var _muzzles: Array[Vector3] = []
var _ads_positions: Array[Vector3] = []  # WeaponSway position that centres the sights

# Countdown timers (in seconds), ticked down every frame.
var _fire_cooldown := 0.0
var _reload_timer := 0.0
var _flash_timer := 0.0

var _trigger_ready := true   # semi-auto: the trigger was released since the last shot
var _reload_queued := false  # reload pressed while pumping / cycling the bolt
var _switching := false
var _switch_target := 0       # the weapon being switched to
var _aim_wanted := false     # right mouse held, or the touch AIM button toggled on
var _aiming := false         # aiming with any weapon (sights or scope)
var _scoped := false         # aiming with the sniper scope (overlay shown)
var _ads := 0.0              # 0 = gun at the hip, 1 = sights centred
var _ads_tween: Tween
var _spread := 0.0           # extra spread from sustained fire (degrees)
var _weapon_tween: Tween     # reload / switch / pump animation
var _sound_tween: Tween      # reload sounds
var _fov_tween: Tween

# Grenade throwing.
var _grenade_held := false   # G / GRENADE held: the arc preview is shown
var _throw_cooldown := 0.0
var _preview: MultiMeshInstance3D
var _preview_marker: MeshInstance3D

# Feel state.
var _bob_time := 0.0       # advances while walking; drives head bob and footsteps
var _bob_blend := 0.0      # 0 = standing still, 1 = full bob
var _last_step := 0
var _sway := Vector2.ZERO  # recent look movement, makes the gun lag behind
var _recoil := 0.0
var _recoil_vel := 0.0     # spring recoil (see SPRING_RATE)
var _recoil_side := 0.0    # random sideways part of the last kick (-1..1)
var _breath_time := 0.0
var _arms_sets := {}       # fp_arms model name -> its Arms node ("arms", "gloves")
var _shake := 0.0
var _sprint := 0.0         # 0 = gun up, 1 = sprint pose
var _casings: Node3D

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var view_model: Node3D = $Head/Camera3D/ViewModel
@onready var weapon_sway: Node3D = $Head/Camera3D/ViewModel/WeaponSway
@onready var weapon_reload: Node3D = $Head/Camera3D/ViewModel/WeaponSway/WeaponReload
@onready var weapon_recoil: Node3D = $Head/Camera3D/ViewModel/WeaponSway/WeaponReload/WeaponRecoil
@onready var gun_holder: Node3D = %Gun
@onready var arms: Node3D = $Head/Camera3D/ViewModel/Arms
@onready var muzzle: Node3D = $Head/Camera3D/ViewModel/WeaponSway/WeaponReload/WeaponRecoil/Muzzle
@onready var muzzle_flash: Node3D = %MuzzleFlash
@onready var shoot_sound: AudioStreamPlayer = $ShootSound
@onready var reload_sound: AudioStreamPlayer = $ReloadSound
@onready var cycle_sound: AudioStreamPlayer = $CycleSound
@onready var footstep_sound: AudioStreamPlayer = $FootstepSound


func _ready() -> void:
	muzzle_flash.visible = false
	# Weapons can use other first-person arms ("arms" in weapon_stats.gd, e.g.
	# the Pistol's gloves); each set is built once, only one is shown.
	_arms_sets["arms"] = arms
	for w: Dictionary in Weapons.LIST:
		var set_name: String = w.get("arms", "arms")
		if not _arms_sets.has(set_name):
			var a: Node3D = FpArms.new()
			a.name = "Arms_" + set_name
			a.model_name = set_name
			a.model_scale = w.get("arms_scale", 1.0)
			a.shoulders = w.get("arms_shoulders", a.shoulders)
			a.visible = false
			view_model.add_child(a)
			_arms_sets[set_name] = a
	for i in Weapons.LIST.size():
		var w: Dictionary = Weapons.LIST[i]
		# AK Rifle and Pistol; the rest are bought in the shop (economy.gd).
		_owned.append(w.name in Economy.START_WEAPONS or Settings.debug_unlock_all)
		_upgrades.append({"damage": 0, "mag": 0, "reload": 0})
		_mag.append(mag_size(i))
		_reserve.append(w.reserve)
		_add_view_model(w)
	_casings = Casings.new()
	_casings.name = "Casings"
	add_child(_casings)
	_show_weapon(start_weapon_index())
	_build_throw_preview()
	# On touch devices the mouse is never captured; touch controls are used instead.
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# Builds the first-person model for one weapon (weapon_view.gd: the model
# for the graphics quality, its parts and hand targets), barrel pointing
# forward (-Z), and remembers where its muzzle is. Also adds the red dot sight
# if the weapon has one, and works out where the gun must move so its sights
# line up with the centre of the screen.
func _add_view_model(w: Dictionary) -> void:
	var view: Node3D = WeaponView.new()
	gun_holder.add_child(view)
	view.transform = Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3.ZERO)
	view.setup(w, Settings.effective_quality())
	view.visible = false
	view.eject.connect(_on_eject.bind(view))
	_views.append(view)
	_muzzles.append(view.transform * view.tip)

	var sight := Vector3(0.0, w.sight_height, 0.0)
	if w.sight_height <= 0.0:
		var aabb: AABB = view.aabb
		sight = WeaponModel.top_at(view.model, aabb, aabb.position.x + aabb.size.x * w.sight_at)
		sight.z = 0.0
	var drop: float = w.get("ads_drop", ADS_SIGHT_DROP)
	if w.sight == "red_dot":
		sight = WeaponModel.add_red_dot(view, sight, 1.0)
		drop = 0.0  # look straight through the window
	# The Gun node sits at WeaponSway's origin, so this is the sight in
	# WeaponSway space; move WeaponSway so it ends up on the camera's axis.
	var p := view.transform * sight
	_ads_positions.append(Vector3(-p.x, -p.y - drop, -w.ads_distance) + w.ads_offset)


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
	elif event.is_action_pressed("grenade"):
		start_grenade()
	elif event.is_action_released("grenade"):
		throw_grenade()
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
	var want_aim := _aim_wanted and can_aim() and not is_dead \
			and not _switching and _reload_timer <= 0.0
	if want_aim != _aiming:
		_set_aiming(want_aim)
	_update_feel(delta)
	_throw_cooldown -= delta
	if _grenade_held:
		_update_throw_preview()


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	_invulnerable = maxf(_invulnerable - delta, 0.0)

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
	if _aiming:
		speed = WALK_SPEED * ADS_MOVE_SCALE
	speed *= current_weapon().move_scale  # heavy guns (LMG) slow you down
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
	_update_aim_assist(delta)


## Rotate the view by a mouse/finger movement in pixels.
## Turns the body left/right and tilts the head up/down. Slower while scoped.
## Scaled by the look sensitivity from the settings screen. With aim assist
## on, finger looking slows down while the crosshair is on an enemy.
func look(relative: Vector2, from_touch := false) -> void:
	relative *= camera.fov / BASE_FOV * Settings.look_sensitivity
	if from_touch and _assist_over != null and aim_assist_active():
		relative *= ASSIST_SLOW
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


## True while looking through the sniper scope (black overlay shown).
func is_scoped() -> bool:
	return _scoped


## True while aiming with any weapon (down the sights or through the scope).
func is_aiming() -> bool:
	return _aiming


## Every weapon can aim: sights for most, the scope for the sniper.
func can_aim() -> bool:
	var w := current_weapon()
	return w.zoom_fov > 0.0 if w.sight == "scope" else w.ads_fov > 0.0


## Touch AIM button: aim in / out.
func toggle_aim() -> void:
	_aim_wanted = not _aiming


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
	fired.emit()

	# Flash, sound, kick and shake.
	muzzle_flash.visible = true
	muzzle_flash.rotation.z = randf() * TAU
	# x1.4 at VIEW_SCALE 0.5: the flash is inside the scaled-down ViewModel,
	# closer to the eye.
	muzzle_flash.scale = Vector3.ONE * w.flash_size * 0.7 / view_scale_of(w) * randf_range(0.8, 1.2)
	_flash_timer = FLASH_TIME
	shoot_sound.pitch_scale = w.shot_pitch * randf_range(0.95, 1.05)
	shoot_sound.play()
	_recoil = minf(_recoil + w.recoil, maxf(1.5, w.recoil))
	if w.get("recoil_spring", false):
		_recoil = w.recoil  # each shot snaps to the full kick, the spring brings it back
		_recoil_vel = 0.0
		_recoil_side = randf_range(-1.0, 1.0)
	_shake = maxf(_shake, w.shake)
	_view().fire(_mag[weapon_index] == 0)
	if w.cycle_sound:
		_play_cycle(w)

	# Bullets go out of the camera, i.e. through the crosshair, with some
	# random spread. Pellets that hit the same enemy are added together so it
	# takes one hit (one blood splash, one stagger) per shot.
	var spread: float = w.spread + _spread
	if _scoped:
		spread = w.scoped_spread + _spread
	elif _aiming:
		spread *= w.ads_spread
	_spread = minf(_spread + w.spread_per_shot, w.max_spread)
	Haptics.shot()
	# Pellets through the head hitbox do double damage.
	var enemy_hits := {}
	var sparks := 0
	for i in w.pellets:
		var dir := _spread_direction(spread)
		var hit := _fire_ray(dir, w.range)
		if hit.is_empty():
			continue
		var target: Object = hit.collider
		if target.has_method("take_damage"):
			var head: bool = target.has_method("is_head_hit") and target.is_head_hit(camera.global_position, dir)
			var dmg: int = roll_damage(weapon_index) * (HEADSHOT_MULTIPLIER if head else 1)
			if insta_kill and "hp" in target and not target.get("kind") == "boss":
				dmg = maxi(dmg, target.hp)  # Insta-Kill power-up (not the Boss)
			if enemy_hits.has(target):
				enemy_hits[target].damage += dmg
				enemy_hits[target].headshot = enemy_hits[target].headshot or head
			else:
				enemy_hits[target] = {"damage": dmg, "point": hit.position, "normal": hit.normal, "headshot": head}
		else:
			_spawn_impact(hit.position, hit.normal, sparks < MAX_SPARKS_PER_SHOT)
			sparks += 1
	for target: Object in enemy_hits:
		var h: Dictionary = enemy_hits[target]
		target.take_damage(h.damage, h.point, h.normal, h.headshot)  # enemy: blood + hit reaction
		if target.has_method("is_head_hit"):  # enemies (not barrels)
			var killed: bool = target.hp <= 0
			enemy_hit.emit(target, h.damage, h.point, h.headshot, killed)

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


# Pump / bolt after a shot: the sound, the part moving (weapon_view.gd) and
# a small pull-back of the gun.
func _play_cycle(w: Dictionary) -> void:
	_kill_weapon_tween()
	_view().cycle(w.cycle_delay)
	_weapon_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_weapon_tween.tween_interval(w.cycle_delay)
	_weapon_tween.tween_callback(func() -> void:
		cycle_sound.stream = w.cycle_sound
		cycle_sound.play())
	_weapon_tween.tween_property(weapon_reload, "position", Vector3(-0.01, -0.02, 0.06), 0.15)
	_weapon_tween.parallel().tween_property(weapon_reload, "rotation", Vector3(deg_to_rad(4), 0.0, deg_to_rad(10)), 0.15)
	_weapon_tween.tween_property(weapon_reload, "position", Vector3.ZERO, 0.22)
	_weapon_tween.parallel().tween_property(weapon_reload, "rotation", Vector3.ZERO, 0.22)


# The current weapon's first-person model (weapon_view.gd).
func _view() -> Node3D:
	return _views[weapon_index]


# Spent casings: thrown right, up and a little back from the ejection port.
func _on_eject(count: int, view: Node3D) -> void:
	var w: Dictionary = view.stats
	if w.casing == "" or not view.visible or not is_inside_tree():
		return
	var b := camera.global_basis
	var at: Vector3 = view.port.global_position
	for i in count:
		var v := b.x * CASING_SPEED.x + b.y * CASING_SPEED.y + b.z * CASING_SPEED.z
		if w.view_model == "lmg":
			v = b.x * 0.5 - b.y * 0.8  # the LMG drops them out underneath
		v += Vector3(randf_range(-0.3, 0.3), randf_range(-0.2, 0.3), randf_range(-0.3, 0.3)) + velocity
		if count > 1:  # revolver: the whole cylinder falls out
			v = b.y * -0.6 + b.x * randf_range(-0.4, 0.2) + velocity
			at = view.port.global_position + b * Vector3(randf_range(-0.01, 0.01), randf_range(-0.01, 0.01), 0.0)
		_casings.spawn(w.casing, at, view.global_basis.orthonormalized() * Basis(Vector3.FORWARD, PI / 2.0), v, view_scale_of(w))


## ViewModel's scale for weapon `w` (see the top of this file).
func view_scale_of(w: Dictionary) -> float:
	return w.get("view_scale", VIEW_SCALE)


# --- Reloading --------------------------------------------------------------

func start_reload() -> void:
	if is_dead or _switching or _reload_timer > 0.0:
		return
	var w := current_weapon()
	if _mag[weapon_index] >= mag_size(weapon_index) or _reserve[weapon_index] == 0:
		return
	if _fire_cooldown > 0.0:
		_reload_queued = true  # still pumping / cycling the bolt: reload right after
		return
	_aim_wanted = false
	_reload_timer = reload_time(weapon_index)
	_emit_ammo()

	_sound_tween = create_tween()
	var empty := _mag[weapon_index] == 0
	for entry: Array in w.reload_sounds:
		if entry.size() > 2 and entry[2] == "empty" and not empty:
			continue  # e.g. the slide release, only after the last round
		# Faster reloads (upgrades) play the sounds faster too.
		_sound_tween.parallel().tween_callback(_play_reload_sound.bind(entry[1])).set_delay(entry[0] * _reload_timer / w.reload_time)

	# Reload animation (weapon_view.gd): parts, hands and the gun's tilt.
	_kill_weapon_tween()
	_view().reload(_reload_timer, weapon_reload)


func _finish_reload() -> void:
	var w := current_weapon()
	var need: int = mag_size(weapon_index) - _mag[weapon_index]
	if _reserve[weapon_index] >= 0:
		need = mini(need, _reserve[weapon_index])
		_reserve[weapon_index] -= need
	_mag[weapon_index] += need
	_emit_ammo()


func _cancel_reload() -> void:
	if _reload_timer > 0.0:
		_view().reset()
	_reload_timer = 0.0
	_reload_queued = false
	if _sound_tween:
		_sound_tween.kill()


# --- Switching --------------------------------------------------------------

## Switch to the weapon in `index` (0-based slot) if the player has it.
## A switch already under way (e.g. to a weapon just bought in the shop, which
## pauses the game mid-switch) is replaced by the new one.
func switch_to(index: int) -> void:
	var current := _switch_target if _switching else weapon_index
	if index == current or index < 0 or index >= _owned.size() \
			or not _owned[index] or is_dead:
		return
	_switch_target = index
	_cancel_reload()
	_aim_wanted = false
	_set_aiming(false)
	_switching = true
	_emit_ammo()
	# Lower the current gun (dipping and rolling out of view), swap models,
	# raise the new one with a little overshoot.
	# Weapons with a "holster" pose (the Pistol) go down / come up through it
	# on a smooth curve instead.
	_kill_weapon_tween()
	_weapon_tween = create_tween()
	var down_pos := Vector3(-0.04, -0.4, 0.12)
	var down_rot := Vector3(deg_to_rad(-45), deg_to_rad(10), deg_to_rad(25))
	var down_trans := Tween.TRANS_CUBIC
	var holster: Array = current_weapon().get("holster", [])
	if not holster.is_empty():
		down_pos = holster[0]
		down_rot = holster[1] * (PI / 180.0)
		down_trans = Tween.TRANS_SINE
	_weapon_tween.tween_property(weapon_reload, "position", down_pos, SWITCH_DOWN_TIME).set_trans(down_trans).set_ease(Tween.EASE_IN)
	_weapon_tween.parallel().tween_property(weapon_reload, "rotation", down_rot, SWITCH_DOWN_TIME).set_trans(down_trans).set_ease(Tween.EASE_IN)
	_weapon_tween.tween_callback(_show_weapon.bind(index))
	var up_trans := Tween.TRANS_BACK
	var up_time := SWITCH_UP_TIME
	var draw: Array = Weapons.LIST[index].get("holster", [])
	if not draw.is_empty():
		# Start the new gun from its own holster pose.
		_weapon_tween.tween_callback(func() -> void:
			weapon_reload.position = draw[0]
			weapon_reload.rotation = draw[1] * (PI / 180.0))
		up_trans = Tween.TRANS_QUART
		up_time = SWITCH_UP_TIME * 1.25
	_weapon_tween.tween_property(weapon_reload, "position", Vector3.ZERO, up_time).set_trans(up_trans).set_ease(Tween.EASE_OUT)
	_weapon_tween.parallel().tween_property(weapon_reload, "rotation", Vector3.ZERO, up_time).set_trans(up_trans).set_ease(Tween.EASE_OUT)
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
	if weapon_index != index:
		_views[weapon_index].reset()
	weapon_index = index
	var w := current_weapon()
	for i in _views.size():
		_views[i].visible = i == index
	muzzle.position = _muzzles[index]
	shoot_sound.stream = w.shot_sound
	shoot_sound.volume_db = w.shot_volume_db
	_spread = 0.0
	var set_name: String = w.get("arms", "arms")
	for k: String in _arms_sets:
		_arms_sets[k].visible = k == set_name
	arms = _arms_sets[set_name]
	arms.set_targets(_view().right_target, _view().left_target)
	weapon_changed.emit(w.name)
	_emit_ammo()


func _kill_weapon_tween() -> void:
	if _weapon_tween:
		_weapon_tween.kill()
	weapon_reload.position = Vector3.ZERO
	weapon_reload.rotation = Vector3.ZERO


# --- Aiming -----------------------------------------------------------------

## Aim in or out. The sniper looks through its scope (black overlay, gun
## hidden, big zoom); the other guns move to the centre of the screen so you
## look along their sights, with a smaller zoom and tighter spread.
func _set_aiming(on: bool) -> void:
	if on == _aiming:
		return
	_aiming = on
	_aim_time = 0.0
	var w := current_weapon()
	var scope: bool = w.sight == "scope"
	var fov := BASE_FOV
	if on:
		fov = w.zoom_fov if scope else w.ads_fov
	if _fov_tween:
		_fov_tween.kill()
	_fov_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_fov_tween.tween_property(camera, "fov", fov, 0.12 if scope else ADS_TIME)
	if _ads_tween:
		_ads_tween.kill()
	_ads_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_ads_tween.tween_property(self, "_ads", 1.0 if on and not scope else 0.0, ADS_TIME)
	var scoped := on and scope
	if scoped != _scoped:
		_scoped = scoped
		# The gun and arms would block the scope view.
		weapon_sway.visible = not scoped
		view_model.visible = not scoped
		scope_changed.emit(scoped)
	aim_changed.emit(on, w.sight)


# --- Aim assist (touch only) ------------------------------------------------

## On with the touch controls only: not with a captured mouse (e.g. a
## touchscreen laptop played with the mouse).
func aim_assist_active() -> bool:
	return touch_active and Settings.aim_assist and not is_dead \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED


## The enemy under the crosshair (aim assist), or null.
func assist_enemy_under_crosshair() -> Node3D:
	return _assist_over


## The enemy aiming in is pulling towards (aim assist), or null.
func assist_target() -> Node3D:
	return _assist_target


# Finds the enemy under the crosshair (look speed slows down on it) and,
# while aiming, the visible enemy closest to the crosshair within ASSIST_CONE,
# and turns the view a little towards its chest: more just after aiming in,
# then gently. At most two rays a frame (visibility of those two enemies).
func _update_aim_assist(delta: float) -> void:
	_aim_time += delta
	_assist_over = null
	_assist_target = null
	if not aim_assist_active():
		return
	var from := camera.global_position
	var forward := -head.global_basis.z
	var over: Node3D = null
	var over_dist := INF
	var best: Node3D = null
	var best_angle := deg_to_rad(ASSIST_CONE)
	for e: Node in get_tree().get_nodes_in_group("enemies"):
		if not e is CharacterBody3D or not "stats" in e:
			continue
		var enemy := e as Node3D
		var to := _assist_point(enemy) - from
		var dist := to.length()
		if dist > ASSIST_RANGE or dist < 0.3:
			continue
		if dist < over_dist and _crosshair_on(from, forward, enemy):
			over = enemy
			over_dist = dist
		if _aiming:
			var angle := forward.angle_to(to / dist)
			if angle < best_angle:
				best_angle = angle
				best = enemy
	if over != null and _can_see(from, _assist_point(over)):
		_assist_over = over
	if best != null and _can_see(from, _assist_point(best)):
		_assist_target = best
		var rate := ASSIST_SNAP_RATE if _aim_time < ASSIST_SNAP_TIME else ASSIST_TRACK_RATE
		_turn_towards(_assist_point(best), 1.0 - exp(-rate * delta))


func _assist_point(enemy: Node3D) -> Vector3:
	return enemy.global_position + Vector3.UP * enemy.stats.height * 0.6


# True if the line of sight passes through the enemy's body (its upright
# capsule, a little wider).
func _crosshair_on(from: Vector3, forward: Vector3, enemy: Node3D) -> bool:
	var flat := Vector2(forward.x, forward.z)
	if flat.length_squared() < 1e-4:
		return false  # looking straight up or down
	var base := enemy.global_position
	var t := Vector2(base.x - from.x, base.z - from.z).dot(flat) / flat.length_squared()
	if t <= 0.0:
		return false
	var p := from + forward * t
	var miss := Vector2(p.x - base.x, p.z - base.z).length()
	var y := p.y - base.y
	return miss < enemy.stats.radius * ASSIST_OVER_MARGIN and y > -0.1 and y < enemy.stats.height + 0.15


# Nothing but enemies (that one, or another in front of it) between `from` and `to`.
func _can_see(from: Vector3, to: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(from, to, ASSIST_MASK, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.is_empty() or hit.collider is CharacterBody3D


# Turns the body (yaw) and head (pitch) a share `amount` (0..1) of the way
# to look at `target`.
func _turn_towards(target: Vector3, amount: float) -> void:
	var local := head.global_basis.inverse() * (target - camera.global_position)
	var yaw := atan2(local.x, -local.z)
	var pitch := atan2(local.y, Vector2(local.x, local.z).length())
	rotate_y(-yaw * amount)
	head.rotation.x = clampf(head.rotation.x + pitch * amount, deg_to_rad(-89.0), deg_to_rad(89.0))


# --- Pickups ----------------------------------------------------------------

## Called by weapon pickups. Returns true if the pickup was used.
func give_weapon(index: int) -> bool:
	if is_dead:
		return false
	var w: Dictionary = Weapons.LIST[index]
	if _owned[index]:
		return _add_reserve(index)
	_owned[index] = true
	_mag[index] = mag_size(index)
	_reserve[index] = w.reserve
	message.emit("Picked up %s" % w.name)
	switch_to(index)
	return true


## The weapon in hand when a match starts (economy.gd START_PRIMARY).
static func start_weapon_index() -> int:
	for i in Weapons.LIST.size():
		if Weapons.LIST[i].name == Economy.START_PRIMARY:
			return i
	return 0


## Training Arena: every weapon, magazines full.
func own_all_weapons() -> void:
	for i in _owned.size():
		if not _owned[i]:
			_owned[i] = true
			_mag[i] = mag_size(i)
			_reserve[i] = Weapons.LIST[i].reserve
	_emit_ammo()


## Training Arena: unlimited spare ammo on (every reserve -1 = unlimited) or
## off (every reserve back to full).
func set_infinite_ammo(on: bool) -> void:
	infinite_ammo = on
	for i in _owned.size():
		_reserve[i] = -1 if on else Weapons.LIST[i].max_reserve
	_emit_ammo()


## Called by ammo boxes: spare ammo for every weapon the player owns, and
## one grenade. Returns false (and the box stays) if everything is already full.
func give_ammo() -> bool:
	if is_dead:
		return false
	var added := false
	for i in _owned.size():
		if _owned[i] and _add_reserve(i):
			added = true
	if grenades < MAX_GRENADES:
		grenades += 1
		grenades_changed.emit(grenades)
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
	grenades_changed.emit(grenades)
	armor_changed.emit(armor)


## Max Ammo / the shop: every owned weapon's magazine and spare ammo to full.
## Returns false if everything was already full.
func refill_ammo() -> bool:
	var added := false
	for i in _owned.size():
		if not _owned[i]:
			continue
		var w: Dictionary = Weapons.LIST[i]
		var full_reserve: int = w.max_reserve if w.max_reserve >= 0 else -1
		if _mag[i] < mag_size(i) or _reserve[i] != full_reserve:
			added = true
		if i != weapon_index or _reload_timer <= 0.0:
			_mag[i] = mag_size(i)
		_reserve[i] = full_reserve
	_emit_ammo()
	return added


## Adds grenades up to MAX_GRENADES. Returns how many were added.
func add_grenades(count: int) -> int:
	var added := mini(count, MAX_GRENADES - grenades)
	if added > 0:
		grenades += added
		grenades_changed.emit(grenades)
	return added


# --- Upgrades: the shop's (this match, economy.gd) on top of the Armory's ----
# --- (permanent, progression_config.gd) ------------------------------------

## Weapon `index`'s `stat` ("damage", "mag" or "reload") with its permanent
## upgrades and `match_level` shop upgrades (-1 = the ones bought this match).
## Damage can come out fractional (see roll_damage()).
func stat_value(index: int, stat: String, match_level := -1) -> float:
	var w: Dictionary = Weapons.LIST[index]
	if match_level < 0:
		match_level = _upgrades[index][stat]
	var perm: int = Progress.upgrade_level(w.name, stat)
	match stat:
		"damage":
			return Economy.upgraded_damage(w.damage, match_level) * (1.0 + Progression.PERM_DAMAGE * perm)
		"mag":
			return ceilf(Economy.upgraded_mag(w.mag_size, match_level) * (1.0 + Progression.PERM_MAG * perm) - 0.001)
		_:
			return Economy.upgraded_reload(w.reload_time, match_level) * (1.0 - Progression.PERM_RELOAD * perm)


## Damage per bullet of weapon `index` with its upgrades (rounded).
func weapon_damage(index: int) -> int:
	return roundi(stat_value(index, "damage"))


## The damage of one bullet: a fractional damage like 2.4 does 3 on 40% of
## the bullets and 2 on the rest.
func roll_damage(index: int) -> int:
	var d := stat_value(index, "damage")
	return floori(d) + (1 if randf() < d - floorf(d) else 0)


func mag_size(index: int) -> int:
	return int(stat_value(index, "mag"))


func reload_time(index: int) -> float:
	return stat_value(index, "reload")


## Level (0..UPGRADE_LEVELS) of upgrade `stat` ("damage", "mag" or "reload").
func upgrade_level(index: int, stat: String) -> int:
	return _upgrades[index][stat]


## One more level of `stat` for weapon `index`. Returns false if maxed.
func upgrade(index: int, stat: String) -> bool:
	if _upgrades[index][stat] >= Economy.UPGRADE_LEVELS:
		return false
	_upgrades[index][stat] += 1
	_emit_ammo()
	return true


func _emit_ammo() -> void:
	ammo_changed.emit(_mag[weapon_index], _reserve[weapon_index], _reload_timer > 0.0)


## Shows every gun model for a moment so their shaders compile while the
## level loads (see main.gd), then goes back to the current one.
func show_all_view_models(on: bool) -> void:
	for i in _views.size():
		_views[i].visible = on or i == weapon_index
	var current: Node3D = arms
	for a: Node3D in _arms_sets.values():
		a.visible = on or a == current
	_casings.warm(on, camera.global_position - camera.global_basis.z * 0.5)


# --- Health -----------------------------------------------------------------

func take_damage(amount: int) -> void:
	if is_dead:
		return
	if _invulnerable > 0.0:
		return
	if invincible:
		_shake = maxf(_shake, SHAKE_ON_HIT * 0.5)
		hit_taken.emit()  # red flash only
		return
	_shake = maxf(_shake, SHAKE_ON_HIT)
	Haptics.damage()
	if GOD_MODE:
		hit_taken.emit()  # red flash only
		return
	if armor > 0:
		# Armor takes its share of the hit while it lasts.
		var absorbed := mini(roundi(amount * Economy.ARMOR_ABSORB), armor)
		armor -= absorbed
		amount -= absorbed
		armor_changed.emit(armor)
		if amount <= 0:
			hit_taken.emit()  # still a red flash
			return
	health = maxi(health - amount, 0)
	health_changed.emit(health)
	if health == 0:
		is_dead = true
		_set_aiming(false)
		cancel_grenade()
		died.emit()


## Back to life with full health (the revive after watching an ad), and
## no damage for `invulnerable` seconds.
func revive(invulnerable := 0.0) -> void:
	is_dead = false
	health = MAX_HEALTH
	_invulnerable = invulnerable
	_aim_wanted = false
	touch_move = Vector2.ZERO
	touch_shoot = false
	health_changed.emit(health)
	emit_status()


func is_invulnerable() -> bool:
	return _invulnerable > 0.0


## Adds armor, up to economy.gd MAX_ARMOR. Returns false if it was already full.
func add_armor(amount: int) -> bool:
	if is_dead or armor >= Economy.MAX_ARMOR:
		return false
	armor = mini(armor + amount, Economy.MAX_ARMOR)
	armor_changed.emit(armor)
	return true


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


## Extra camera shake from outside (e.g. a nearby explosion), 0..~1.2.
func add_shake(amount: float) -> void:
	_shake = maxf(_shake, amount)


# --- Grenades ---------------------------------------------------------------

## G pressed / GRENADE button touched: pull the pin and show the throw arc.
func start_grenade() -> void:
	if is_dead or _grenade_held or (grenades <= 0 and not infinite_grenades) or _throw_cooldown > 0.0:
		return
	_grenade_held = true
	_play_reload_sound(PIN_SOUND)
	_update_throw_preview()
	_preview.visible = true


## G released / finger lifted off GRENADE: throw it along the previewed arc.
func throw_grenade() -> void:
	if not _grenade_held:
		return
	_grenade_held = false
	_hide_throw_preview()
	if is_dead or (grenades <= 0 and not infinite_grenades):
		return
	if not infinite_grenades:
		grenades -= 1
	_throw_cooldown = THROW_COOLDOWN
	grenades_changed.emit(grenades)
	var g: RigidBody3D = Grenade.new()
	g.thrower = self
	get_tree().current_scene.add_child(g)
	g.global_position = _throw_origin()
	g.linear_velocity = _throw_velocity()
	g.angular_velocity = Vector3(randf_range(-8, 8), randf_range(-8, 8), randf_range(-8, 8))
	# A quick dip of the gun while the other hand throws.
	if not _switching and _reload_timer <= 0.0 and _fire_cooldown <= 0.0:
		_kill_weapon_tween()
		_weapon_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		_weapon_tween.tween_property(weapon_reload, "position", Vector3(0.0, -0.12, 0.06), 0.1)
		_weapon_tween.parallel().tween_property(weapon_reload, "rotation", Vector3(deg_to_rad(-12), 0.0, deg_to_rad(-8)), 0.1)
		_weapon_tween.tween_property(weapon_reload, "position", Vector3.ZERO, 0.25)
		_weapon_tween.parallel().tween_property(weapon_reload, "rotation", Vector3.ZERO, 0.25)


## Lets go of a held grenade without throwing it (pause, death).
func cancel_grenade() -> void:
	_grenade_held = false
	_hide_throw_preview()


func is_holding_grenade() -> bool:
	return _grenade_held


# Where the grenade leaves the hand: a little right of and below the eyes,
# pulled back to the camera if that spot is inside a wall.
func _throw_origin() -> Vector3:
	var b := camera.global_basis
	var from := camera.global_position
	var to := from + b * Vector3(0.24, -0.2, -0.3)
	var q := PhysicsRayQueryParameters3D.create(from, to, SHOT_MASK | 2, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return from if not hit.is_empty() else to


func _throw_velocity() -> Vector3:
	var b := camera.global_basis
	var dir := (-b.z).rotated(b.x, deg_to_rad(THROW_UP_ANGLE)).normalized()
	return dir * THROW_SPEED + velocity


# The arc preview: a row of small glowing dots and a ring where it lands.
func _build_throw_preview() -> void:
	var dot_mat := StandardMaterial3D.new()
	dot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dot_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dot_mat.albedo_color = Color(1.0, 0.85, 0.35, 0.85)
	var dot := SphereMesh.new()
	dot.radius = 0.035
	dot.height = 0.07
	dot.radial_segments = 6
	dot.rings = 3
	dot.material = dot_mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = dot
	mm.instance_count = PREVIEW_DOTS
	_preview = MultiMeshInstance3D.new()
	_preview.multimesh = mm
	_preview.top_level = true
	_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_preview.visible = false
	add_child(_preview)

	var ring := TorusMesh.new()
	ring.inner_radius = 0.38
	ring.outer_radius = 0.46
	ring.rings = 24
	ring.ring_segments = 4
	ring.material = dot_mat
	_preview_marker = MeshInstance3D.new()
	_preview_marker.mesh = ring
	_preview_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_preview_marker.top_level = true
	_preview_marker.visible = false
	add_child(_preview_marker)


func _hide_throw_preview() -> void:
	if _preview:
		_preview.visible = false
		_preview_marker.visible = false


## Simulates the throw (same start, speed and gravity as the real grenade)
## up to its first hit. Returns {"points": [...], "hit": Dictionary}.
func throw_arc() -> Dictionary:
	var space := get_world_3d().direct_space_state
	var pos := _throw_origin()
	var vel := _throw_velocity()
	var gravity := get_gravity()
	var points: Array[Vector3] = [pos]
	var hit := {}
	var t := 0.0
	while t < PREVIEW_MAX_TIME:
		var next := pos + vel * PREVIEW_STEP
		vel += gravity * PREVIEW_STEP
		var q := PhysicsRayQueryParameters3D.create(pos, next, SHOT_MASK | 2, [get_rid()])
		hit = space.intersect_ray(q)
		if not hit.is_empty():
			points.append(hit.position)
			break
		pos = next
		points.append(pos)
		t += PREVIEW_STEP
	return {"points": points, "hit": hit}


func _update_throw_preview() -> void:
	var arc := throw_arc()
	var points: Array[Vector3] = arc.points
	var mm := _preview.multimesh
	# Spread the dots evenly over the arc (skip the point in the hand).
	var count := points.size()
	for i in PREVIEW_DOTS:
		var k := clampi(int(lerpf(1.0, count - 1, float(i) / (PREVIEW_DOTS - 1))), 0, count - 1)
		mm.set_instance_transform(i, Transform3D(Basis(), points[k]))
	var hit: Dictionary = arc.hit
	_preview_marker.visible = not hit.is_empty()
	if not hit.is_empty():
		# The ring lies flat in its XZ plane: turn its Y axis to the surface normal.
		var n: Vector3 = hit.normal
		var up := Vector3.FORWARD if absf(n.y) > 0.99 else Vector3.UP
		var x := up.cross(n).normalized()
		_preview_marker.global_transform = Transform3D(Basis(x, n, x.cross(n)), hit.position + n * 0.03)

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
	camera.position = bob * lerpf(1.0, 0.4, _ads)

	# Weapon sway: lags behind look movement and bobs a little while walking.
	# Aiming down the sights moves the gun to the centre and steadies it;
	# sprinting swings it down and across.
	_sway = _sway.lerp(Vector2.ZERO, clampf(delta * 10.0, 0.0, 1.0))
	var sprinting := Input.is_action_pressed("sprint") and speed > WALK_SPEED + 0.5 and is_on_floor() \
			and not _aiming and _reload_timer <= 0.0 and not _switching and _fire_cooldown < -0.25
	_sprint = move_toward(_sprint, 1.0 if sprinting else 0.0, delta * SPRINT_BLEND)
	var sprint := smoothstep(0.0, 1.0, _sprint)
	var steady := lerpf(1.0, ADS_SWAY, _ads)
	var w := current_weapon()
	var hip: Vector3 = w.hip
	var bob_amount := _bob_blend * steady * (1.0 + sprint)
	weapon_sway.position = hip.lerp(_ads_positions[weapon_index], _ads) \
			+ Vector3(-_sway.x * SWAY_AMOUNT, _sway.y * SWAY_AMOUNT, 0.0) * steady \
			+ Vector3(cos(_bob_time) * GUN_BOB.x, -absf(sin(_bob_time)) * GUN_BOB.y, 0.0) * bob_amount \
			+ SPRINT_POS * sprint
	var turn := (HIP_TURN * (1.0 - _ads) + SPRINT_TURN * sprint) * (PI / 180.0)
	weapon_sway.rotation = Vector3(_sway.y * 0.002, _sway.x * 0.002, -_sway.x * 0.001) * steady + turn
	# Breathing while standing (less when aiming) and a roll with each step.
	var breath: float = w.get("breath", 0.0)
	if breath > 0.0:
		_breath_time += delta * BREATH_RATE
		var t := _breath_time
		var idle := breath * (1.0 - _bob_blend * 0.7) * lerpf(1.0, 0.3, _ads)
		weapon_sway.position += Vector3(sin(t * 0.5) * BREATH_MOVE.x, sin(t) * BREATH_MOVE.y, 0.0) * idle
		weapon_sway.rotation += Vector3(sin(t + 0.6) * BREATH_TURN.x, sin(t * 0.5 + 1.3) * BREATH_TURN.y,
				sin(t * 0.5) * BREATH_TURN.z) * (idle * PI / 180.0)
		weapon_sway.rotation.z += cos(_bob_time) * deg_to_rad(WALK_ROLL) * breath * bob_amount * lerpf(1.0, 0.3, _ads)

	# Recoil: the gun kicks back and up about the grip, then settles.
	if w.get("recoil_spring", false):
		# Damped spring: snaps back in ~0.12 s with a small overshoot.
		var acc := -SPRING_RATE * SPRING_RATE * _recoil - 2.0 * SPRING_DAMPING * SPRING_RATE * _recoil_vel
		var dt := minf(delta, 1.0 / 30.0)
		_recoil_vel += acc * dt
		_recoil += _recoil_vel * dt
	else:
		_recoil = lerpf(_recoil, 0.0, clampf(delta * 12.0, 0.0, 1.0))
	var back: float = w.get("recoil_back", RECOIL_BACK)
	var pitch: float = w.get("recoil_pitch", RECOIL_PITCH)
	weapon_recoil.position = Vector3(0.0, absf(_recoil) * back * 0.15, _recoil * back * lerpf(1.0, 0.6, _ads)) \
			if w.get("recoil_spring", false) else Vector3(0.0, 0.0, _recoil * back * lerpf(1.0, 0.6, _ads))
	weapon_recoil.rotation = Vector3(_recoil * pitch * lerpf(1.0, 0.5, _ads),
			_recoil * _recoil_side * pitch * 0.12, -_recoil * _recoil_side * pitch * 0.2) \
			if w.get("recoil_spring", false) else Vector3(_recoil * pitch * lerpf(1.0, 0.5, _ads), 0.0, 0.0)

	# The view model's own scale and FOV (see the top of this file).
	var vs := view_scale_of(w)
	var k := 1.0
	if w.has("view_fov"):
		var vfov: float = lerpf(w.view_fov, w.get("ads_view_fov", w.view_fov), _ads)
		k = tan(deg_to_rad(camera.fov) * 0.5) / tan(deg_to_rad(vfov) * 0.5)
	view_model.scale = Vector3(vs * k, vs * k, vs)

	# Camera shake: small random rotations that fade out quickly.
	_shake = move_toward(_shake, 0.0, delta * 2.5)
	var s := _shake * _shake * 0.03
	camera.rotation = Vector3(randf_range(-s, s), randf_range(-s, s), randf_range(-s, s) * 0.5)
