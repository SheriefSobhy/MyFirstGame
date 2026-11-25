extends RefCounted
## Weapon skins (progression_config.gd SKINS): recolours a gun model's
## materials. Each surface keeps its light and dark parts, just shifted
## towards the skin's colour; Camo adds a generated blotchy texture.
## player.gd puts the equipped skin on each first-person model.

const Config := preload("res://progression_config.gd")
const CAMO_COLORS := [Color(0.16, 0.2, 0.11), Color(0.36, 0.4, 0.22), Color(0.45, 0.36, 0.24), Color(0.08, 0.08, 0.07)]

static var _camo: Texture2D


## Puts skin `skin_id` on every mesh under `model` ("standard" = no change).
static func apply(model: Node, skin_id: String) -> void:
	var skin: Dictionary = Config.SKINS.get(skin_id, Config.SKINS.standard)
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		for s in mi.mesh.get_surface_count():
			# Back to the model's own material first, so skins don't stack.
			mi.set_surface_override_material(s, null)
			if skin.mix > 0.0 or skin.pattern != "":
				mi.set_surface_override_material(s, skinned(mi.get_active_material(s), skin))


## A copy of `source` in the skin's colours.
static func skinned(source: Material, skin: Dictionary) -> Material:
	var mat: StandardMaterial3D
	if source is StandardMaterial3D:
		mat = source.duplicate()
	else:
		mat = StandardMaterial3D.new()
	var base: Color = mat.albedo_color
	var shade := clampf(0.45 + base.get_luminance() * 1.1, 0.35, 1.4)
	var target: Color = skin.color * shade
	target.a = base.a
	mat.albedo_color = base.lerp(target, skin.mix)
	if skin.metallic >= 0.0:
		mat.metallic = skin.metallic
	if skin.roughness >= 0.0:
		mat.roughness = skin.roughness
	if skin.pattern == "camo":
		mat.albedo_texture = camo_texture()
		mat.albedo_color = Color(shade, shade, shade, base.a).lerp(Color.WHITE, 0.3)
		mat.uv1_triplanar = true
		mat.uv1_scale = Vector3.ONE * 2.5
	return mat


## 128x128 four-colour camouflage, made once.
static func camo_texture() -> Texture2D:
	if _camo:
		return _camo
	var noise := FastNoiseLite.new()
	noise.seed = 7
	noise.frequency = 0.035
	noise.fractal_octaves = 2
	var img := Image.create(128, 128, false, Image.FORMAT_RGB8)
	for y in 128:
		for x in 128:
			var i := clampi(int((noise.get_noise_2d(x, y) + 0.5) * 4.0), 0, 3)
			img.set_pixel(x, y, CAMO_COLORS[i])
	img.generate_mipmaps()
	_camo = ImageTexture.create_from_image(img)
	return _camo
