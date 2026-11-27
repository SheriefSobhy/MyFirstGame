extends CharacterBody3D
## Rescue missions: the captured officer (built in code by missions/rescue.gd).
## The Exploder's Mixamo mesh (the Ch35 officer, no glow) with its own
## animation library assets/models/enemies/hostage_anims.res (idle / walk /
## run / death; tools/mixamo_anims.gd -- --only hostage; placeholder clips
## until the real ones are downloaded, see HOSTAGE_SET there).
##
##  CAPTIVE  crouched at his spot until freed (hold USE 3 s)
##  FOLLOW   follows the player on the small enemies' navmesh, aiming for a
##           spot FOLLOW_BEHIND m behind them; stands still within
##           FOLLOW_STOP m; runs when far behind; ducks (procedural crouch,
##           soldiers/crouch_modifier.gd) for COWER_TIME s when a bullet
##           flies close; moved behind the player if stuck far away
##  SAFE     reached the extraction zone
##  DEAD     shot dead (the mission fails)
## He is on physics layer 4: the player's bullets and the soldiers' sight
## rays pass through him; a soldier aiming at him adds that layer
## (tactical_soldier.gd _fire -> take_bullet).

signal died
signal health_changed(hp: int, max_hp: int)

const M := preload("res://missions/missions_config.gd")
const Types := preload("res://enemy_types.gd")
const CrouchModifier := preload("res://soldiers/crouch_modifier.gd")
const MESH := "exploder"
const ANIMS := "res://assets/models/enemies/hostage_anims.res"
const LAYER := 8          # physics layer 4
const MODEL_SCALE := 0.89
const HEIGHT := 1.75
const RADIUS := 0.3
const CROUCH_SPEED := 4.0  # crouch blend per second
const REPATH := 0.4

enum State { CAPTIVE, FOLLOW, SAFE, DEAD }

var state := State.CAPTIVE
var hp := M.HOSTAGE_HP
var max_hp := M.HOSTAGE_HP
var player: Node3D
## Bullets that hit him / made him duck (for tests).
var hits_taken := 0
var cower_count := 0
var warps := 0

var anim: AnimationPlayer
var agent: NavigationAgent3D
var _crouch: SkeletonModifier3D
var _cower := 0.0
var _repath := 0.0
var _progress_from := Vector3.ZERO
var _progress_time := 0.0
var _moving := false
var _yaw := 0.0


func _init(start_yaw_degrees := 0.0) -> void:
	_yaw = deg_to_rad(start_yaw_degrees)


func _ready() -> void:
	add_to_group("hostage")
	collision_layer = LAYER
	collision_mask = 1
	rotation.y = _yaw
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = RADIUS
	capsule.height = HEIGHT
	shape.shape = capsule
	shape.position.y = HEIGHT * 0.5
	add_child(shape)
	var model: Node3D = load("%s%s_%s.glb" % [Types.MODEL_DIR, MESH, Types.LODS[clampi(Settings.effective_quality(), 0, 2)]]).instantiate()
	model.name = "Model"
	model.transform = Transform3D(Basis(Vector3.UP, PI).scaled(Vector3.ONE * MODEL_SCALE), Vector3.ZERO)
	add_child(model)
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var skel: Skeleton3D = model.find_children("*", "Skeleton3D", true, false)[0]
	anim = AnimationPlayer.new()
	anim.name = "AnimationPlayer"
	model.add_child(anim)
	anim.root_node = anim.get_path_to(skel.get_parent())
	var lib: AnimationLibrary = load(ANIMS) if ResourceLoader.exists(ANIMS) else Types.anim_library("exploder")
	anim.add_animation_library("", lib)
	_crouch = CrouchModifier.new()
	_crouch.name = "Crouch"
	_crouch.influence = 1.0
	skel.add_child(_crouch)
	agent = NavigationAgent3D.new()
	agent.navigation_layers = Types.NAV_SMALL
	agent.radius = 0.4
	agent.height = HEIGHT
	agent.path_desired_distance = 0.5
	agent.target_desired_distance = 0.5
	agent.avoidance_enabled = false
	add_child(agent)
	player = get_tree().get_first_node_in_group("player")
	if player is CollisionObject3D:
		add_collision_exception_with(player)  # never blocks the player, never blocked by them
	_play("idle")


## Freed: he follows the player from now on.
func free_hostage() -> void:
	if state != State.CAPTIVE:
		return
	state = State.FOLLOW
	_progress_from = global_position


## Reached the extraction zone.
func make_safe() -> void:
	if state == State.FOLLOW:
		state = State.SAFE


## Soldiers only shoot at him while he follows the player.
func is_targetable() -> bool:
	return state == State.FOLLOW


## A soldier's bullet hit him.
func take_bullet(_from: Vector3) -> void:
	if state != State.FOLLOW:
		return
	hits_taken += 1
	hp = maxi(hp - M.HOSTAGE_DAMAGE, 0)
	health_changed.emit(hp, max_hp)
	_start_cower()
	if hp <= 0:
		_die()


## A bullet flew from `from` to `to`: he ducks if it passed close.
func bullet_passed(from: Vector3, to: Vector3) -> void:
	if state != State.FOLLOW:
		return
	var chest := global_position + Vector3.UP * 1.0
	var closest := Geometry3D.get_closest_point_to_segment(chest, from, to)
	if closest.distance_to(chest) < M.COWER_NEAR:
		_start_cower()


func is_cowering() -> bool:
	return _cower > 0.0


func _start_cower() -> void:
	if _cower <= 0.0:
		cower_count += 1
	_cower = M.COWER_TIME


func _die() -> void:
	state = State.DEAD
	velocity = Vector3.ZERO
	_crouch.influence = 0.0
	anim.play("death", 0.1)
	anim.seek(0.0, true)
	collision_layer = 0
	died.emit()


func _physics_process(delta: float) -> void:
	if state == State.DEAD:
		return
	if not is_on_floor():
		velocity += get_gravity() * delta
	else:
		velocity.y = 0.0
	_cower = maxf(_cower - delta, 0.0)
	var want_crouch := state == State.CAPTIVE or (state == State.FOLLOW and _cower > 0.0)
	_crouch.influence = move_toward(_crouch.influence, 1.0 if want_crouch else 0.0, CROUCH_SPEED * delta)
	_moving = false
	if state == State.FOLLOW and _cower <= 0.0 and player != null:
		_follow(delta)
	if not _moving:
		velocity.x = 0.0
		velocity.z = 0.0
		if state == State.FOLLOW and player != null:
			_face((player.global_position - global_position), delta)
	_crouch.forward = -global_basis.z
	move_and_slide()
	_update_anim()


func _follow(delta: float) -> void:
	var to_player := player.global_position - global_position
	to_player.y = 0.0
	var d := to_player.length()
	if d > M.HOSTAGE_WARP:
		_warp_behind()
		return
	if d < M.FOLLOW_STOP:
		_progress_time = 0.0
		_progress_from = global_position
		return
	# A spot behind the player (the way they came, roughly).
	var back := player.global_basis.z
	back.y = 0.0
	var goal := player.global_position + back.normalized() * M.FOLLOW_BEHIND
	_repath -= delta
	if _repath <= 0.0 or goal.distance_to(agent.target_position) > 1.0:
		agent.target_position = goal
		_repath = REPATH
	var next := agent.get_next_path_position() - global_position
	next.y = 0.0
	if agent.is_navigation_finished() or next.length() < 0.05:
		if Vector2(goal.x - global_position.x, goal.z - global_position.z).length() < 0.6:
			return
		next = to_player  # no path yet: straight at the player
	var speed := M.HOSTAGE_RUN if d > M.HOSTAGE_RUN_DISTANCE else M.HOSTAGE_WALK
	var dir := next.normalized()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	_moving = true
	_face(dir, delta)
	# Not getting anywhere for a while, and well behind: move him behind the player.
	_progress_time += delta
	if _progress_time >= 3.0:
		if global_position.distance_to(_progress_from) < 1.0 and d > 6.0:
			_warp_behind()
		_progress_time = 0.0
		_progress_from = global_position


func _warp_behind() -> void:
	var back := player.global_basis.z
	back.y = 0.0
	var goal := player.global_position + back.normalized() * M.FOLLOW_BEHIND
	var map := get_world_3d().navigation_map
	var p := NavigationServer3D.map_get_closest_point(map, goal)
	if p == Vector3.ZERO and goal.length() > 1.0:
		p = goal
	global_position = Vector3(p.x, player.global_position.y, p.z)
	velocity = Vector3.ZERO
	warps += 1
	_progress_from = global_position
	_progress_time = 0.0


func _face(dir: Vector3, delta: float) -> void:
	dir.y = 0.0
	if dir.length_squared() < 0.001:
		return
	rotation.y = lerp_angle(rotation.y, atan2(-dir.x, -dir.z), clampf(8.0 * delta, 0.0, 1.0))


func _update_anim() -> void:
	var speed := Vector2(velocity.x, velocity.z).length()
	var want := "idle"
	if _moving:
		want = "run" if speed > (M.HOSTAGE_WALK + M.HOSTAGE_RUN) * 0.5 else "walk"
	if anim.current_animation != want:
		_play(want)
	if want != "idle":
		var ground: float = anim.get_animation(want).get_meta("ground_speed", 1.0) * MODEL_SCALE
		anim.speed_scale = clampf(speed / maxf(ground, 0.05), 0.5, 3.0)
	else:
		anim.speed_scale = 1.0


func _play(anim_name: String) -> void:
	if anim.has_animation(anim_name):
		anim.play(anim_name, 0.2)
	elif anim.has_animation("walk") and anim_name == "run":
		anim.play("walk", 0.2)
