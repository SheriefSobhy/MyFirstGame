extends Node3D
## The mood of a map on top of its baked light (numbers: atmosphere_config.gd):
## colour grade, fog, floating dust, additive light shafts, reflection probes,
## flickering lamps and emergency lights. Created by main.gd for the three
## maps (not the Training Arena); main.gd calls apply_quality() with the
## effective graphics level:
##   Low     baked light + colour grade only (the grade is always on)
##   Medium  + fog (main.gd), dust, flickering lamps
##   High    + reflection probes, light shafts, glow (main.gd), emergency lights
## Everything is cheap on purpose (phones): a few hundred additive pixels of
## shafts, ~100 dust quads, probes captured once, a handful of lights.

const Config := preload("res://atmosphere_config.gd")
const SHAFT_SHADER := preload("res://effects/light_shaft.gdshader")
## Everything except the weapon layer (the first-person gun), like the sun.
const WORLD_MASK := 1048573

var map_id := ""
var _cfg: Dictionary
var _env: Environment
var _sun: DirectionalLight3D
var _quality := 2
var _time := 0.0
var _dust: CPUParticles3D
var _shafts: Array[MeshInstance3D] = []
var _probes: Array[ReflectionProbe] = []
var _flickers: Array[Dictionary] = []
var _beacons: Array[Dictionary] = []


## Adds an Atmosphere to `main` when its map has one; null for other maps.
static func attach(main: Node3D, id: String, environment: Environment, sun: DirectionalLight3D) -> Node3D:
	if not Config.has_map(id):
		return null
	var a := new()
	a.name = "Atmosphere"
	a.map_id = id
	a._env = environment
	a._sun = sun
	main.add_child(a)
	return a


func _ready() -> void:
	_cfg = Config.MAPS[map_id]
	_apply_grade(_cfg.grade)
	_apply_fog(_cfg.fog)
	if _cfg.has("dust"):
		_make_dust(_cfg.dust)
	for s: Dictionary in _cfg.get("shafts", []):
		_make_shaft(s)
	for p: Dictionary in _cfg.get("probes", []):
		_make_probe(p)
	for f: Dictionary in _cfg.get("flicker", []):
		_make_flicker(f)
	for l: Dictionary in _cfg.get("lights", []):
		_make_lamp(l)
	for b: Dictionary in _cfg.get("beacons", []):
		_make_beacon(b)
	apply_quality(Settings.effective_quality())


# --- Colour grade and fog -----------------------------------------------------

func _apply_grade(g: Dictionary) -> void:
	var e := _env
	e.tonemap_mode = g.tonemap
	e.tonemap_white = g.white
	e.tonemap_exposure = g.exposure
	e.adjustment_enabled = true
	e.adjustment_brightness = g.brightness
	e.adjustment_contrast = g.contrast
	e.adjustment_saturation = g.saturation
	# A per-channel curve: tints the shadows and the highlights.
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	grad.colors = PackedColorArray([g.shadows, g.mids, g.highs])
	var lut := GradientTexture1D.new()
	lut.gradient = grad
	lut.width = 64
	e.adjustment_color_correction = lut
	e.glow_intensity = g.glow_intensity
	e.glow_bloom = g.glow_bloom
	e.glow_hdr_threshold = g.glow_threshold


func _apply_fog(f: Dictionary) -> void:
	_env.fog_light_color = f.color
	_env.fog_density = f.density
	_env.fog_sky_affect = f.sky_affect
	_env.fog_sun_scatter = f.sun_scatter


# --- Dust -------------------------------------------------------------------------

func _make_dust(d: Dictionary) -> void:
	var dot := Gradient.new()
	dot.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var tex := GradientTexture2D.new()
	tex.gradient = dot
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 32
	tex.height = 32
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = tex
	mat.disable_fog = true
	mat.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
	mat.distance_fade_min_distance = 0.4
	mat.distance_fade_max_distance = 1.6
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * d.size
	quad.material = mat
	# Fade in, hang there, fade out.
	var ramp := Gradient.new()
	var c: Color = d.color
	ramp.offsets = PackedFloat32Array([0.0, 0.2, 0.8, 1.0])
	ramp.colors = PackedColorArray([Color(c, 0.0), c, c, Color(c, 0.0)])
	_dust = CPUParticles3D.new()
	_dust.name = "Dust"
	_dust.mesh = quad
	_dust.amount = d.amount
	_dust.lifetime = d.lifetime
	_dust.preprocess = d.lifetime
	_dust.local_coords = false
	_dust.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_dust.emission_box_extents = (d.box as Vector3) * 0.5
	_dust.direction = Vector3(0.4, 0.1, 0.2)
	_dust.spread = 180.0
	_dust.gravity = Vector3(0.0, -0.01, 0.0)
	_dust.initial_velocity_min = 0.03
	_dust.initial_velocity_max = 0.16
	_dust.scale_amount_min = 0.5
	_dust.scale_amount_max = 1.6
	_dust.color_ramp = ramp
	_dust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dust.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(_dust)


# --- Light shafts -----------------------------------------------------------------

func _make_shaft(s: Dictionary) -> void:
	var length: float = s.len if s.has("len") else 8.0
	var start: Vector3 = s.pos
	var dir := Vector3.DOWN
	if s.get("dir", "") == "sun" and _sun:
		dir = -_sun.global_basis.z
	elif s.has("to"):
		var d: Vector3 = (s.to as Vector3) - start
		length = d.length()
		dir = d / length
	var cyl := CylinderMesh.new()
	cyl.top_radius = s.r0
	cyl.bottom_radius = s.r1
	cyl.height = length
	cyl.radial_segments = 14
	cyl.rings = 1
	cyl.cap_top = false
	cyl.cap_bottom = false
	var mat := ShaderMaterial.new()
	mat.shader = SHAFT_SHADER
	mat.set_shader_parameter("beam_color", s.color)
	mat.set_shader_parameter("intensity", s.intensity)
	mat.set_shader_parameter("fade_in", s.get("fade_in", 0.04 if s.kind == "cone" else 0.15))
	mat.set_shader_parameter("fade_out", s.get("fade_out", 0.9 if s.kind == "cone" else 0.5))
	cyl.material = mat
	var mi := MeshInstance3D.new()
	mi.name = "Shaft%d" % _shafts.size()
	mi.mesh = cyl
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# The cylinder's axis is Y with its top (radius r0) at +Y: point +Y back
	# at the source.
	var y := -dir
	var x := y.cross(Vector3.FORWARD if absf(y.dot(Vector3.UP)) > 0.95 else Vector3.UP).normalized()
	mi.transform = Transform3D(Basis(x, y, x.cross(y)), start + dir * length * 0.5)
	add_child(mi)
	_shafts.append(mi)


# --- Reflection probes -------------------------------------------------------------

func _make_probe(p: Dictionary) -> void:
	var probe := ReflectionProbe.new()
	probe.name = "Probe%d" % _probes.size()
	probe.position = p.pos
	probe.size = p.size
	probe.interior = p.interior
	probe.box_projection = p.interior
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.cull_mask = WORLD_MASK
	probe.intensity = 1.0
	add_child(probe)
	_probes.append(probe)


# --- Flickering lamps and emergency lights ------------------------------------------

func _make_flicker(f: Dictionary) -> void:
	var lamp := get_parent().find_child(f.lamp, true, false) as Light3D
	if lamp == null or lamp.light_bake_mode == Light3D.BAKE_STATIC:
		return
	_add_flicker(lamp, get_parent().find_child(f.tube, true, false) as MeshInstance3D, f.strong)


func _make_lamp(l: Dictionary) -> void:
	var lamp := OmniLight3D.new()
	lamp.name = l.name
	lamp.position = l.pos
	lamp.light_color = l.color
	lamp.light_energy = l.energy
	lamp.omni_range = l.range
	lamp.omni_attenuation = 1.2
	lamp.shadow_enabled = false
	lamp.light_cull_mask = WORLD_MASK
	add_child(lamp)
	_add_flicker(lamp, null, l.strong)


func _add_flicker(lamp: Light3D, glow: MeshInstance3D, strong: bool) -> void:
	var entry := {"light": lamp, "base": lamp.light_energy, "strong": strong, "t": randf_range(0.5, 3.0),
			"burst": 0, "mult": 1.0, "mat": null, "emission": 1.0}
	if glow:
		var src: Material = glow.material_override
		if src == null and glow.mesh:
			src = glow.mesh.surface_get_material(0) if glow.mesh.get_surface_count() > 0 else null
			if src == null:
				src = glow.mesh.get("material")
		if src is StandardMaterial3D:
			var own := (src as StandardMaterial3D).duplicate() as StandardMaterial3D
			glow.material_override = own  # this lamp's glow only
			entry.mat = own
			entry.emission = own.emission_energy_multiplier
	_flickers.append(entry)


func _make_beacon(b: Dictionary) -> void:
	var lamp := OmniLight3D.new()
	lamp.name = b.name
	lamp.position = b.pos
	lamp.light_color = b.color
	lamp.light_energy = 0.0
	lamp.omni_range = b.range
	lamp.shadow_enabled = false
	lamp.light_cull_mask = WORLD_MASK
	add_child(lamp)
	var bulb := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.1
	sphere.height = 0.2
	sphere.radial_segments = 8
	sphere.rings = 4
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = b.color
	sphere.material = mat
	bulb.mesh = sphere
	bulb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bulb.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	lamp.add_child(bulb)
	_beacons.append({"light": lamp, "bulb": mat, "color": b.color, "color2": b.get("color2", b.color),
			"two": b.has("color2"), "energy": b.energy, "speed": b.speed, "phase": randf() * TAU})


# --- Quality -----------------------------------------------------------------------

## Low / Medium / High (Settings.Quality values 0 / 1 / 2).
func apply_quality(q: int) -> void:
	_quality = q
	if _dust:
		_dust.visible = q >= 1
		_dust.emitting = q >= 1
	for s in _shafts:
		s.visible = q >= 2
	for p in _probes:
		p.visible = q >= 2
	for b in _beacons:
		(b.light as Light3D).visible = q >= 2
	for f in _flickers:
		(f.light as Light3D).visible = q >= 1 or f.light.get_parent() != self
		_set_flicker(f, 1.0)


func _set_flicker(f: Dictionary, mult: float) -> void:
	f.mult = mult
	(f.light as Light3D).light_energy = f.base * mult
	if f.mat:
		(f.mat as StandardMaterial3D).emission_energy_multiplier = f.emission * mult


func _process(delta: float) -> void:
	_time += delta
	if _dust and _dust.visible:
		var cam := get_viewport().get_camera_3d()
		if cam:
			_dust.global_position = cam.global_position
	if _quality >= 1:
		for f in _flickers:
			_tick_flicker(f, delta)
	if _quality >= 2:
		for b in _beacons:
			_tick_beacon(b)


# Steady most of the time, now and then a burst of quick dips: dark for a
# moment, then back. `strong` lamps dip to almost nothing, weak ones a little.
func _tick_flicker(f: Dictionary, delta: float) -> void:
	f.t -= delta
	if f.t > 0.0:
		return
	if f.burst > 0:
		f.burst -= 1
		var low := 0.05 if f.strong else 0.6
		_set_flicker(f, low if f.burst % 2 == 0 and f.burst > 0 else randf_range(0.7, 1.0))
		f.t = randf_range(0.03, 0.11)
		if f.burst == 0:
			_set_flicker(f, 1.0)
			f.t = randf_range(2.0, 6.0) if f.strong else randf_range(4.0, 10.0)
	else:
		f.burst = randi_range(3, 9)
		f.t = 0.02


func _tick_beacon(b: Dictionary) -> void:
	var s := sin(_time * b.speed + b.phase)
	var light: Light3D = b.light
	var c: Color = b.color if (s > 0.0 or not b.two) else b.color2
	light.light_color = c
	var k := pow(absf(s), 1.5)
	light.light_energy = b.energy * k
	(b.bulb as StandardMaterial3D).albedo_color = c * (0.25 + 0.75 * k)
