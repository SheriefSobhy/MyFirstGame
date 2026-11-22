extends SceneTree
## Generates the grime/detail textures in assets/textures/generated/.
## They're made from noise and random walks, so they need no license.
## Run: godot --headless --path . --script res://tools/gen_textures.gd

const OUT := "res://assets/textures/generated/"


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	seed(1234)
	_noise_rgb()
	_cracks()
	_blob("decal_oil.png", 256, Color(0.05, 0.045, 0.04), 0.3, 7, true, 0.02)
	_blob("decal_stain.png", 256, Color(0.42, 0.36, 0.29), 0.55, 11, false, 0.1)
	_blob("puddle_mask.png", 256, Color(1, 1, 1), 0.3, 21, false, 0.02)
	_chainlink()
	print("Textures written to ", OUT)
	quit()


func _fbm(freq: float, octaves: int, s: int, type := FastNoiseLite.TYPE_SIMPLEX_SMOOTH) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = type
	n.seed = s
	n.frequency = freq
	n.fractal_octaves = octaves
	return n


# Tileable 256 px noise. R = big blotches, G = medium detail, B = fine grain.
func _noise_rgb() -> void:
	var size := 256
	var chans: Array[Image] = []
	for cfg in [[0.012, 4, 1], [0.04, 3, 2], [0.15, 2, 3]]:
		var n := _fbm(cfg[0], cfg[1], cfg[2])
		var img := n.get_seamless_image(size, size, false, false, 0.1, true)
		img.convert(Image.FORMAT_L8)
		chans.append(img)
	var out := Image.create(size, size, false, Image.FORMAT_RGB8)
	for y in size:
		for x in size:
			out.set_pixel(x, y, Color(chans[0].get_pixel(x, y).r, chans[1].get_pixel(x, y).r, chans[2].get_pixel(x, y).r))
	out.save_png(OUT + "noise_rgb.png")


# Soft blob with a noisy edge. Used for oil, dirt stains and puddles.
func _blob(file: String, size: int, color: Color, edge_noise: float, s: int, dark_core: bool, grain: float) -> void:
	var n := _fbm(0.018, 4, s)
	var fine := _fbm(0.09, 2, s + 1)
	var img := Image.create(size, size, true, Image.FORMAT_RGBA8)
	var c := Vector2(size, size) * 0.5
	for y in size:
		for x in size:
			var p := Vector2(x, y)
			var d := p.distance_to(c) / (size * 0.42)
			d += n.get_noise_2d(x, y) * edge_noise + fine.get_noise_2d(x, y) * grain
			var a := clampf(smoothstep(1.0, 0.7, d), 0.0, 1.0)
			if dark_core:
				a *= 0.75 + 0.25 * smoothstep(0.9, 0.2, d)
			img.set_pixel(x, y, Color(color.r, color.g, color.b, a))
	img.generate_mipmaps()
	img.save_png(OUT + file)


# Branching dark cracks on transparent background.
func _cracks() -> void:
	var size := 512
	var alpha := PackedFloat32Array()
	alpha.resize(size * size)
	var walkers: Array = []
	for i in 4:
		walkers.append([Vector2(size * 0.5, size * 0.5), TAU * (i + randf_range(-0.2, 0.2)) / 4.0, 2.4, 260])
	while not walkers.is_empty():
		var w: Array = walkers.pop_back()
		var pos: Vector2 = w[0]
		var ang: float = w[1]
		var width: float = w[2]
		for step in int(w[3]):
			ang += randf_range(-0.22, 0.22)
			pos += Vector2.from_angle(ang) * 1.0
			if pos.x < 8 or pos.y < 8 or pos.x > size - 8 or pos.y > size - 8:
				break
			_stamp(alpha, size, pos, width)
			width = maxf(width * 0.996, 1.1)
			if randf() < 0.012 and width > 1.0:
				walkers.append([pos, ang + randf_range(-1.3, 1.3), width * 0.7, int(w[3] * 0.5)])
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			img.set_pixel(x, y, Color(0.12, 0.1, 0.09, alpha[y * size + x]))
	img.generate_mipmaps()
	img.save_png(OUT + "decal_cracks.png")


func _stamp(alpha: PackedFloat32Array, size: int, pos: Vector2, r: float) -> void:
	# Hard core for the crack itself plus a faint dirty halo around it.
	var halo := r * 3.0
	for y in range(int(pos.y - halo), int(pos.y + halo) + 1):
		for x in range(int(pos.x - halo), int(pos.x + halo) + 1):
			var d := Vector2(x, y).distance_to(pos)
			var a := clampf(r * 0.5 + 0.5 - d, 0.0, 1.0)
			if d < halo:
				a = maxf(a, 0.15 * (1.0 - d / halo))
			var i := y * size + x
			alpha[i] = maxf(alpha[i], a)


# Tileable chain-link diamond mesh for the fence (alpha-scissored).
func _chainlink() -> void:
	var size := 128
	var img := Image.create(size, size, true, Image.FORMAT_RGBA8)
	var cell := size / 2.0
	for y in size:
		for x in size:
			var u := fposmod(x + y, cell)
			var v := fposmod(x - y, cell)
			var d := minf(minf(u, cell - u), minf(v, cell - v))
			var a := 1.0 if d < 2.2 else 0.0
			var shade := 0.55 + 0.25 * (1.0 - d / 2.2)
			img.set_pixel(x, y, Color(shade, shade, shade * 1.02, a))
	img.generate_mipmaps()
	img.save_png(OUT + "chainlink.png")
