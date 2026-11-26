extends SceneTree
## Last step of the gun / arms build (tools/blender/build_guns.bat): import
## settings for the first-person models in assets/models/guns/ and arms/.
##  - .glb: no generated LODs (the three detail levels are separate files),
##    no shadow meshes or lightmap UVs (view models cast no shadows), tangents
##    on (normal maps);
##  - extracted textures: VRAM compressed (ETC2 on phones) with mipmaps.
## Returns 0; prints what it changed. Run `godot --headless --import` after.
##   godot --headless --path . --script res://tools/gun_imports.gd

const DIRS := ["res://assets/models/guns/", "res://assets/models/arms/"]


func _initialize() -> void:
	for dir: String in DIRS:
		for f in DirAccess.get_files_at(dir):
			if not f.ends_with(".import"):
				continue
			var cfg := ConfigFile.new()
			if cfg.load(dir + f) != OK:
				continue
			var want := {}
			if f.ends_with(".glb.import"):
				want = {
					"meshes/generate_lods": false,
					"meshes/create_shadow_meshes": false,
					"meshes/light_baking": 0,
					"meshes/ensure_tangents": true,
				}
			else:
				want = {
					"compress/mode": 2,
					"mipmaps/generate": true,
					"detect_3d/compress_to": 0,
					# Plain ETC2 RGB for normal maps too: half the size of the
					# two-channel format, and the shader rebuilds Z anyway.
					"compress/normal_map": 2,
				}
			var changed := false
			for k: String in want:
				if cfg.get_value("params", k, null) != want[k]:
					cfg.set_value("params", k, want[k])
					changed = true
			if changed:
				cfg.save(dir + f)
				print("import settings: ", dir + f.get_basename())
	quit(0)
