extends Node3D
## A power-up dropped by an enemy (match_economy.gd spawns it): a glowing,
## spinning token with its name over it. Walk into it to collect it. It
## blinks before it vanishes (economy.gd POWERUP_LIFETIME / POWERUP_BLINK).
## Built from simple meshes, no lights (cheap on phones).

signal collected(kind: String)

const Economy := preload("res://economy.gd")
const FLOAT_HEIGHT := 0.9
const BOB := 0.12
const SPIN := 2.2

## A key of economy.gd POWERUP_INFO. Set before adding to the scene.
var kind := "max_ammo"
var time_left := Economy.POWERUP_LIFETIME

var _token: Node3D
var _player: Node3D
var _t := randf() * TAU


func _ready() -> void:
	_player = get_tree().get_first_node_in_group("player")
	var info: Dictionary = Economy.POWERUP_INFO[kind]
	var color: Color = info.color
	_token = Node3D.new()
	add_child(_token)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color.darkened(0.3)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.5
	mat.metallic = 0.3
	mat.roughness = 0.35
	# A coin with a raised rim, standing up so it reads from far away.
	var coin := CylinderMesh.new()
	coin.top_radius = 0.3
	coin.bottom_radius = 0.3
	coin.height = 0.08
	coin.radial_segments = 20
	coin.rings = 1
	coin.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = coin
	mi.rotation.x = PI / 2.0
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_token.add_child(mi)
	var rim := TorusMesh.new()
	rim.inner_radius = 0.3
	rim.outer_radius = 0.37
	rim.rings = 20
	rim.ring_segments = 6
	rim.material = mat
	var rim_mi := MeshInstance3D.new()
	rim_mi.mesh = rim
	rim_mi.rotation.x = PI / 2.0
	rim_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_token.add_child(rim_mi)

	var label := Label3D.new()
	label.text = info.short
	label.font_size = 64
	label.pixel_size = 0.004
	label.outline_size = 12
	label.modulate = color.lightened(0.3)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = false
	label.position.y = FLOAT_HEIGHT + 0.6
	label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(label)
	add_child(_glow_disc(color))


func _process(delta: float) -> void:
	_t += delta
	time_left -= delta
	if time_left <= 0.0:
		queue_free()
		return
	_token.rotation.y += SPIN * delta
	_token.position.y = FLOAT_HEIGHT + sin(_t * 2.5) * BOB
	# Blink faster and faster before it disappears.
	if time_left < Economy.POWERUP_BLINK:
		var rate := lerpf(10.0, 3.0, time_left / Economy.POWERUP_BLINK)
		visible = sin(_t * rate * TAU) > -0.3
	if _player and not _player.is_dead:
		var d := Vector2(_player.global_position.x - global_position.x, _player.global_position.z - global_position.z)
		if d.length() < Economy.POWERUP_PICKUP_RADIUS and absf(_player.global_position.y - global_position.y) < 2.0:
			collected.emit(kind)
			queue_free()


func _glow_disc(color: Color) -> MeshInstance3D:
	var g := Gradient.new()
	g.set_color(0, Color(color, 0.7))
	g.set_color(1, Color(color, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = g
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
	quad.size = Vector2(1.6, 1.6)
	quad.orientation = PlaneMesh.FACE_Y
	quad.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.position.y = 0.03
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
