extends Area3D
## A floating, spinning pickup. Walk into it to collect it.
##  - WEAPON: gives the player a weapon from weapon_stats.gd, then disappears.
##    If the player already has that weapon, it gives spare ammo instead.
##  - AMMO: gives spare ammo to every weapon the player has, then comes back
##    after `respawn_time` seconds. If all the ammo is full, it stays.
## The visuals are built in code: the weapon's own model, or a small ammo box.

enum Kind { WEAPON, AMMO }

const Weapons := preload("res://weapon_stats.gd")
const WeaponModel := preload("res://weapon_model.gd")
const AMMO_SOUND := preload("res://assets/sounds/metalLatch.ogg")
const FLOAT_HEIGHT := 0.6   # metres above the floor
const BOB_HEIGHT := 0.08
const SPIN_SPEED := 1.6     # radians per second

@export var kind := Kind.AMMO
## Slot in weapon_stats.gd (1 = rifle, 2 = shotgun, 3 = sniper).
@export_range(0, 3) var weapon_index := 1
@export var respawn_time := 30.0

var _visual: Node3D
var _glow: MeshInstance3D
var _active := true
var _respawn_timer := 0.0
var _time := randf() * TAU

@onready var sound: AudioStreamPlayer = $Sound


func _ready() -> void:
	_visual = Node3D.new()
	add_child(_visual)
	if kind == Kind.WEAPON:
		_build_weapon()
		sound.stream = Weapons.LIST[weapon_index].reload_sounds[-1][1]
	else:
		_build_ammo_box()
		sound.stream = AMMO_SOUND
	_build_glow()


func _process(delta: float) -> void:
	if not _active:
		if _respawn_timer > 0.0:
			_respawn_timer -= delta
			if _respawn_timer <= 0.0:
				_set_active(true)
		return
	_time += delta
	_visual.rotation.y += SPIN_SPEED * delta
	_visual.position.y = FLOAT_HEIGHT + sin(_time * 2.0) * BOB_HEIGHT


func _physics_process(_delta: float) -> void:
	if not _active:
		return
	# Checked every frame (not only on enter) so standing on a full ammo box
	# still picks it up once you've used some ammo.
	for body in get_overlapping_bodies():
		if body.is_in_group("player"):
			_collect(body)
			return


func _collect(player: Node) -> void:
	var used: bool = player.give_weapon(weapon_index) if kind == Kind.WEAPON else player.give_ammo()
	if not used:
		return
	sound.play()
	_set_active(false)
	if kind == Kind.AMMO:
		_respawn_timer = respawn_time


func _set_active(on: bool) -> void:
	_active = on
	_visual.visible = on
	_glow.visible = on


# The weapon's model, scaled to pickup_length and centred, tilted a little.
func _build_weapon() -> void:
	var w: Dictionary = Weapons.LIST[weapon_index]
	var model: Node3D = w.model.instantiate()
	var aabb: AABB = WeaponModel.measure(model).aabb
	var s: float = w.pickup_length / aabb.size.x
	var basis := Basis(Vector3.FORWARD, deg_to_rad(12)).scaled(Vector3.ONE * s)
	model.transform = Transform3D(basis, -(basis * aabb.get_center()))
	_visual.add_child(model)


# A small olive ammo crate with a darker lid and a yellow label.
func _build_ammo_box() -> void:
	_add_box(Vector3(0.46, 0.24, 0.28), Vector3(0, 0, 0), Color(0.22, 0.27, 0.13), 0.7)
	_add_box(Vector3(0.48, 0.05, 0.3), Vector3(0, 0.13, 0), Color(0.15, 0.18, 0.09), 0.6)
	_add_box(Vector3(0.18, 0.08, 0.005), Vector3(0, 0.0, 0.142), Color(0.85, 0.65, 0.1), 0.5)
	_add_box(Vector3(0.18, 0.08, 0.005), Vector3(0, 0.0, -0.142), Color(0.85, 0.65, 0.1), 0.5)
	_add_box(Vector3(0.12, 0.03, 0.04), Vector3(0, 0.17, 0), Color(0.08, 0.08, 0.08), 0.4)  # handle


func _add_box(size: Vector3, pos: Vector3, color: Color, roughness: float) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	_visual.add_child(mi)


# A soft glowing disc on the floor so pickups are easy to spot.
func _build_glow() -> void:
	var gradient := Gradient.new()
	var tint := Color(1.0, 0.75, 0.25) if kind == Kind.WEAPON else Color(0.45, 1.0, 0.35)
	gradient.set_color(0, Color(tint, 0.55))
	gradient.set_color(1, Color(tint, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 64
	tex.height = 64
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_texture = tex
	var quad := QuadMesh.new()
	quad.size = Vector2(1.1, 1.1)
	quad.orientation = PlaneMesh.FACE_Y
	quad.material = mat
	_glow = MeshInstance3D.new()
	_glow.mesh = quad
	_glow.position.y = 0.02
	_glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_glow)
