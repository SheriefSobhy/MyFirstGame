extends RigidBody3D
## A thrown frag grenade. It bounces off the floor, walls and enemies and
## explodes FUSE_TIME seconds after the throw. Enemies inside DAMAGE_RADIUS
## take damage that falls off with distance (none through walls); the player
## can be hurt too if they stand too close. The model is built in code.
##
## The player creates it with Grenade.new(), sets `thrower` and the start
## velocity, then adds it to the scene.

const Blast := preload("res://effects/blast.gd")
const BOUNCE_SOUNDS := [
	preload("res://assets/sounds/impactGeneric_light_000.ogg"),
	preload("res://assets/sounds/impactGeneric_light_001.ogg"),
	preload("res://assets/sounds/impactGeneric_light_002.ogg"),
]

const FUSE_TIME := 3.0
const RADIUS := 0.05             # collision sphere, metres
const DAMAGE_RADIUS := 7.0       # enemies take damage inside this range...
const MAX_DAMAGE := 10           # ...this much at the centre (enemies have 3 HP)
const PLAYER_RADIUS := 5.0       # the thrower can get hurt inside this range
const PLAYER_MAX_DAMAGE := 60
const GROUND_DRAG := 2.5         # linear damping after the first bounce

var thrower: Node3D
var fuse := FUSE_TIME
var _bounce_cooldown := 0.0

@onready var _sound := AudioStreamPlayer3D.new()


func _init() -> void:
	mass = 0.4
	continuous_cd = true
	collision_layer = 0
	collision_mask = 3
	# No air drag, so the flight matches the throw preview exactly.
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp = 3.0
	contact_monitor = true
	max_contacts_reported = 2
	var mat := PhysicsMaterial.new()
	mat.bounce = 0.35
	mat.friction = 0.8
	physics_material_override = mat
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = RADIUS
	shape.shape = sphere
	add_child(shape)
	add_child(build_model())


func _ready() -> void:
	if thrower:
		add_collision_exception_with(thrower)
	_sound.unit_size = 3.0
	add_child(_sound)
	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	_bounce_cooldown -= delta
	fuse -= delta
	if fuse <= 0.0:
		explode()


func _on_body_entered(_body: Node) -> void:
	# Once it has hit something it rolls and scuffs along the ground, so give it
	# some drag (none in the air, where it must follow the preview arc).
	linear_damp = GROUND_DRAG
	if _bounce_cooldown > 0.0 or linear_velocity.length() < 1.2:
		return
	_bounce_cooldown = 0.12
	_sound.stream = BOUNCE_SOUNDS.pick_random()
	_sound.pitch_scale = randf_range(1.3, 1.6)
	_sound.volume_db = linear_to_db(clampf(linear_velocity.length() / 10.0, 0.2, 1.0))
	_sound.play()


func explode() -> void:
	set_physics_process(false)
	Blast.detonate(self, global_position, DAMAGE_RADIUS, MAX_DAMAGE, thrower, PLAYER_RADIUS, PLAYER_MAX_DAMAGE)
	queue_free()


## Damage with linear falloff (see blast.gd).
static func damage_at(distance: float, radius: float, max_damage: int) -> int:
	return Blast.damage_at(distance, radius, max_damage)


## The grenade model: an olive egg-shaped body with a grey fuse and lever.
## Also used for the HUD-less preview in tests.
static func build_model() -> Node3D:
	var root := Node3D.new()
	root.name = "Model"
	var olive := StandardMaterial3D.new()
	olive.albedo_color = Color(0.24, 0.28, 0.15)
	olive.roughness = 0.7
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.45, 0.45, 0.42)
	metal.metallic = 0.7
	metal.roughness = 0.4

	var body := SphereMesh.new()
	body.radius = 0.034
	body.height = 0.085
	body.radial_segments = 12
	body.rings = 6
	body.material = olive
	_part(root, body, Vector3.ZERO)

	var fuse_mesh := CylinderMesh.new()
	fuse_mesh.top_radius = 0.012
	fuse_mesh.bottom_radius = 0.014
	fuse_mesh.height = 0.03
	fuse_mesh.radial_segments = 8
	fuse_mesh.material = metal
	_part(root, fuse_mesh, Vector3(0, 0.05, 0))

	var lever := BoxMesh.new()
	lever.size = Vector3(0.008, 0.07, 0.016)
	lever.material = metal
	var l := _part(root, lever, Vector3(0.036, 0.02, 0))
	l.rotation.z = deg_to_rad(8)

	var ring := TorusMesh.new()
	ring.inner_radius = 0.008
	ring.outer_radius = 0.012
	ring.rings = 8
	ring.ring_segments = 6
	ring.material = metal
	var r := _part(root, ring, Vector3(-0.016, 0.062, 0))
	r.rotation.z = PI / 2.0
	return root


static func _part(parent: Node3D, mesh: Mesh, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	parent.add_child(mi)
	return mi
