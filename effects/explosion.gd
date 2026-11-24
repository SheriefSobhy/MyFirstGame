extends Node3D
## Grenade explosion visuals and sound, built in code: a fireball, smoke,
## flying sparks, a short bright light flash and a dark scorch mark on the
## ground. Removes itself when done. Damage is handled by grenade.gd.
##
## Usage: add to the scene, then call setup(position, ground_normal_or_zero).

const SOUND := preload("res://assets/sounds/explosion.ogg")
const LIFETIME := 2.6          # seconds until the node frees itself (smoke is longest)
const LIGHT_ENERGY := 7.0
const LIGHT_TIME := 0.35       # seconds for the flash to fade out
const SCORCH_TIME := 20.0      # seconds the scorch mark stays before fading

## false while prewarming shaders in main.gd (no sound, nothing left behind).
var with_sound := true

var _time := 0.0
var _light: OmniLight3D
var _scorch: MeshInstance3D

static var _soft_tex: GradientTexture2D


func _ready() -> void:
	_add_fireball()
	_add_smoke()
	_add_sparks()
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.62, 0.3)
	_light.light_energy = LIGHT_ENERGY
	_light.omni_range = 12.0
	_light.shadow_enabled = false
	_light.position = Vector3(0, 0.5, 0)
	add_child(_light)


## pos: where it went off. ground_normal: surface below it (ZERO = in the air,
## no scorch mark).
func setup(pos: Vector3, ground_normal := Vector3.ZERO, ground_point := Vector3.ZERO) -> void:
	global_position = pos
	for p in find_children("*", "CPUParticles3D", false, false):
		(p as CPUParticles3D).restart()
	if with_sound:
		var sound := AudioStreamPlayer3D.new()
		sound.stream = SOUND
		sound.unit_size = 12.0
		sound.max_db = 6.0
		sound.volume_db = 4.0
		sound.pitch_scale = randf_range(0.92, 1.05)
		add_child(sound)
		sound.play()
	if ground_normal != Vector3.ZERO and with_sound:
		_add_scorch(ground_point, ground_normal)


func _process(delta: float) -> void:
	_time += delta
	_light.light_energy = LIGHT_ENERGY * maxf(1.0 - _time / LIGHT_TIME, 0.0)
	_light.visible = _light.light_energy > 0.0
	if _time >= LIFETIME:
		set_process(false)
		if _scorch == null:
			queue_free()
		else:
			for c in get_children():
				if c != _scorch:
					c.queue_free()
			var tween := create_tween()
			tween.tween_interval(SCORCH_TIME)
			tween.tween_property(_scorch, "transparency", 1.0, 2.0)
			tween.tween_callback(queue_free)


# A soft round dot texture shared by every particle here.
static func _soft_texture() -> GradientTexture2D:
	if _soft_tex == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		_soft_tex = GradientTexture2D.new()
		_soft_tex.gradient = g
		_soft_tex.fill = GradientTexture2D.FILL_RADIAL
		_soft_tex.fill_from = Vector2(0.5, 0.5)
		_soft_tex.fill_to = Vector2(0.5, 0.0)
		_soft_tex.width = 64
		_soft_tex.height = 64
	return _soft_tex


func _particle_material(additive: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	m.vertex_color_use_as_albedo = true
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.albedo_texture = _soft_texture()
	return m


func _emitter(amount: int, lifetime: float, size: float, additive: bool) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.emitting = false
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = amount
	p.lifetime = lifetime
	p.local_coords = false
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	quad.material = _particle_material(additive)
	p.mesh = quad
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.direction = Vector3.UP
	p.spread = 180.0
	add_child(p)
	return p


func _ramp(colors: Array, offsets: Array) -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets)
	g.colors = PackedColorArray(colors)
	return g


func _grow(from: float, to: float) -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0, from))
	c.add_point(Vector2(1, to))
	return c


func _add_fireball() -> void:
	var p := _emitter(16, 0.55, 1.4, true)
	p.emission_sphere_radius = 0.4
	p.position.y = 0.4
	p.initial_velocity_min = 1.5
	p.initial_velocity_max = 5.0
	p.damping_min = 6.0
	p.damping_max = 9.0
	p.gravity = Vector3(0, 2.0, 0)
	p.scale_amount_min = 0.8
	p.scale_amount_max = 1.5
	p.scale_amount_curve = _grow(0.6, 1.6)
	p.color_ramp = _ramp([Color(3.0, 2.6, 1.6, 1), Color(2.2, 0.9, 0.2, 0.9), Color(0.4, 0.1, 0.02, 0)], [0.0, 0.35, 1.0])


func _add_smoke() -> void:
	var p := _emitter(12, 2.4, 1.8, false)
	p.emission_sphere_radius = 0.6
	p.position.y = 0.6
	p.initial_velocity_min = 0.8
	p.initial_velocity_max = 2.5
	p.damping_min = 1.0
	p.damping_max = 2.0
	p.gravity = Vector3(0, 0.9, 0)
	p.scale_amount_min = 0.8
	p.scale_amount_max = 1.4
	p.scale_amount_curve = _grow(0.5, 2.2)
	p.color_ramp = _ramp([Color(0.2, 0.18, 0.16, 0.0), Color(0.22, 0.2, 0.18, 0.7), Color(0.35, 0.34, 0.33, 0.0)], [0.0, 0.12, 1.0])


func _add_sparks() -> void:
	var p := _emitter(26, 0.9, 0.06, true)
	p.emission_sphere_radius = 0.2
	p.position.y = 0.3
	p.initial_velocity_min = 7.0
	p.initial_velocity_max = 14.0
	p.gravity = Vector3(0, -9.8, 0)
	p.color_ramp = _ramp([Color(3.0, 2.2, 1.0, 1), Color(2.0, 0.7, 0.15, 1), Color(0.5, 0.1, 0.0, 0)], [0.0, 0.5, 1.0])


# A dark, soft-edged quad on the ground. Mix-blended (not multiply), which
# keeps shadowed floor from turning black in the Compatibility renderer.
func _add_scorch(point: Vector3, normal: Vector3) -> void:
	_scorch = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(2.6, 2.6)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.03, 0.025, 0.02, 0.75)
	m.albedo_texture = _soft_texture()
	quad.material = m
	_scorch.mesh = quad
	_scorch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_scorch)
	_scorch.global_position = point + normal * 0.015
	var up := Vector3.UP if absf(normal.y) < 0.99 else Vector3.FORWARD
	_scorch.look_at(_scorch.global_position - normal, up)
	_scorch.rotate_object_local(Vector3.BACK, randf() * TAU)
