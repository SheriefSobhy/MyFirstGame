extends "res://enemy.gd"
## Combat mode and missions: the Mixamo soldier that has to notice the player
## before it fights, and then fights from cover. The zombie mode's soldier
## (enemy.gd) is not changed; this script replaces its senses, movement,
## shooting and animation. Health, headshots (head_sphere / is_head_hit),
## knockback + flinch, death, navigation and the stuck handling come from
## enemy.gd unchanged. Every number: soldiers_config.gd.
##
## Perception (awareness):
##   UNAWARE     mission guards patrol round their post; Combat-wave soldiers
##               sweep the area round a rough guess of where the player is
##   SUSPICIOUS  "?": heard a gunshot / sprinting / an explosion, or glimpsed
##               the player: turns, walks to the spot, looks round, calms down
##   COMBAT      "!": the cover fight below. Seeing the player (cone + clear
##               line, range shortened by darkness / fog) fills a notice
##               meter; being shot, or a squad mate's radio report, goes
##               straight here
##   SEARCH      "?": no sight or sound of the player for LOSE_CONTACT s: goes
##               to the last known position, checks the cover nearby, back to
##               UNAWARE after SEARCH_TIME s
## A soldier that goes into combat radios the player's position to the others
## within RADIO_RANGE m, RADIO_DELAY s later (not instantly, not map-wide).
##
## Cover points come from the mode (soldiers_mode.gd get_cover_points(): spots
## beside the map's houses, containers, racks, cars, crates...; tall cover
## has a peek spot just past the corner, behind low cover the soldier
## crouches and stands up to fire over it). The combat loop:
##   FIND   pick a free cover point 6-24 m from the player that hides it from
##          the player and whose peek spot can see the player (a few rays)
##   MOVE   run there (strafing, facing the player, when they are close and in view)
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
##
## Animation: an AnimationTree (shared tree, see _tree_root) blends the
## locomotion clips by velocity in the soldier's frame (relaxed / aiming idle,
## walk, walk back, strafe left / right, run), at the playback speed that
## matches the ground speed; crouch idle behind low cover, aiming idle while
## firing, the jab, death, and a hit reaction over the top.

## A bullet was fired at the player (hit = it hit them; armor may still have
## taken it). The mode shows the damage direction from `from`.
signal shot_at_player(from: Vector3, hit: bool)
## It went into combat (saw the player, was shot, got a radio report...).
signal alerted
## Hunt the Commander: reached its escape spot.
signal fled

const Cfg := preload("res://soldiers/soldiers_config.gd")
const RIFLE_SHOT := preload("res://assets/sounds/guns/ak_shot.wav")
const Mission := preload("res://missions/missions_config.gd")
const Synth := preload("res://effects/synth_sounds.gd")

enum Tac { FIND, MOVE, HIDE, PEEK, RETURN, OPEN }
enum Aware { UNAWARE, SUSPICIOUS, COMBAT, SEARCH }

# AnimationTree parameters (see _tree_root).
const P_LOCO := &"parameters/loco/blend_position"
const P_STANCE := &"parameters/loco/stand/blend_position"
const P_LOCO_SPEED := &"parameters/loco_speed/scale"
const P_ACTION := &"parameters/action/transition_request"
const P_JAB_SPEED := &"parameters/jab_speed/scale"
const P_JAB_SEEK := &"parameters/jab_seek/seek_request"
const P_DEATH_SPEED := &"parameters/death_speed/scale"
const P_FIRE := &"parameters/fire/request"
const P_HIT := &"parameters/hit/request"
const P_HIT_SPEED := &"parameters/hit_speed/scale"

## How aware of the player it is (see the top of this file).
var awareness := Aware.COMBAT
## Spawn setting, kept from before awareness existed: false = UNAWARE, true =
## COMBAT. Reads true while fighting or searching ("has noticed the player").
var alert: bool:
	get:
		return awareness == Aware.COMBAT or awareness == Aware.SEARCH
	set(value):
		awareness = Aware.COMBAT if value else Aware.UNAWARE

## Missions (missions/mission_mode.gd) only; defaults = the Waves soldier.
## Defend: a "pusher" walks to this spot in the zone and holds it (INF = no).
var push_spot := Vector3.INF
## Mission guards: their post (patrol starts and ends there) and the way they
## look while standing at it (degrees, 0 = -Z). INF = not a guard: when
## unaware it sweeps round a guess of the player's position instead.
var guard_post := Vector3.INF
var guard_yaw := 0.0
## Rescue: the hostage; a burst goes at him with this chance (if it sees him).
var alt_target: Node3D = null
var alt_chance := 0.0
var _target: Node3D = null
## Hunt the Commander: once alert, it runs to this spot (its escape vehicle)
## at flee_speed x walking speed without stopping to fight (INF = no), and
## emits fled on arrival.
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
## For tests: bullets fired, how often it left a cover because the player
## could see it there, radio reports sent.
var shots_fired := 0
var flanked_count := 0
var radio_reports := 0

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
var _crouch_amount := 0.0
var _crouched_capsule := false
var _no_view: Array[Dictionary] = []  # covers whose peek showed nothing: {cover, player (where they were)}

# Perception.
var _notice := 0.0               # 0..1: how close it is to noticing the player
var _percept_timer := 0.0
var _known_pos := Vector3.INF    # where it last saw / heard the player
var _contact_time := 0.0         # s since it last saw or heard the player (combat)
var _seen_time := 99.0           # s since it last saw the player
var _heard_shot_time := 99.0
var _investigate_pos := Vector3.INF
var _goal := Vector3.INF         # patrol / sweep / search point it walks to
var _wait_left := 0.0            # s it stays at the point it reached
var _look_time := 0.0
var _look_yaw := 0.0
var _mode_time := 0.0            # s in the current awareness
var _route: Array[Vector3] = []
var _route_index := 0
var _search_points: Array[Vector3] = []
var _radio_left := 0.0           # s until the pending radio report (0 = none)
var _radio_pos := Vector3.ZERO
var _radio_cooldown := 0.0
var _radio_sfx: AudioStreamPlayer3D
var _icon: Label3D
var _icon_alert_left := 0.0
# Movement and animation.
var _strafe := false             # moving while facing the player
var _strafe_timer := 0.0
var _strafe_was := false
var _turn_frame := -1
var _turn_from := 0.0
var _tree: AnimationTree
var _action := ""
var _blend := Vector2.ZERO
var _anim_scale := 1.0
var _stance := 0.0               # 0 = relaxed idle .. 1 = aiming idle
var _prev_yaw := 0.0
var _yaw_rate := 0.0
var _hit_left := 0.0

static var _tracer_material: StandardMaterial3D
static var _flash_material: StandardMaterial3D
static var _shared_tree: AnimationNodeBlendTree
static var _clip_speeds := {}    # walk / back / left / right / run: m/s at model scale 1


func _ready() -> void:
	super._ready()
	add_to_group("hears_noise")
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
	_radio_sfx = AudioStreamPlayer3D.new()
	_radio_sfx.stream = Synth.radio()
	_radio_sfx.unit_size = 5.0
	_radio_sfx.max_distance = 35.0
	_radio_sfx.volume_db = -6.0
	_radio_sfx.position.y = stats.height * 0.85
	add_child(_radio_sfx)
	_icon = make_icon()
	_icon.position.y = stats.height + Cfg.ICON_HEIGHT
	add_child(_icon)
	_setup_tree()
	_percept_timer = randf() * Cfg.PERCEPTION_TICK  # spread the checks over frames
	_prev_yaw = rotation.y
	if awareness == Aware.COMBAT and _player:
		_known_pos = _player.global_position  # reinforcements / pushers: told where the player is
	elif awareness == Aware.UNAWARE and guard_post != Vector3.INF:
		_wait_left = randf_range(Cfg.PATROL_WAIT.x, Cfg.PATROL_WAIT.y)


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


## The "?" / "!" label above a soldier's head (the mode also draws one at
## load, so its shader is ready).
static func make_icon() -> Label3D:
	var l := Label3D.new()
	l.name = "AwarenessIcon"
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.fixed_size = true
	l.pixel_size = 0.0011
	l.font_size = 64
	l.outline_size = 16
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	l.text = "?"
	l.visible = false
	return l


## Chance (0..1) that one bullet hits a player `distance` m away moving at
## `player_speed` m/s (soldiers_config.gd HIT_*, MOVING_*).
static func hit_chance(distance: float, player_speed: float) -> float:
	var t := clampf((distance - Cfg.NEAR_DISTANCE) / (Cfg.FAR_DISTANCE - Cfg.NEAR_DISTANCE), 0.0, 1.0)
	var c := lerpf(Cfg.HIT_NEAR, Cfg.HIT_FAR, t)
	return c * lerpf(1.0, Cfg.MOVING_FACTOR, clampf(player_speed / Cfg.MOVING_SPEED, 0.0, 1.0))


## True while it hides crouched behind low cover (and isn't shot, aiming or dead).
func wants_crouch() -> bool:
	return tac == Tac.HIDE and state == State.CHASE and awareness == Aware.COMBAT and cover.get("low", false)


## 0 = standing .. 1 = crouched.
func crouch_amount() -> float:
	return _crouch_amount


# The crouch clip blends in (the action transition); the hit capsule is
# shortened while crouched (bullets over the cover miss).
func _update_crouch(delta: float) -> void:
	var want := 1.0 if wants_crouch() else 0.0
	if _crouch_amount == want:
		return
	_crouch_amount = move_toward(_crouch_amount, want, delta / Cfg.CROUCH_TIME)
	var low := _crouch_amount > 0.5
	if low != _crouched_capsule and state != State.DEAD:
		_crouched_capsule = low
		var capsule := collision.shape as CapsuleShape3D
		capsule.height = Cfg.CROUCH_HEIGHT if low else stats.height
		collision.position.y = capsule.height * 0.5


func _process(delta: float) -> void:
	_update_crouch(delta)
	_update_anim(delta)
	_update_icon(delta)
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


# --- Perception -----------------------------------------------------------------

## For tests and the HUD-less demo: "?" / "!" / "" as shown above the head.
func icon_text() -> String:
	return _icon.text if _icon.visible else ""


## The notice meter (0..1, for tests).
func notice_level() -> float:
	return _notice


## Where it last saw / heard the player (INF = never).
func known_position() -> Vector3:
	return _known_pos


# Every physics frame (CHASE / AIM / HIT): timers; the sight check every
# PERCEPTION_TICK s.
func _perceive(delta: float) -> void:
	_contact_time += delta
	_seen_time += delta
	_heard_shot_time += delta
	_mode_time += delta
	_radio_cooldown -= delta
	if _radio_left > 0.0:
		_radio_left -= delta
		if _radio_left <= 0.0:
			_send_radio()
	_percept_timer -= delta
	if _percept_timer > 0.0 or not _player_alive():
		return
	var tick := Cfg.PERCEPTION_TICK - _percept_timer
	_percept_timer = Cfg.PERCEPTION_TICK
	var d := _flat_distance_to_player()
	if awareness == Aware.COMBAT:
		if d < Cfg.COMBAT_SIGHT_RANGE and can_see_player():
			_contact(_player.global_position, true)
		elif _contact_time > Cfg.LOSE_CONTACT and push_spot == Vector3.INF and flee_to == Vector3.INF:
			_start_search()
		return
	if _sees_player(d):
		var near := clampf((d - Cfg.NOTICE_NEAR) / maxf(_sight_range() - Cfg.NOTICE_NEAR, 1.0), 0.0, 1.0)
		var need := lerpf(Cfg.NOTICE_TIME.x, Cfg.NOTICE_TIME.y, near)
		if awareness != Aware.UNAWARE:
			need /= Cfg.AWARE_NOTICE
		_notice += tick / need
		if d < Cfg.TOUCH_RANGE or _notice >= 1.0:
			_enter_combat(_player.global_position)
			return
		if _notice >= Cfg.SUSPECT_LEVEL:
			_suspect(_player.global_position)
	else:
		_notice = maxf(_notice - Cfg.NOTICE_DECAY * tick, 0.0)
	if d < Cfg.SPRINT_HEAR and _player_sprinting():
		hear_noise(_player.global_position)


## The sight range where the player stands: SIGHT_RANGE x the map's
## visibility there (soldiers_mode.gd visibility_at: darkness, fog, lamps).
func _sight_range() -> float:
	var main := get_tree().current_scene
	var vis := 1.0
	if main and main.has_method("visibility_at"):
		vis = main.visibility_at(_player.global_position)
	return Cfg.SIGHT_RANGE * vis


# In range, in the view cone (or right next to it), and a clear line.
func _sees_player(d: float) -> bool:
	if d > _sight_range():
		return false
	if d > Cfg.TOUCH_RANGE:
		var to := _player.global_position - global_position
		to.y = 0.0
		var fwd := -global_basis.z
		fwd.y = 0.0
		if fwd.normalized().dot(to.normalized()) < cos(deg_to_rad(Cfg.SIGHT_FOV * 0.5)):
			return false
	return can_see_player()


func _player_sprinting() -> bool:
	var v: Vector3 = _player.velocity
	return Vector2(v.x, v.z).length() > Cfg.SPRINT_SPEED and _player.is_on_floor()


## The player fired at `pos` (soldiers_mode.gd, every shot): heard within
## GUNSHOT_HEAR m with a clear line, GUNSHOT_HEAR_BLOCKED x that through walls.
func hear_gunshot(pos: Vector3) -> void:
	if state == State.DEAD:
		return
	if awareness == Aware.COMBAT and _heard_shot_time < 0.4:
		return  # a burst: once is enough
	var d := global_position.distance_to(pos)
	if d > Cfg.GUNSHOT_HEAR:
		return
	if d > Cfg.GUNSHOT_HEAR * Cfg.GUNSHOT_HEAR_BLOCKED:
		var q := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 1.5,
				global_position + Vector3.UP * stats.height * 0.85, 1, _sight_exclusions())
		if not get_world_3d().direct_space_state.intersect_ray(q).is_empty():
			return
	_heard_shot_time = 0.0
	hear_noise(pos)


## An explosion (effects/blast.gd: grenades, barrels, C4) within EXPLOSION_HEAR m.
func hear_explosion(pos: Vector3) -> void:
	if state == State.DEAD or awareness == Aware.COMBAT:
		return
	if global_position.distance_to(pos) <= Cfg.EXPLOSION_HEAR:
		hear_noise(pos)


## A noise from the player at `pos` (gunshot, sprinting, a C4 being
## planted...): in combat it tells where they are; searching, it goes
## straight back to combat; otherwise it gets suspicious and looks.
func hear_noise(pos: Vector3) -> void:
	if state == State.DEAD:
		return
	match awareness:
		Aware.COMBAT:
			_contact(pos, false)
		Aware.SEARCH:
			_enter_combat(pos)
		_:
			_suspect(pos)


## A squad mate's radio report (within RADIO_RANGE m): the player is at `pos`.
func hear_radio(pos: Vector3) -> void:
	if state == State.DEAD:
		return
	if awareness == Aware.COMBAT:
		_contact(pos, false)
	else:
		_enter_combat(pos, false)


## The player is somewhere: noticed (shot, heard, seen, told by another
## soldier, or a mission event). Goes into combat.
func raise_alert() -> void:
	if state == State.DEAD or not _player:
		return
	if awareness == Aware.COMBAT:
		_contact(_player.global_position, false)
	else:
		_enter_combat(_player.global_position)


func _contact(pos: Vector3, seen: bool) -> void:
	_known_pos = pos
	_contact_time = 0.0
	if seen:
		_seen_time = 0.0


# Into the cover fight, and radio it (unless it heard it on the radio).
func _enter_combat(pos: Vector3, radio := true) -> void:
	var seen := _player != null and pos.distance_to(_player.global_position) < 0.5 and _notice >= 1.0
	awareness = Aware.COMBAT
	_mode_time = 0.0
	_notice = 1.0
	_contact(pos, seen)
	_icon_alert_left = Cfg.ICON_ALERT_TIME
	_go(Tac.FIND)
	if radio and _radio_left <= 0.0 and _radio_cooldown <= 0.0:
		_radio_left = randf_range(Cfg.RADIO_DELAY.x, Cfg.RADIO_DELAY.y)
		_radio_pos = pos
	alerted.emit()


func _suspect(pos: Vector3) -> void:
	if awareness != Aware.SUSPICIOUS:
		awareness = Aware.SUSPICIOUS
		_mode_time = 0.0
		_release_cover()
	_investigate_pos = pos
	_look_time = 0.0
	_wait_left = 0.0


# Lost the player in combat: the last known position, then the cover round it.
func _start_search() -> void:
	awareness = Aware.SEARCH
	_mode_time = 0.0
	_notice = 0.0
	_release_cover()
	_search_points.clear()
	var map := get_world_3d().navigation_map
	if _known_pos != Vector3.INF:
		_search_points.append(NavigationServer3D.map_get_closest_point(map, _known_pos))
		var near: Array = []
		for c: Dictionary in _cover_points():
			var d := _flat_distance(c.pos, _known_pos)
			if d <= Cfg.SEARCH_RADIUS and (c.owner == null or not is_instance_valid(c.owner)):
				near.append([d, c.pos])
		near.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
		for i in mini(near.size(), Cfg.SEARCH_COVERS):
			_search_points.append(near[i][1])
	_goal = Vector3.INF
	_wait_left = 0.0


# Back to normal: its patrol (guards) or the sweep (Combat waves).
func _calm_down() -> void:
	awareness = Aware.UNAWARE
	_mode_time = 0.0
	_notice = 0.0
	_goal = Vector3.INF
	_wait_left = 0.0
	_release_cover()


func _send_radio() -> void:
	if state == State.DEAD:
		return
	_radio_cooldown = Cfg.RADIO_INTERVAL
	radio_reports += 1
	_radio_sfx.play()
	for e in get_tree().get_nodes_in_group("hears_noise"):
		if e != self and e.has_method("hear_radio") and is_instance_valid(e) \
				and (e as Node3D).global_position.distance_to(global_position) <= Cfg.RADIO_RANGE:
			e.hear_radio(_radio_pos)


func _update_icon(delta: float) -> void:
	_icon_alert_left -= delta
	var text := ""
	if state == State.DEAD:
		text = ""
	elif _icon_alert_left > 0.0 and awareness == Aware.COMBAT:
		text = "!"
	elif awareness == Aware.SUSPICIOUS or awareness == Aware.SEARCH:
		text = "?"
	_icon.visible = text != ""
	if text != "" and _icon.text != text:
		_icon.text = text
		_icon.modulate = Color(1.0, 0.25, 0.15) if text == "!" else Color(1.0, 0.85, 0.2)
	_icon.position.y = stats.height + Cfg.ICON_HEIGHT - 0.6 * _crouch_amount


# --- Unaware, suspicious, searching ---------------------------------------------

# UNAWARE. Guards: round their patrol (post first, then the other points),
# waiting at each, looking along guard_yaw at the post. Others (Combat
# waves, reinforcements that lost the player): sweep round a rough guess of
# where the player is.
func _patrol_move(delta: float) -> void:
	if guard_post != Vector3.INF:
		if _route.is_empty():
			_build_route()
		var point: Vector3 = _route[_route_index % _route.size()] if not _route.is_empty() else guard_post
		if _wait_left > 0.0 or _arrived(point):
			_stop()
			if _wait_left <= 0.0:
				_wait_left = randf_range(Cfg.PATROL_WAIT.x, Cfg.PATROL_WAIT.y)
				_look_time = 0.0
				_look_yaw = rotation.y
			_wait_left -= delta
			if _route_index % maxi(_route.size(), 1) == 0:
				var yaw := deg_to_rad(guard_yaw)
				_turn_towards(Vector3(-sin(yaw), 0.0, -cos(yaw)), delta)
			else:
				_look_around(delta)
			if _wait_left <= 0.0 and _route.size() > 1:
				_route_index = (_route_index + 1) % _route.size()
		else:
			_walk_to(point, delta, Cfg.PATROL_SPEED)
		return
	# The sweep.
	if _goal == Vector3.INF or _mode_time > 15.0:
		_goal = _guess_player_area()
		_mode_time = 0.0
	if _wait_left > 0.0:
		_stop()
		_wait_left -= delta
		_look_around(delta)
		if _wait_left <= 0.0:
			_goal = Vector3.INF
		return
	if _goal == Vector3.INF:
		_stop()
		return
	_walk_to(_goal, delta, Cfg.HUNT_SPEED)
	if _arrived(_goal) or (not _wants_move and _mode_time > 1.0):
		_wait_left = Cfg.SEARCH_LOOK
		_look_time = 0.0
		_look_yaw = rotation.y


# A point on the navmesh about HUNT_GUESS m from the player (INF while the
# navmesh isn't ready).
func _guess_player_area() -> Vector3:
	if not _navmesh_ready():
		return Vector3.INF
	var a := randf() * TAU
	var p := _player.global_position + Vector3(cos(a), 0.0, sin(a)) * randf_range(0.3, 1.0) * Cfg.HUNT_GUESS
	return NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, p)


# The post and PATROL_POINTS more points PATROL_RADIUS m round it that the
# navmesh reaches with a short walk (or just the post).
func _build_route() -> void:
	if not _navmesh_ready():
		return
	_route = [guard_post]
	var map := get_world_3d().navigation_map
	var tries := 0
	while _route.size() < Cfg.PATROL_POINTS + 1 and tries < 16:
		tries += 1
		var a := randf() * TAU
		var r := randf_range(Cfg.PATROL_RADIUS.x, Cfg.PATROL_RADIUS.y)
		var want := guard_post + Vector3(cos(a), 0.0, sin(a)) * r
		var path := NavigationServer3D.map_get_path(map, guard_post, want, true, agent.navigation_layers)
		if path.is_empty():
			continue
		var p: Vector3 = path[path.size() - 1]
		var length := 0.0
		for k in range(1, path.size()):
			length += path[k - 1].distance_to(path[k])
		if _flat_distance(p, guard_post) < Cfg.PATROL_RADIUS.x * 0.6 or length > r * 1.6:
			continue
		var close := false
		for q in _route:
			close = close or _flat_distance(p, q) < 2.5
		if not close:
			_route.append(p)


func _navmesh_ready() -> bool:
	var main := get_tree().current_scene
	if main and main.has_method("navmesh_ready"):
		return main.navmesh_ready()
	return NavigationServer3D.map_get_iteration_id(get_world_3d().navigation_map) > 0


# SUSPICIOUS: turn to the noise, walk there, look round, calm down.
func _investigate_move(delta: float) -> void:
	var to := _investigate_pos - global_position
	to.y = 0.0
	if _mode_time < Cfg.INVESTIGATE_TURN and _look_time == 0.0:
		_stop()
		_turn_towards(to.normalized(), delta)
		return
	if _look_time > 0.0 or _arrived(_investigate_pos) or _mode_time > 20.0:
		_stop()
		if _look_time == 0.0:
			_look_yaw = rotation.y
		_look_time += delta
		_look_around(delta)
		if _look_time > Cfg.LOOK_AROUND_TIME:
			_calm_down()
		return
	_walk_to(_investigate_pos, delta, Cfg.INVESTIGATE_SPEED)
	if not _wants_move and _mode_time > Cfg.INVESTIGATE_TURN + 0.5:
		_look_time = 0.001  # as close as it gets: look round from here


# SEARCH: the last known position, then nearby cover, looking round at each;
# back to UNAWARE after SEARCH_TIME s.
func _search_move(delta: float) -> void:
	if _mode_time > Cfg.SEARCH_TIME:
		_calm_down()
		return
	if _wait_left > 0.0:
		_stop()
		_wait_left -= delta
		_look_around(delta)
		return
	if _goal == Vector3.INF:
		if _search_points.is_empty():
			_stop()
			_look_around(delta)
			return
		_goal = _search_points.pop_front()
	_walk_to(_goal, delta, Cfg.SEARCH_SPEED)
	if _arrived(_goal) or (not _wants_move and _mode_time > 1.0):
		_goal = Vector3.INF
		_wait_left = Cfg.SEARCH_LOOK
		_look_time = 0.0
		_look_yaw = rotation.y


# Standing, turning the head and body slowly left and right.
func _look_around(delta: float) -> void:
	_look_time += delta
	var yaw := _look_yaw + sin(_look_time * 1.4) * 1.1
	_turn_towards(Vector3(-sin(yaw), 0.0, -cos(yaw)), delta)


# --- Missions: pushers and the Commander -----------------------------------------

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
		_strafe = _seen_time < 1.5 and _flat_distance_to_player() < Cfg.STRAFE_RANGE
		_walk_to(push_spot, delta, Cfg.STRAFE_SPEED if _strafe else Mission.PUSH_SPEED)


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
	_strafe = false
	if not _player_alive():
		_stop()
		return
	_perceive(delta)
	if flee_to != Vector3.INF:
		_flee_move(delta)
		return
	if push_spot != Vector3.INF and awareness == Aware.COMBAT:
		_push_move(delta)
		return
	match awareness:
		Aware.UNAWARE:
			_patrol_move(delta)
			return
		Aware.SUSPICIOUS:
			_investigate_move(delta)
			return
		Aware.SEARCH:
			_search_move(delta)
			return
	if _player_in_range(stats.attack_range):
		_set_state(State.ATTACK)  # rifle jab, as in enemy.gd
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
			_face_player(delta)
			_find_cover()
		Tac.MOVE:
			if _arrived(cover.pos):
				_start_hide()
			elif _tac_time > 12.0 or _player_too_close():
				_go(Tac.FIND)
			else:
				_strafe = _should_strafe(cover.pos, delta)
				_walk_to(cover.pos, delta, Cfg.STRAFE_SPEED if _strafe else Cfg.RUN_SPEED)
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
				_strafe = true  # side-step out, rifle on the player
				_walk_to(cover.peek, delta, Cfg.PEEK_SPEED)
				if _tac_time > 5.0:
					_go(Tac.RETURN)
		Tac.RETURN:
			if _arrived(cover.pos):
				_start_hide()
			else:
				_strafe = _seen_time < 1.5
				_walk_to(cover.pos, delta, Cfg.STRAFE_SPEED if _strafe else Cfg.RUN_SPEED)
				if _check_timer <= 0.0:
					_check_timer = Cfg.FLANK_CHECK
					if _tac_time > 5.0 or _player_too_close():
						_go(Tac.FIND)
		Tac.OPEN:
			# enemy.gd's soldier: a firing spot in the open (bursts via AIM).
			_strafe = _seen_time < 1.5 and _flat_distance_to_player() < Cfg.STRAFE_RANGE
			super._soldier_move(delta)
			if _tac_time > Cfg.SEARCH_RETRY and not points.is_empty():
				_go(Tac.FIND)


# Moving to `target` in combat: face the player (strafe / back off) when they
# are close, in view, and off to the side of the way it goes; decided every
# half second so it doesn't flip.
func _should_strafe(target: Vector3, delta: float) -> bool:
	_strafe_timer -= delta
	if _strafe_timer > 0.0:
		return _strafe_was
	_strafe_timer = 0.5
	_strafe_was = false
	if _seen_time < 1.5 and _flat_distance_to_player() < Cfg.STRAFE_RANGE:
		var way := agent.get_next_path_position() - global_position
		if way.length_squared() < 0.01:
			way = target - global_position
		way.y = 0.0
		var to := _player.global_position - global_position
		to.y = 0.0
		_strafe_was = way.normalized().dot(to.normalized()) < cos(deg_to_rad(Cfg.STRAFE_ANGLE))
	return _strafe_was


func _go(t: Tac) -> void:
	tac = t
	_tac_time = 0.0
	_check_timer = 0.0
	_strafe_timer = 0.0
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


# --- Turning --------------------------------------------------------------------

# Turns at most TURN_RATE degrees/s, easing in at the end (no snapping).
# While strafing it keeps facing the player whichever way it walks. Called
# twice in a physics frame (walk, then face the player), the last one wins:
# one step a frame.
func _turn_towards(dir: Vector3, delta: float) -> void:
	var frame := Engine.get_physics_frames()
	if frame != _turn_frame:
		_turn_frame = frame
		_turn_from = rotation.y
	if _strafe and _player:
		dir = _player.global_position - global_position
		dir.y = 0.0
		dir = dir.normalized()
	if dir.length_squared() < 0.001:
		return
	var diff := wrapf(atan2(-dir.x, -dir.z) - _turn_from, -PI, PI)
	var rate := minf(deg_to_rad(Cfg.TURN_RATE), absf(diff) * Cfg.TURN_GAIN)
	rotation.y = _turn_from + signf(diff) * minf(absf(diff), rate * delta)


# --- Animation --------------------------------------------------------------------

## The tree every soldier shares (the playback state lives in each
## AnimationTree):
##   loco        BlendSpace2D by velocity (x = right, y = forward; 1 = walking,
##               2 = running): centre = "stand" (BlendSpace1D relaxed .. aim),
##               walk, walk_back, walk_left, walk_right, run
##   loco_speed  TimeScale (ground speed / the clips' speed)
##   action      Transition: loco | crouch | aim | jab | death
##   fire        OneShot: the firing clip on each shot
##   hit         OneShot: the hit reaction, blended out after HIT_REACT_TIME
static func _tree_root() -> AnimationNodeBlendTree:
	if _shared_tree:
		return _shared_tree
	var bt := AnimationNodeBlendTree.new()
	var stand := AnimationNodeBlendSpace1D.new()
	stand.add_blend_point(_clip("relaxed"), 0.0, -1, &"relaxed")
	stand.add_blend_point(_clip("aim"), 1.0, -1, &"aim")
	stand.min_space = 0.0
	stand.max_space = 1.0
	var loco := AnimationNodeBlendSpace2D.new()
	loco.min_space = Vector2(-1.0, -1.0)
	loco.max_space = Vector2(1.0, 2.0)
	loco.add_blend_point(stand, Vector2.ZERO, -1, &"stand")
	loco.add_blend_point(_clip("walk"), Vector2(0.0, 1.0), -1, &"walk")
	loco.add_blend_point(_clip("walk_back"), Vector2(0.0, -1.0), -1, &"walk_back")
	loco.add_blend_point(_clip("walk_left"), Vector2(-1.0, 0.0), -1, &"walk_left")
	loco.add_blend_point(_clip("walk_right"), Vector2(1.0, 0.0), -1, &"walk_right")
	loco.add_blend_point(_clip("run"), Vector2(0.0, 2.0), -1, &"run")
	bt.add_node(&"loco", loco)
	bt.add_node(&"loco_speed", AnimationNodeTimeScale.new())
	bt.connect_node(&"loco_speed", 0, &"loco")
	bt.add_node(&"crouch", _clip("crouch"))
	bt.add_node(&"aim", _clip("aim"))
	bt.add_node(&"jab_clip", _clip("shoot"))
	bt.add_node(&"jab_speed", AnimationNodeTimeScale.new())
	bt.add_node(&"jab_seek", AnimationNodeTimeSeek.new())
	bt.connect_node(&"jab_speed", 0, &"jab_clip")
	bt.connect_node(&"jab_seek", 0, &"jab_speed")
	bt.add_node(&"death_clip", _clip("death"))
	bt.add_node(&"death_speed", AnimationNodeTimeScale.new())
	bt.connect_node(&"death_speed", 0, &"death_clip")
	var action := AnimationNodeTransition.new()
	action.xfade_time = 0.2
	for n: String in ["loco", "crouch", "aim", "jab", "death"]:
		action.add_input(n)
	bt.add_node(&"action", action)
	bt.connect_node(&"action", 0, &"loco_speed")
	bt.connect_node(&"action", 1, &"crouch")
	bt.connect_node(&"action", 2, &"aim")
	bt.connect_node(&"action", 3, &"jab_seek")
	bt.connect_node(&"action", 4, &"death_speed")
	var fire := AnimationNodeOneShot.new()
	fire.fadein_time = 0.02
	fire.fadeout_time = 0.08
	bt.add_node(&"fire", fire)
	bt.add_node(&"fire_clip", _clip("shoot"))
	bt.connect_node(&"fire", 0, &"action")
	bt.connect_node(&"fire", 1, &"fire_clip")
	var hit := AnimationNodeOneShot.new()
	hit.fadein_time = 0.08
	hit.fadeout_time = 0.3
	bt.add_node(&"hit", hit)
	bt.add_node(&"hit_clip", _clip("hit"))
	bt.add_node(&"hit_speed", AnimationNodeTimeScale.new())
	bt.connect_node(&"hit_speed", 0, &"hit_clip")
	bt.connect_node(&"hit", 0, &"fire")
	bt.connect_node(&"hit", 1, &"hit_speed")
	bt.connect_node(&"output", 0, &"hit")
	_shared_tree = bt
	return bt


static func _clip(anim_name: String) -> AnimationNodeAnimation:
	var a := AnimationNodeAnimation.new()
	a.animation = anim_name
	return a


# The AnimationPlayer from enemy.gd keeps the clips but stops driving the
# skeleton; the tree does.
func _setup_tree() -> void:
	var lib := Types.anim_library(kind)
	if not lib.has_animation("walk_left"):
		return  # an old library: enemy.gd's AnimationPlayer keeps playing
	if _clip_speeds.is_empty():
		var clips := {"walk": "walk", "back": "walk_back", "left": "walk_left", "right": "walk_right", "run": "run"}
		for k: String in clips:
			var clip: String = clips[k]
			_clip_speeds[k] = maxf(lib.get_animation(clip).get_meta("ground_speed", 1.0), 0.1)
	anim.stop()
	anim.active = false
	_tree = AnimationTree.new()
	_tree.name = "AnimationTree"
	$Model.add_child(_tree)
	_tree.root_node = _tree.get_path_to(_skel.get_parent())
	_tree.add_animation_library(&"", lib)
	_tree.tree_root = _tree_root()
	_tree.set(P_LOCO_SPEED, 1.0)
	_tree.set(P_JAB_SPEED, stats.anim_speed.attack)
	_tree.set(P_DEATH_SPEED, stats.anim_speed.death)
	_tree.set(P_HIT_SPEED, Cfg.HIT_REACT_SPEED)
	_stance = 1.0 if awareness == Aware.COMBAT else 0.0
	_tree.set(P_STANCE, _stance)
	_tree.active = true


## The clip blend the tree is in ("loco", "crouch", "aim", "jab", "death"; for tests).
func anim_action() -> String:
	return _action


## The locomotion blend position (x = right, y = forward) and its playback speed (for tests).
func anim_blend() -> Vector3:
	return Vector3(_blend.x, _blend.y, _anim_scale)


# Every frame: the clip blend for the state, and the locomotion blend from
# the velocity in the soldier's own frame (x = its right, y = forward).
func _update_anim(delta: float) -> void:
	if _tree == null:
		return
	var action := "loco"
	match state:
		State.DEAD:
			action = "death"
		State.ATTACK:
			action = "jab"
		State.AIM:
			action = "aim"
		_:
			if wants_crouch():
				action = "crouch"
	if action != _action:
		_action = action
		_tree.set(P_ACTION, action)
	if _hit_left > 0.0:
		_hit_left -= delta
		if _hit_left <= 0.0:
			_tree.set(P_HIT, AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
	var aiming := awareness == Aware.COMBAT or awareness == Aware.SEARCH
	_stance = move_toward(_stance, 1.0 if aiming else 0.0, Cfg.STANCE_SMOOTH * delta)
	_tree.set(P_STANCE, _stance)
	var yaw_rate := wrapf(rotation.y - _prev_yaw, -PI, PI) / maxf(delta, 0.0001)
	_prev_yaw = rotation.y
	_yaw_rate = lerpf(_yaw_rate, yaw_rate, clampf(10.0 * delta, 0.0, 1.0))
	var ms: float = stats.model_scale
	var v := Vector3(velocity.x, 0.0, velocity.z) if state == State.CHASE else Vector3.ZERO
	var local := Vector2(v.dot(global_basis.x), v.dot(-global_basis.z))
	var speed := local.length()
	var target := Vector2.ZERO
	var scale := 1.0
	if speed > 0.15:
		var dir := local / speed
		if dir.y > 0.7 and speed > _clip_speeds.walk * ms * Cfg.RUN_FORWARD:
			target = Vector2(dir.x, 2.0 * dir.y)
			scale = speed / (_clip_speeds.run * ms)
		else:
			var along: float = _clip_speeds.walk if dir.y >= 0.0 else _clip_speeds.back
			var side: float = _clip_speeds.right if dir.x >= 0.0 else _clip_speeds.left
			var ref := (along * dir.y * dir.y + side * dir.x * dir.x) * ms
			target = dir * minf(speed / (0.5 * ref), 1.0)
			scale = speed / ref
	elif absf(_yaw_rate) > 0.8 and state == State.CHASE and not wants_crouch():
		# Turning on the spot: small side steps so the feet move with it.
		target = Vector2(-signf(_yaw_rate) * minf(absf(_yaw_rate) * Cfg.TURN_STEP, 0.6), 0.0)
	var k := clampf(Cfg.BLEND_SMOOTH * delta, 0.0, 1.0)
	_blend = _blend.lerp(target, k)
	_anim_scale = lerpf(_anim_scale, clampf(scale, Cfg.ANIM_SCALE.x, Cfg.ANIM_SCALE.y), k)
	_tree.set(P_LOCO, _blend)
	_tree.set(P_LOCO_SPEED, _anim_scale)


# enemy.gd's clip per state, through the tree (only what the action blend
# in _update_anim doesn't cover).
func _play_state_anim(new_state: State) -> void:
	if _tree == null:
		super._play_state_anim(new_state)
		return
	match new_state:
		State.ATTACK:
			var rate: float = stats.anim_speed.attack
			var strike: float = anim.get_animation(stats.anims.attack).get_meta("hit_time", 0.0)
			_tree.set(P_JAB_SPEED, rate)
			_tree.set(P_JAB_SEEK, maxf(strike - stats.attack_hit_time * rate, 0.0))
		State.DEAD:
			var quick := 1.25 if _last_headshot or _last_hit_force > 2.5 else 1.0
			_tree.set(P_DEATH_SPEED, stats.anim_speed.death * quick)
			_tree.set(P_HIT, AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
			_hit_left = 0.0
	_update_anim(0.0)


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
	if _tree == null:
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
	_perceive(delta)
	var tgt := _burst_target()
	var to := tgt.global_position - global_position
	to.y = 0.0
	_turn_towards(to.normalized(), delta)
	if not _player_alive() or (tgt != _player and not tgt.call("is_targetable")):
		_end_burst()
		return
	if _state_time < Cfg.AIM_TIME:
		return
	if _tree == null and not anim.is_playing():
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
	if _tree:
		_tree.set(P_FIRE, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
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
	if state == State.DEAD:
		return
	raise_alert()
	if _tree:
		_tree.set(P_HIT, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		_hit_left = Cfg.HIT_REACT_TIME
	# Shot while out: duck back behind the cover.
	if not cover.is_empty() and tac == Tac.PEEK:
		_go(Tac.RETURN)


func _die() -> void:
	super._die()
	_release_cover()
	_muzzle_flash.visible = false
	_radio_left = 0.0


func relocate(pos: Vector3) -> void:
	super.relocate(pos)
	_go(Tac.FIND)
