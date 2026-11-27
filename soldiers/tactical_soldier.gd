extends "res://enemy.gd"
## Combat mode only: the Mixamo soldier fighting from cover. The zombie
## mode's soldier (enemy.gd) is not changed; this script replaces its
## movement and shooting. Health, headshots (head_sphere / is_head_hit), hit
## reactions (flinch + stagger), death, navigation and the stuck handling
## all come from enemy.gd unchanged.
##
## Cover points come from the mode (soldiers_mode.gd get_cover_points(): spots
## beside the map's houses, containers, racks, cars, crates...; tall cover
## has a peek spot just past the corner, behind low cover the soldier
## crouches (crouch_modifier.gd) and stands up to fire over it). The loop:
##   FIND   pick a free cover point 6-24 m from the player that hides it from
##          the player and whose peek spot can see the player (a few rays)
##   MOVE   run there
##   HIDE   wait 1-2 s (crouched behind low cover), checking the player can't
##          see it; if they can (they flanked it, or came too close) it looks
##          for another cover
##   PEEK   step out to the peek spot (or stand up behind low cover); with a
##          view of the player: a short burst (AIM state), then RETURN behind
##          the cover and HIDE again; after 2-3 peeks it moves to another cover
##   OPEN   no usable cover: fights in the open like the zombie mode's
##          soldier (but with bursts) and looks for cover again soon
## Each bullet's hit chance falls with distance and when the player moves
## (hit_chance). Every shot: muzzle flash, a travelling tracer, a gunshot.

## A bullet was fired at the player (hit = it hit them; armor may still have
## taken it). The mode shows the damage direction from `from`.
signal shot_at_player(from: Vector3, hit: bool)

const Cfg := preload("res://soldiers/soldiers_config.gd")
const RIFLE_SHOT := preload("res://assets/sounds/guns/ak_shot.wav")
const CrouchModifier := preload("res://soldiers/crouch_modifier.gd")
const Mission := preload("res://missions/missions_config.gd")

## Missions: a guard noticed the player (raise_alert()).
signal alerted

enum Tac { FIND, MOVE, HIDE, PEEK, RETURN, OPEN }

## Missions (missions/mission_mode.gd) only; defaults = the Waves soldier.
## Defend: a "pusher" walks to this spot in the zone and holds it (INF = no).
var push_spot := Vector3.INF
## Rescue: false = a guard at guard_post looking along guard_yaw (degrees,
## 0 = -Z) that hasn't noticed the player yet.
var alert := true
var guard_post := Vector3.INF
var guard_yaw := 0.0
## Rescue: the hostage; a burst goes at him with this chance (if it sees him).
var alt_target: Node3D = null
var alt_chance := 0.0
var _target: Node3D = null
## Hunt the Commander: once alert, it runs to this spot (its escape vehicle)
## at flee_speed x walking speed without stopping to fight (INF = no), and
## emits fled on arrival.
signal fled
var flee_to := Vector3.INF
var flee_speed := 1.5
var _fled := false
## Share of non-headshot damage it takes (the Commander's vest). Fractions
## are rolled per hit.
var armor := 1.0
## The Commander's beret (make_commander()): follows the head every frame.
var _beret: MeshInstance3D

## Where it is in the cover loop (see the top of this file).
var tac := Tac.FIND
## The cover point it is using (an entry of the mode's cover points), or {}.
var cover: Dictionary = {}
## For tests: bullets fired, and how often it left a cover because the player
## could see it there.
var shots_fired := 0
var flanked_count := 0

var _peeks_left := 0
var _hide_left := 0.0
var _check_timer := 0.0
var _tac_time := 0.0
var _shots_left := 0
var _burst_timer := 0.0
var _muzzle_flash: MeshInstance3D
var _flash_left := 0.0
var _tracers: Array[MeshInstance3D] = []
var _tracer_runs: Array[Dictionary] = []   # per tracer: from, dir, length, travelled
var _next_tracer := 0
var _gun_sfx: AudioStreamPlayer3D
var _crouch: SkeletonModifier3D
var _crouched_capsule := false
var _crouch_head := {}   # crouched head hitbox: offset from the feet, radius
var _no_view: Array[Dictionary] = []  # covers whose peek showed nothing: {cover, player (where they were)}

static var _tracer_material: StandardMaterial3D
static var _flash_material: StandardMaterial3D


func _ready() -> void:
	super._ready()
	_muzzle_flash = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * Cfg.FLASH_SIZE
	quad.material = fx_materials()[1]
	_muzzle_flash.mesh = quad
	_muzzle_flash.top_level = true
	_muzzle_flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_muzzle_flash.visible = false
	add_child(_muzzle_flash)
	for i in 2:
		var box := BoxMesh.new()
		box.size = Vector3(Cfg.TRACER_WIDTH, Cfg.TRACER_WIDTH, 1.0)
		box.material = fx_materials()[0]
		var t := MeshInstance3D.new()
		t.mesh = box
		t.top_level = true
		t.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		t.visible = false
		add_child(t)
		_tracers.append(t)
		_tracer_runs.append({})
	_gun_sfx = AudioStreamPlayer3D.new()
	_gun_sfx.stream = RIFLE_SHOT
	_gun_sfx.unit_size = 12.0
	_gun_sfx.max_distance = 70.0
	_gun_sfx.max_polyphony = 3
	_gun_sfx.volume_db = -3.0
	_gun_sfx.position.y = stats.height * 0.8
	add_child(_gun_sfx)
	_crouch = CrouchModifier.new()
	_crouch.name = "Crouch"
	_crouch.influence = 0.0
	_skel.add_child(_crouch)
	_skel.skeleton_updated.connect(_on_skeleton_updated)


## The tracer and muzzle flash materials (shared by every soldier; the mode
## draws them once at load so the first shot doesn't stall on shaders).
static func fx_materials() -> Array[StandardMaterial3D]:
	if _tracer_material == null:
		_tracer_material = StandardMaterial3D.new()
		_tracer_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_tracer_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_tracer_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_tracer_material.albedo_color = Color(2.2, 1.6, 0.6, 1.0)
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.25, 1.0])
		g.colors = PackedColorArray([Color(1, 1, 0.9, 1), Color(1, 0.75, 0.3, 0.8), Color(1, 0.4, 0.05, 0)])
		var tex := GradientTexture2D.new()
		tex.gradient = g
		tex.fill = GradientTexture2D.FILL_RADIAL
		tex.fill_from = Vector2(0.5, 0.5)
		tex.fill_to = Vector2(0.5, 0.0)
		tex.width = 32
		tex.height = 32
		_flash_material = StandardMaterial3D.new()
		_flash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_flash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_flash_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_flash_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		_flash_material.albedo_color = Color(3.0, 2.0, 0.8, 1.0)
		_flash_material.albedo_texture = tex
	return [_tracer_material, _flash_material]


## Chance (0..1) that one bullet hits a player `distance` m away moving at
## `player_speed` m/s (soldiers_config.gd HIT_*, MOVING_*).
static func hit_chance(distance: float, player_speed: float) -> float:
	var t := clampf((distance - Cfg.NEAR_DISTANCE) / (Cfg.FAR_DISTANCE - Cfg.NEAR_DISTANCE), 0.0, 1.0)
	var c := lerpf(Cfg.HIT_NEAR, Cfg.HIT_FAR, t)
	return c * lerpf(1.0, Cfg.MOVING_FACTOR, clampf(player_speed / Cfg.MOVING_SPEED, 0.0, 1.0))


## True while it hides crouched behind low cover (and isn't shot, aiming or dead).
func wants_crouch() -> bool:
	return tac == Tac.HIDE and state == State.CHASE and cover.get("low", false)


## 0 = standing .. 1 = crouched.
func crouch_amount() -> float:
	return _crouch.influence


# The crouch only exists in the bone poses while the skeleton reports its
# update (the next animation step resets them), so the head hitbox is
# remembered here, relative to the soldier's feet.
func _on_skeleton_updated() -> void:
	if not is_inside_tree():
		return  # leaving the scene (Retry / scene change)
	if _crouch.influence <= 0.001:
		_crouch_head = {}
		return
	var head := super.head_sphere()
	if not head.is_empty():
		_crouch_head = {"offset": head.center - global_position, "radius": head.radius}


## The head hitbox, lowered while crouched (see _on_skeleton_updated).
func head_sphere() -> Dictionary:
	if _crouch.influence > 0.001 and not _crouch_head.is_empty():
		return {"center": global_position + _crouch_head.offset, "radius": _crouch_head.radius}
	return super.head_sphere()


# Blends the crouch in and out; the hit capsule is shortened while crouched
# (bullets over the cover miss).
func _update_crouch(delta: float) -> void:
	var want := 1.0 if wants_crouch() else 0.0
	if _crouch.influence == want:
		return
	_crouch.influence = move_toward(_crouch.influence, want, delta / Cfg.CROUCH_TIME)
	_crouch.forward = -global_basis.z
	var low := _crouch.influence > 0.5
	if low != _crouched_capsule and state != State.DEAD:
		_crouched_capsule = low
		var capsule := collision.shape as CapsuleShape3D
		capsule.height = Cfg.CROUCH_HEIGHT if low else stats.height
		collision.position.y = capsule.height * 0.5


func _process(delta: float) -> void:
	_update_crouch(delta)
	if _beret:
		_place_beret()
	if _flash_left > 0.0:
		_flash_left -= delta
		_muzzle_flash.global_position = _muzzle.global_position
		if _flash_left <= 0.0:
			_muzzle_flash.visible = false
	for i in _tracers.size():
		var run: Dictionary = _tracer_runs[i]
		if run.is_empty():
			continue
		run.travelled += Cfg.TRACER_SPEED * delta
		var head := minf(run.travelled, run.length)
		var tail := maxf(run.travelled - Cfg.TRACER_LENGTH, 0.0)
		if tail >= run.length:
			_tracers[i].visible = false
			_tracer_runs[i] = {}
			continue
		_stretch(_tracers[i], run.from + run.dir * tail, run.from + run.dir * head)


# --- Missions: pushers and guards ---------------------------------------------

# Defend: walk into the zone (push_spot) and hold it, firing a burst at the
# player whenever they show (every PUSH_FIRE_COOLDOWN s at most).
func _push_move(delta: float) -> void:
	_shot_cooldown -= delta
	_check_timer -= delta
	if _check_timer <= 0.0:
		_check_timer = 0.25
		if _shot_cooldown <= 0.0 and _flat_distance_to_player() < Cfg.SHOT_RANGE and can_see_player():
			_set_state(State.AIM)
			return
	if _arrived(push_spot):
		_stop()
		_face_player(delta)
	else:
		_walk_to(push_spot, delta, Mission.PUSH_SPEED)


# Rescue: stand at the post looking out until the player is heard (close)
# or seen in front of it; then the normal cover fight.
func _guard_move(delta: float) -> void:
	if guard_post != Vector3.INF and not _arrived(guard_post):
		_walk_to(guard_post, delta, 0.6)
	else:
		_stop()
		_turn_towards(Vector3(-sin(deg_to_rad(guard_yaw)), 0.0, -cos(deg_to_rad(guard_yaw))), delta)
	_check_timer -= delta
	if _check_timer > 0.0:
		return
	_check_timer = 0.3
	var d := _flat_distance_to_player()
	if d < Mission.GUARD_HEAR:
		raise_alert()
		return
	if d < Mission.GUARD_SIGHT:
		var to := _player.global_position - global_position
		to.y = 0.0
		var fwd := -global_basis.z
		fwd.y = 0.0
		if fwd.normalized().dot(to.normalized()) > Mission.GUARD_FOV and can_see_player():
			raise_alert()


## A guard notices the player (heard, seen, shot, or told by another guard).
func raise_alert() -> void:
	if alert or state == State.DEAD:
		return
	alert = true
	_go(Tac.FIND)
	alerted.emit()


# Hunt: run for the escape vehicle (no cover, no shooting); fled on arrival.
func _flee_move(delta: float) -> void:
	if _fled:
		_stop()
		return
	if _arrived(flee_to):
		_fled = true
		_stop()
		fled.emit()
		return
	_walk_to(flee_to, delta, flee_speed)


## True once it reached its escape spot.
func has_fled() -> bool:
	return _fled


## Hunt the Commander: a darker red uniform (`tint` on every material), a red
## beret on the head, `armor` on body shots. Call after it entered the tree.
func make_commander(tint: Color, beret_color: Color, body_armor: float) -> void:
	armor = body_armor
	for mi: MeshInstance3D in meshes:
		for s in mi.mesh.get_surface_count():
			var src := mi.get_active_material(s) as BaseMaterial3D
			if src == null:
				continue
			var m := src.duplicate() as BaseMaterial3D
			m.albedo_color = src.albedo_color * tint
			mi.set_surface_override_material(s, m)
	_beret = MeshInstance3D.new()
	_beret.name = "Beret"
	var cap := SphereMesh.new()
	cap.radius = 0.13
	cap.height = 0.12
	cap.radial_segments = 12
	cap.rings = 4
	cap.is_hemisphere = true
	var mat := StandardMaterial3D.new()
	mat.albedo_color = beret_color
	mat.roughness = 0.9
	cap.material = mat
	_beret.mesh = cap
	_beret.top_level = true
	_beret.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_beret)
	_place_beret()


# On top of the head, tilted to one side like a beret.
func _place_beret() -> void:
	if state == State.DEAD and _state_time > 0.6:
		_beret.visible = false  # the death fall would leave it floating
		return
	var head := head_sphere()
	if head.is_empty():
		return
	var top: Vector3 = _skel.global_transform * _skel.get_bone_global_pose(_head_end_bone).origin \
			if _head_end_bone >= 0 else head.center + Vector3.UP * head.radius
	var up: Vector3 = (top - head.center).normalized()
	var fwd := -global_basis.z
	var side := up.cross(fwd).normalized()
	if side.length_squared() < 0.5:
		side = global_basis.x
	var b := Basis(side, up, side.cross(up)).rotated(fwd.normalized(), 0.25)
	_beret.global_transform = Transform3D(b, head.center + up * head.radius * 0.55)


## The beret (for tests).
func beret() -> Node3D:
	return _beret

# --- Cover loop ----------------------------------------------------------------

# Called by enemy.gd every physics frame while in CHASE (its own soldier move
# when the scene has no cover points).
func _soldier_move(delta: float) -> void:
	if not _player_alive():
		_stop()
		_update_move_anim()
		return
	if not alert:
		_guard_move(delta)
		_update_move_anim()
		return
	if flee_to != Vector3.INF:
		_flee_move(delta)
		_update_move_anim()
		return
	if _player_in_range(stats.attack_range):
		_set_state(State.ATTACK)  # rifle jab, as in enemy.gd
		return
	if push_spot != Vector3.INF:
		_push_move(delta)
		_update_move_anim()
		return
	var points := _cover_points()
	if points.is_empty() and tac != Tac.OPEN:
		tac = Tac.OPEN
		_tac_time = 0.0
	_tac_time += delta
	_check_timer -= delta
	match tac:
		Tac.FIND:
			_stop()
			_find_cover()
		Tac.MOVE:
			if _arrived(cover.pos):
				_start_hide()
			elif _tac_time > 12.0 or _player_too_close():
				_go(Tac.FIND)
			else:
				_walk_to(cover.pos, delta, Cfg.RUN_SPEED)
		Tac.HIDE:
			_stop()
			_face_player(delta)
			_hide_left -= delta
			if _check_timer <= 0.0:
				_check_timer = Cfg.FLANK_CHECK
				if _player_too_close() or _exposed_at(cover.pos, cover.get("eye", Cfg.EYE_HEIGHT)):
					flanked_count += 1
					_go(Tac.FIND)
					return
			if _hide_left <= 0.0:
				_go(Tac.PEEK if _peeks_left > 0 else Tac.FIND)
		Tac.PEEK:
			if _check_timer <= 0.0:
				_check_timer = 0.15
				if can_see_player():
					_set_state(State.AIM)
					return
			if _arrived(cover.peek):
				_stop()
				_face_player(delta)
				if _tac_time > Cfg.PEEK_WAIT:
					# No view from here: remember it and go to another cover.
					_no_view.append({"cover": cover, "player": _player.global_position})
					_peeks_left -= 1
					_go(Tac.FIND)
			else:
				_walk_to(cover.peek, delta, Cfg.PEEK_SPEED)
				if _tac_time > 5.0:
					_go(Tac.RETURN)
		Tac.RETURN:
			if _arrived(cover.pos):
				_start_hide()
			else:
				_walk_to(cover.pos, delta, Cfg.RUN_SPEED)
				if _check_timer <= 0.0:
					_check_timer = Cfg.FLANK_CHECK
					if _tac_time > 5.0 or _player_too_close():
						_go(Tac.FIND)
		Tac.OPEN:
			# enemy.gd's soldier: a firing spot in the open (bursts via AIM).
			super._soldier_move(delta)
			if _tac_time > Cfg.SEARCH_RETRY and not points.is_empty():
				_go(Tac.FIND)
	_update_move_anim()


func _go(t: Tac) -> void:
	tac = t
	_tac_time = 0.0
	_check_timer = 0.0
	if t == Tac.FIND or t == Tac.OPEN:
		_release_cover()


func _start_hide() -> void:
	_go(Tac.HIDE)
	_hide_left = randf_range(Cfg.HIDE_TIME.x, Cfg.HIDE_TIME.y)
	_check_timer = Cfg.FLANK_CHECK


func _arrived(pos: Vector3) -> bool:
	return _flat_distance(global_position, pos) <= SPOT_REACHED


func _player_too_close() -> bool:
	return not cover.is_empty() and _flat_distance(cover.pos, _player.global_position) < Cfg.TOO_CLOSE


func _cover_points() -> Array:
	var main := get_tree().current_scene
	if main and main.has_method("get_cover_points"):
		return main.get_cover_points()
	return []


## Picks the cover point: free, in range, on the far side of its object from
## the player (cheap checks first), then by distance; the best few get two
## rays (hidden from the player at the point, a view from its peek spot).
## Hidden-but-no-view (tall cover only) is kept as a fallback. Nothing found: fight in the open.
func _find_cover() -> void:
	var player_pos := _player.global_position
	var candidates: Array = []
	for c: Dictionary in _cover_points():
		var owner_node: Variant = c.owner
		if owner_node != null and owner_node != self and is_instance_valid(owner_node):
			continue
		if _gave_no_view(c):
			continue
		var d := _flat_distance(c.pos, player_pos)
		if d < maxf(Cfg.COVER_RANGE.x, Cfg.TOO_CLOSE + 0.5) or d > Cfg.COVER_RANGE.y:
			continue
		var to_player := Vector3(player_pos.x - c.pos.x, 0.0, player_pos.z - c.pos.z).normalized()
		if (c.normal as Vector3).dot(to_player) > -0.2:
			continue  # the player is on this side of the object
		var cost := _flat_distance(global_position, c.pos) + 0.6 * absf(d - Cfg.COVER_BEST_DISTANCE)
		candidates.append([cost, c])
	candidates.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var rays := 0
	var chosen: Dictionary = {}
	var fallback: Dictionary = {}
	for entry: Array in candidates:
		if rays + 2 > Cfg.COVER_RAY_BUDGET:
			break
		var c: Dictionary = entry[1]
		rays += 1
		if _exposed_at(c.pos, c.get("eye", Cfg.EYE_HEIGHT)):
			continue
		rays += 1
		if _clear_view_from(c.peek):
			chosen = c
			break
		if fallback.is_empty() and not c.get("low", false):  # low cover without a view is useless
			fallback = c
	if chosen.is_empty():
		chosen = fallback
	if chosen.is_empty():
		_go(Tac.OPEN)
		return
	_release_cover()
	cover = chosen
	cover.owner = self
	_peeks_left = randi_range(Cfg.PEEKS_PER_COVER.x, Cfg.PEEKS_PER_COVER.y)
	_go(Tac.MOVE)


# True if peeking from `c` showed nothing and the player hasn't moved
# NO_VIEW_RESET m since (older entries are dropped).
func _gave_no_view(c: Dictionary) -> bool:
	var player_pos := _player.global_position
	_no_view = _no_view.filter(func(e: Dictionary) -> bool:
		return _flat_distance(e.player, player_pos) < Cfg.NO_VIEW_RESET)
	for e in _no_view:
		if e.cover == c:
			return true
	return false


## True if the player could see this soldier's head at `pos`, eyes `eye` m
## up (standing, or crouched behind low cover). Only walls and props block
## the view; the see-through fence doesn't.
func _exposed_at(pos: Vector3, eye_height := Cfg.EYE_HEIGHT) -> bool:
	var eye := _player.global_position + Vector3.UP * 1.6
	var cam := get_viewport().get_camera_3d()
	if cam:
		eye = cam.global_position
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * eye_height, eye, 1, _sight_exclusions())
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.is_empty() or hit.collider == _player


func _release_cover() -> void:
	if not cover.is_empty() and cover.owner == self:
		cover.owner = null
	cover = {}


# Walk while moving, the rifle-up pose while standing.
func _update_move_anim() -> void:
	var want: String = stats.anims.walk if _wants_move else stats.anims.idle
	if anim.current_animation != want:
		if _wants_move:
			anim.play(want, 0.2, _walk_anim_speed())
		else:
			_play_idle(0.2)


# --- Bursts --------------------------------------------------------------------

func _set_state(new_state: State) -> void:
	if new_state != State.AIM:
		super._set_state(new_state)
		return
	# Raise the rifle (no warning laser in this mode), then a burst.
	state = State.AIM
	_state_time = 0.0
	_shots_left = randi_range(Cfg.BURST.x, Cfg.BURST.y)
	_burst_timer = 0.0
	_play_from_start(stats.anims.shoot, 0.15)
	anim.seek(AIM_POSE_TIME, true)
	anim.pause()
	# Rescue missions: some bursts go at the hostage (when it can see him).
	_target = _player
	if is_instance_valid(alt_target) and alt_chance > 0.0 and randf() < alt_chance \
			and alt_target.has_method("is_targetable") and alt_target.call("is_targetable") \
			and _clear_view_to(alt_target.global_position + Vector3.UP * 0.9):
		_target = alt_target


## What the current burst is aimed at (the player unless it chose the hostage).
func _burst_target() -> Node3D:
	return _target if is_instance_valid(_target) else _player


## True if nothing solid is between the soldier's eyes and `point`.
func _clear_view_to(point: Vector3) -> bool:
	var from: Vector3 = global_position + Vector3.UP * stats.height * 0.85
	var q := PhysicsRayQueryParameters3D.create(from, point, SIGHT_MASK, _sight_exclusions())
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


# AIM state: raise, then fire _shots_left bullets BURST_INTERVAL apart.
func _aim(delta: float) -> void:
	_stop()
	var tgt := _burst_target()
	var to := tgt.global_position - global_position
	to.y = 0.0
	_turn_towards(to.normalized(), delta)
	if not _player_alive() or (tgt != _player and not tgt.call("is_targetable")):
		_end_burst()
		return
	if _state_time < Cfg.AIM_TIME:
		return
	if not anim.is_playing():
		anim.play()  # the firing motion of the clip
	_burst_timer -= delta
	if _burst_timer > 0.0:
		return
	if _shots_left <= 0:
		_end_burst()
		return
	_fire()
	_shots_left -= 1
	_burst_timer = Cfg.BURST_INTERVAL


func _end_burst() -> void:
	_shot_cooldown = randf_range(SHOT_COOLDOWN.x, SHOT_COOLDOWN.y)
	_set_state(State.CHASE)
	if push_spot != Vector3.INF:
		_shot_cooldown = randf_range(Mission.PUSH_FIRE_COOLDOWN.x, Mission.PUSH_FIRE_COOLDOWN.y)
		return
	if tac == Tac.OPEN:
		return
	_peeks_left -= 1
	_go(Tac.RETURN if not cover.is_empty() and _peeks_left > 0 else Tac.FIND)


## One bullet at the burst's target (the player, or the hostage in a Rescue
## mission): hits with hit_chance(), otherwise goes past. Walls and props stop it.
func _fire() -> void:
	var tgt := _burst_target()
	var from := _muzzle.global_position
	var chest := tgt.global_position + Vector3.UP * (1.2 if tgt == _player else 0.9)
	var tv: Vector3 = tgt.get("velocity") if tgt.get("velocity") is Vector3 else Vector3.ZERO
	var speed := Vector2(tv.x, tv.z).length()
	var target := chest
	if randf() > hit_chance(_flat_distance(global_position, tgt.global_position), speed):
		var side := (chest - from).cross(Vector3.UP).normalized()
		target += side * randf_range(Cfg.MISS_OFFSET.x, Cfg.MISS_OFFSET.y) * (1.0 if randf() < 0.5 else -1.0) \
				+ Vector3.UP * randf_range(-0.3, 0.6)
	var dir := (target - from).normalized()
	var mask := SIGHT_MASK
	if tgt != _player and tgt is CollisionObject3D:
		mask |= (tgt as CollisionObject3D).collision_layer
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * Cfg.SHOT_RANGE, mask, _sight_exclusions())
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var end := from + dir * Cfg.SHOT_RANGE
	var hit_player := false
	if not hit.is_empty():
		end = hit.position
		if hit.collider == _player:
			hit_player = true
			_player.take_damage(Cfg.SHOT_DAMAGE)
			end -= dir * minf(Cfg.TRACER_HIT_SHORT, from.distance_to(end) * 0.5)
		elif hit.collider == tgt and tgt.has_method("take_bullet"):
			tgt.call("take_bullet", global_position)
	if is_instance_valid(alt_target) and alt_target.has_method("bullet_passed"):
		alt_target.call("bullet_passed", from, end)  # the hostage ducks when bullets fly close
	shots_fired += 1
	_launch_tracer(from, end)
	_muzzle_flash.global_position = from
	_muzzle_flash.scale = Vector3.ONE * randf_range(0.8, 1.2)
	_muzzle_flash.visible = true
	_flash_left = Cfg.FLASH_TIME
	_gun_sfx.pitch_scale = randf_range(0.93, 1.07)
	_gun_sfx.play()
	if tgt == _player:
		shot_at_player.emit(global_position, hit_player)


func _launch_tracer(from: Vector3, to: Vector3) -> void:
	var i := _next_tracer
	_next_tracer = (_next_tracer + 1) % _tracers.size()
	var length := from.distance_to(to)
	if length < 0.5:
		return
	# Starts half a streak out of the muzzle, so it shows on the first frame.
	_tracer_runs[i] = {"from": from, "dir": (to - from) / length, "length": length,
			"travelled": Cfg.TRACER_LENGTH * 0.5}
	_stretch(_tracers[i], from, from + (to - from) / length * minf(Cfg.TRACER_LENGTH * 0.5, length))
	_tracers[i].visible = true


## True while a tracer or the muzzle flash is on screen (for tests).
func fx_visible() -> bool:
	if _muzzle_flash.visible:
		return true
	for t in _tracers:
		if t.visible:
			return true
	return false


func is_gun_sound_playing() -> bool:
	return _gun_sfx.playing


# --- Hits, death, relocation ---------------------------------------------------

func take_damage(amount: int, hit_position := Vector3.ZERO, hit_normal := Vector3.UP, headshot := false) -> void:
	if armor < 1.0 and not headshot:
		# The vest: body hits lose part of their damage (fractions rolled).
		var scaled := amount * armor
		amount = int(scaled) + (1 if randf() < scaled - int(scaled) else 0)
	super.take_damage(amount, hit_position, hit_normal, headshot)
	raise_alert()
	# Shot while out: duck back behind the cover.
	if state != State.DEAD and not cover.is_empty() and tac == Tac.PEEK:
		_go(Tac.RETURN)


func _die() -> void:
	super._die()
	_release_cover()
	_muzzle_flash.visible = false


func relocate(pos: Vector3) -> void:
	super.relocate(pos)
	_go(Tac.FIND)
