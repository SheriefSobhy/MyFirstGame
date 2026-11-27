extends Node3D
## A visible zone on the ground (Defend point, Rescue extraction): a glowing
## ring and a faint disc, unshaded (works in Compatibility, no shadows, two
## draw calls). `color` changes both.

var radius := 3.0
var color := Color(0.3, 0.7, 1.0):
	set(c):
		color = c
		if _ring_mat:
			_ring_mat.albedo_color = Color(c, 0.9)
			_disc_mat.albedo_color = Color(c, 0.16)

var _ring_mat: StandardMaterial3D
var _disc_mat: StandardMaterial3D


func _init(r := 3.0, c := Color(0.3, 0.7, 1.0)) -> void:
	radius = r
	color = c


func _ready() -> void:
	_ring_mat = _material()
	_disc_mat = _material()
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = radius - 0.16
	torus.outer_radius = radius
	torus.rings = 48
	torus.ring_segments = 4
	ring.mesh = torus
	ring.material_override = _ring_mat
	ring.scale = Vector3(1.0, 0.35, 1.0)
	ring.position.y = 0.05
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)
	var disc := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = 0.02
	cyl.radial_segments = 32
	cyl.rings = 1
	disc.mesh = cyl
	disc.material_override = _disc_mat
	disc.position.y = 0.03
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(disc)
	color = color


## True if `pos` is inside (flat distance).
func contains(pos: Vector3) -> bool:
	return Vector2(pos.x - global_position.x, pos.z - global_position.z).length() <= radius


static func _material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = false
	return m
