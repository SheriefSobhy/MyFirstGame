extends Node3D
## Extraction missions: the pick-up helicopter (missions/extraction.gd).
## Model assets/models/vehicles/helicopter.glb (CC0, OpenGameArt "Helicopter"
## by z3eus; tools/blender/build_helicopter.py): meshes "body" and "rotor"
## (origin on the hub). No collision: boarding is a distance check.
##
##  AWAY      hidden
##  APPROACH  arrive(t): flies in from HELI_FROM (relative to the landing
##            spot) to a hover above it, then descends, touching down
##            exactly t s later; banks into the turn, dust kicks up near the
##            ground
##  LANDED    on the ground, rotor turning
##  LIFTOFF   lift_off(): climbs away (cosmetic, after boarding)
## The rotor spins all the time it's visible (a faint blurred disc over it
## at speed); the rotor sound (synth_sounds.gd rotor_loop, no file) is a
## positional loop, so it's heard coming.

const M := preload("res://missions/missions_config.gd")
const Synth := preload("res://effects/synth_sounds.gd")
const Explosion := preload("res://effects/explosion.gd")
const MODEL := preload("res://assets/models/vehicles/helicopter.glb")
const ROTOR_SPEED := 26.0       # rad/s
const HOVER_HEIGHT := 12.0      # m above the spot before the descent
const DESCENT_SHARE := 0.35     # share of the approach spent descending

enum State { AWAY, APPROACH, LANDED, LIFTOFF }

var state := State.AWAY
## Where it lands, and its heading there (degrees, 0 = nose to -Z).
var spot := Vector3.ZERO
var yaw := 0.0
var rotor: Node3D
var sound: AudioStreamPlayer3D
## 0..1 along the approach. driven = the mission sets it every frame
## (extraction.gd: it only moves on while the LZ is held) instead of time.
var driven := false
var progress := 0.0
var _duration := 1.0
var _from := Vector3.ZERO
var _disc: MeshInstance3D
var _dust: CPUParticles3D
var _lift_time := 0.0
var _heading := 0.0


func _ready() -> void:
	var model: Node3D = MODEL.instantiate()
	model.name = "Model"
	add_child(model)
	rotor = model.find_child("rotor", true, false)
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_disc = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 4.5
	cyl.bottom_radius = 4.5
	cyl.height = 0.02
	cyl.radial_segments = 24
	cyl.rings = 1
	_disc.mesh = cyl
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.05, 0.05, 0.05, 0.22)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_disc.material_override = m
	_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if rotor:
		rotor.add_child(_disc)
		_disc.position.y = 1.0
	sound = AudioStreamPlayer3D.new()
	sound.stream = Synth.rotor_loop()
	sound.unit_size = 22.0
	sound.max_distance = 160.0
	sound.volume_db = 2.0
	sound.position.y = 2.5
	add_child(sound)
	_dust = CPUParticles3D.new()
	_dust.amount = 18
	_dust.lifetime = 1.4
	_dust.local_coords = false
	_dust.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	_dust.emission_ring_axis = Vector3.UP
	_dust.emission_ring_radius = 2.5
	_dust.emission_ring_inner_radius = 1.0
	_dust.emission_ring_height = 0.1
	_dust.direction = Vector3(1, 0.2, 0)
	_dust.spread = 180.0
	_dust.flatness = 0.85
	_dust.initial_velocity_min = 4.0
	_dust.initial_velocity_max = 7.0
	_dust.gravity = Vector3.ZERO
	_dust.damping_min = 3.0
	_dust.damping_max = 4.0
	var q := QuadMesh.new()
	q.size = Vector2(1.6, 1.6)
	var dm := StandardMaterial3D.new()
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.vertex_color_use_as_albedo = true
	dm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	dm.albedo_texture = Explosion._soft_texture()
	q.material = dm
	_dust.mesh = q
	var g := Gradient.new()
	g.colors = PackedColorArray([Color(0.55, 0.5, 0.42, 0.35), Color(0.55, 0.5, 0.42, 0.0)])
	_dust.color_ramp = g
	_dust.emitting = false
	_dust.top_level = true
	add_child(_dust)
	visible = false
	set_process(false)


## Fly in and touch down at `at` (heading `heading` degrees) `seconds` from now.
func arrive(at: Vector3, heading: float, seconds: float) -> void:
	spot = at
	yaw = heading
	_duration = maxf(seconds, 0.5)
	_from = at + M.HELI_FROM
	progress = 0.0
	state = State.APPROACH
	visible = true
	global_position = _from
	_heading = atan2(-(at.x - _from.x), -(at.z - _from.z))
	rotation = Vector3(0.0, _heading, 0.0)
	sound.play()
	set_process(true)


## Seconds until it touches down (0 once landed).
func time_to_land() -> float:
	if state != State.APPROACH:
		return 0.0 if state == State.LANDED else INF
	return (1.0 - progress) * _duration


func lift_off() -> void:
	if state == State.LIFTOFF:
		return
	state = State.LIFTOFF
	_lift_time = 0.0
	set_process(true)


func _process(delta: float) -> void:
	if rotor:
		rotor.rotate_y(ROTOR_SPEED * delta)
	match state:
		State.APPROACH:
			if not driven:
				progress = minf(progress + delta / _duration, 1.0)
			_fly()
			if progress >= 1.0:
				state = State.LANDED
				global_position = spot
				rotation = Vector3(0.0, deg_to_rad(yaw), 0.0)
		State.LANDED:
			_dust.global_position = spot
			_dust.emitting = true
		State.LIFTOFF:
			_lift_time += delta
			var k := _lift_time / M.HELI_LIFT
			global_position = spot + Vector3(0.0, 30.0 * k * k + 2.0 * k, 0.0) - global_basis.z * 40.0 * k * k
			rotation.x = -0.15 * clampf(k * 3.0, 0.0, 1.0)
			_dust.emitting = _lift_time < 1.5
			if _lift_time >= M.HELI_LIFT:
				visible = false
				sound.stop()
				set_process(false)


# The approach: a curve to the hover point (easing out), then straight down
# while turning to the landing heading.
func _fly() -> void:
	var hover := spot + Vector3.UP * HOVER_HEIGHT
	var cruise := 1.0 - DESCENT_SHARE
	var pos: Vector3
	var bank := 0.0
	var pitch := 0.0
	if progress < cruise:
		var k := progress / cruise
		var e := 1.0 - pow(1.0 - k, 2.0)  # ease out: slows into the hover
		pos = _from.lerp(hover, e)
		pos.y += sin(k * PI) * 6.0
		pitch = -0.18 * (1.0 - e)        # nose down while fast
		bank = 0.12 * sin(k * PI)
	else:
		var k := (progress - cruise) / DESCENT_SHARE
		var e := k * k * (3.0 - 2.0 * k)
		pos = hover.lerp(spot, e)
		_heading = lerp_angle(_heading, deg_to_rad(yaw), 0.05)
		if k > 0.95:
			_heading = deg_to_rad(yaw)
	global_position = pos
	rotation = Vector3(pitch, _heading, bank)
	var height := pos.y - spot.y
	_dust.global_position = spot
	_dust.emitting = height < 7.0
