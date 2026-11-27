extends StaticBody3D
## Sabotage missions: one target (missions/sabotage.gd). Built in code:
##  generator  a painted box generator on a frame with an exhaust and a panel
##  fuel       a horizontal fuel tank on two saddles, with red barrels
##  vehicle    the Kenney truck (assets/models/vehicles/truck.glb), larger
## A box collider on layer 1 (cover, blocks bullets and the soldiers' view)
## and a NavigationObstacle3D so soldiers steer round it (the baked navmesh
## doesn't know it). plant() sticks a blinking C4 charge on it; blow() is the
## big explosion: Blast.detonate (damage, shake) plus extra fireballs, a
## flash and a burning wreck that smokes for WRECK_FIRE_TIME s. Primitive
## meshes, a few CPU particles: cheap on phones.

const M := preload("res://missions/missions_config.gd")
const Blast := preload("res://effects/blast.gd")
const Explosion := preload("res://effects/explosion.gd")
const Synth := preload("res://effects/synth_sounds.gd")
const TRUCK := "res://assets/models/vehicles/truck.glb"
const BARREL := "res://assets/models/polyhaven/Barrel_01/Barrel_01_1k.gltf"

var kind := "generator"
var planted := false
## Seconds between beeps (sabotage.gd shortens it as the countdown runs).
var beep_interval := 1.4
var destroyed := false
var size := Vector3.ONE
var _c4: Node3D
var _c4_light: MeshInstance3D
var _beep: AudioStreamPlayer3D
var _visual: Node3D
var _beep_left := 0.0
var _fire: Array[CPUParticles3D] = []
var _fire_left := 0.0

static var _paint := {}


func _init(target_kind := "generator") -> void:
	kind = target_kind
	size = M.TARGET_SIZE.get(kind, Vector3.ONE)


func _ready() -> void:
	add_to_group("sabotage_targets")
	collision_layer = 1
	collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position.y = size.y * 0.5
	add_child(shape)
	var obstacle := NavigationObstacle3D.new()
	var hx := size.x * 0.5 + 0.1
	var hz := size.z * 0.5 + 0.1
	obstacle.vertices = PackedVector3Array([Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(hx, 0, hz), Vector3(-hx, 0, hz)])
	obstacle.height = size.y
	obstacle.avoidance_enabled = true
	add_child(obstacle)
	_visual = Node3D.new()
	_visual.name = "Visual"
	add_child(_visual)
	match kind:
		"fuel":
			_build_fuel()
		"vehicle":
			_build_vehicle()
		_:
			_build_generator()
	_beep = AudioStreamPlayer3D.new()
	_beep.stream = Synth.c4_beep()
	_beep.unit_size = 6.0
	_beep.max_distance = 40.0
	add_child(_beep)
	set_process(false)


## Where the C4 sits and the USE button is measured from (the front face).
func use_point() -> Vector3:
	return global_position + global_basis.z * (size.z * 0.5 + 0.2) + Vector3.UP * 0.9


func plant() -> void:
	if planted:
		return
	planted = true
	_c4 = Node3D.new()
	_c4.name = "C4"
	add_child(_c4)
	_c4.position = Vector3(0.0, minf(size.y * 0.55, 1.0), size.z * 0.5 + 0.06)
	var block := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.28, 0.18, 0.08)
	block.mesh = bm
	block.material_override = _mat("c4", Color(0.55, 0.5, 0.36), 0.9)
	_c4.add_child(block)
	_c4_light = MeshInstance3D.new()
	var lm := SphereMesh.new()
	lm.radius = 0.025
	lm.height = 0.05
	_c4_light.mesh = lm
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.albedo_color = Color(3.0, 0.2, 0.1)
	_c4_light.material_override = glow
	_c4_light.position = Vector3(0.08, 0.06, 0.05)
	_c4.add_child(_c4_light)
	_beep_left = 0.0
	set_process(true)




func _process(delta: float) -> void:
	if planted and not destroyed:
		_beep_left -= delta
		if _beep_left <= 0.0:
			_beep_left = beep_interval
			_beep.play()
			_c4_light.visible = true
		elif beep_interval - _beep_left > 0.06:
			_c4_light.visible = false
	if destroyed:
		_fire_left -= delta
		if _fire_left <= 0.0:
			for p in _fire:
				p.emitting = false
			set_process(false)


## The big explosion. player: the player node (damage + shake).
func blow(player: Node3D) -> void:
	if destroyed:
		return
	destroyed = true
	if _c4:
		_c4.queue_free()
	var center := global_position + Vector3.UP * size.y * 0.5
	Blast.detonate(self, center, M.BLAST_RADIUS, M.BLAST_ENEMY_DAMAGE, player, M.BLAST_RADIUS, M.BLAST_PLAYER_DAMAGE)
	if player and player.has_method("add_shake"):
		player.add_shake(0.6)
	# Extra fireballs around it a moment apart (sound only on the first).
	var offsets := [Vector3(size.x * 0.4, 0.8, 0.0), Vector3(-size.x * 0.3, 1.4, size.z * 0.3), Vector3(0.0, 2.2, -size.z * 0.2)]
	for i in offsets.size():
		var t := get_tree().create_timer(0.12 * (i + 1), false)
		t.timeout.connect(_fireball.bind(center + global_basis * (offsets[i] as Vector3)))
	_wreck()


func _fireball(pos: Vector3) -> void:
	if not is_inside_tree():
		return
	var fx := Explosion.new()
	fx.with_sound = false
	get_tree().current_scene.add_child(fx)
	fx.setup(pos)


# Charred and burning: the visual goes dark, a fire and a smoke column.
func _wreck() -> void:
	var dark := _mat("wreck", Color(0.07, 0.06, 0.055), 1.0)
	for mi: MeshInstance3D in _visual.find_children("*", "MeshInstance3D", true, false):
		mi.material_override = dark
	_visual.rotation.z = randf_range(-0.06, 0.06)
	_visual.position.y = -0.05
	var top := size.y * 0.8
	_fire.append(_emitter(14, 0.9, 0.9, true, Vector3(0, top, 0), Vector3(0, 2.2, 0),
			[Color(1.0, 0.85, 0.4, 0.9), Color(1.0, 0.4, 0.08, 0.6), Color(0.3, 0.1, 0.05, 0.0)], size * 0.35))
	_fire.append(_emitter(12, 4.0, 2.2, false, Vector3(0, top + 0.8, 0), Vector3(0.4, 1.6, 0.2),
			[Color(0.15, 0.13, 0.12, 0.55), Color(0.2, 0.19, 0.18, 0.3), Color(0.25, 0.25, 0.25, 0.0)], size * 0.25))
	_fire_left = M.WRECK_FIRE_TIME
	set_process(true)


func _emitter(amount: int, lifetime: float, quad: float, additive: bool, at: Vector3, velocity: Vector3,
		colors: Array, box: Vector3) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.local_coords = false
	p.position = at
	var q := QuadMesh.new()
	q.size = Vector2(quad, quad)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	m.vertex_color_use_as_albedo = true
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.albedo_texture = Explosion._soft_texture()
	q.material = m
	p.mesh = q
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(box.x, 0.2, box.z)
	p.direction = velocity.normalized()
	p.spread = 12.0
	p.initial_velocity_min = velocity.length() * 0.7
	p.initial_velocity_max = velocity.length()
	p.gravity = Vector3.ZERO
	p.scale_amount_min = 0.7
	p.scale_amount_max = 1.3
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	g.colors = PackedColorArray(colors)
	p.color_ramp = g
	p.emitting = true
	add_child(p)
	return p


# --- Models ------------------------------------------------------------------

static func _mat(key: String, color: Color, rough: float, metal := 0.0) -> StandardMaterial3D:
	if not _paint.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = rough
		m.metallic = metal
		_paint[key] = m
	return _paint[key]


func _box(s: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = s
	mi.mesh = bm
	mi.material_override = mat
	mi.position = at
	_visual.add_child(mi)
	return mi


func _cyl(r: float, h: float, at: Vector3, rot: Vector3, mat: Material, segs := 12) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = h
	cm.radial_segments = segs
	cm.rings = 1
	mi.mesh = cm
	mi.material_override = mat
	mi.position = at
	mi.rotation = rot
	_visual.add_child(mi)
	return mi


func _build_generator() -> void:
	var paint := _mat("gen", Color(0.62, 0.5, 0.12), 0.55, 0.3)
	var frame := _mat("frame", Color(0.12, 0.12, 0.13), 0.6, 0.6)
	var panel := _mat("panel", Color(0.2, 0.22, 0.24), 0.4, 0.4)
	_box(Vector3(1.6, 0.12, 1.0), Vector3(0, 0.06, 0), frame)              # skid
	_box(Vector3(1.45, 1.05, 0.9), Vector3(0, 0.65, 0), paint)             # housing
	_box(Vector3(1.5, 0.08, 0.95), Vector3(0, 1.21, 0), frame)             # lid rim
	_box(Vector3(0.5, 0.4, 0.04), Vector3(-0.35, 0.75, 0.47), panel)       # control panel
	for i in 4:
		_box(Vector3(0.06, 0.6, 0.02), Vector3(0.2 + i * 0.13, 0.7, 0.46), frame)  # vents
	_cyl(0.06, 0.6, Vector3(0.55, 1.45, -0.2), Vector3.ZERO, frame, 8)     # exhaust
	_cyl(0.16, 0.12, Vector3(-0.45, 1.29, -0.15), Vector3.ZERO, frame, 10)  # filler cap


func _build_fuel() -> void:
	var paint := _mat("tank", Color(0.72, 0.72, 0.68), 0.5, 0.4)
	var stripe := _mat("stripe", Color(0.7, 0.1, 0.08), 0.6, 0.2)
	var frame := _mat("frame", Color(0.12, 0.12, 0.13), 0.6, 0.6)
	var r := 0.72
	_cyl(r, 2.7, Vector3(0, 0.95, 0), Vector3(0, 0, PI * 0.5), paint, 16)   # tank along X
	_cyl(r + 0.01, 0.25, Vector3(0, 0.95, 0), Vector3(0, 0, PI * 0.5), stripe, 16)
	for x: float in [-0.9, 0.9]:
		_box(Vector3(0.15, 0.4, 1.2), Vector3(x, 0.2, 0), frame)            # saddles
	_cyl(0.08, 0.3, Vector3(0.6, 1.75, 0), Vector3.ZERO, frame, 8)         # hatch
	_box(Vector3(0.3, 0.04, 0.3), Vector3(-0.6, 1.68, 0), frame)
	_cyl(0.05, 1.0, Vector3(-1.2, 0.5, 0.55), Vector3(PI * 0.5, 0, 0), frame, 6)  # hose
	if ResourceLoader.exists(BARREL):
		var barrel_scene: PackedScene = load(BARREL)
		for i in 2:
			var b: Node3D = barrel_scene.instantiate()
			b.position = Vector3(-0.6 + i * 0.7, 0.0, 0.85 + i * 0.1)
			b.rotation.y = i * 1.3
			_visual.add_child(b)


func _build_vehicle() -> void:
	var truck: Node3D = load(TRUCK).instantiate()
	truck.scale = Vector3.ONE * 1.6
	_visual.add_child(truck)
