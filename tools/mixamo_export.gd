extends SceneTree
## Step 1 of the enemy model build (tools/blender/build_enemies.bat runs all
## steps). Reads the Mixamo character FBX files from art_source/mixamo/ (not
## in git) with Godot's FBX importer (Blender can't read the old FBX 6.1 ones)
## and writes art_source/build/<id>_raw.glb for tools/blender/build_enemies.py:
##  - bones renamed without the "mixamorig_" prefix (Hips, Head, RightHand...)
##  - only the albedo texture kept, scaled down to 1024 px (High quality size)
##  - the FBX's own animation dropped (animations come from the animation
##    files, retargeted by tools/mixamo_anims.gd)
##   godot --headless --path . --script res://tools/mixamo_export.gd

const CHARACTERS := ["zombie", "runner", "brute", "soldier", "exploder"]
const MAX_TEXTURE := 1024


func _initialize() -> void:
	var src := ProjectSettings.globalize_path("res://art_source/mixamo/")
	var out := ProjectSettings.globalize_path("res://art_source/build/")
	DirAccess.make_dir_recursive_absolute(out)
	var failed := false
	for id: String in CHARACTERS:
		var doc := FBXDocument.new()
		var state := FBXState.new()
		if doc.append_from_file(src + id + ".fbx", state) != OK:
			push_error("can't read %s.fbx" % id)
			failed = true
			continue
		var scene := doc.generate_scene(state)
		for ap in scene.find_children("*", "AnimationPlayer", true, false):
			ap.get_parent().remove_child(ap)
			ap.free()
		var skel: Skeleton3D = scene.find_children("*", "Skeleton3D", true, false)[0]
		for b in skel.get_bone_count():
			skel.set_bone_name(b, strip_prefix(skel.get_bone_name(b)))
		var tris := 0
		var done := {}
		for mi: MeshInstance3D in scene.find_children("*", "MeshInstance3D", true, false):
			for s in mi.mesh.get_surface_count():
				tris += mi.mesh.surface_get_array_index_len(s) / 3
				var m := mi.mesh.surface_get_material(s) as BaseMaterial3D
				if m == null or done.has(m):
					continue
				done[m] = true
				_simplify_material(m)
		var doc_out := GLTFDocument.new()
		var state_out := GLTFState.new()
		doc_out.append_from_scene(scene, state_out)
		var path := out + id + "_raw.glb"
		var err := doc_out.write_to_filesystem(state_out, path)
		print("%s: %d bones, %d tris, %d materials -> %s (%s)" % [id, skel.get_bone_count(), tris, done.size(), path, error_string(err)])
		failed = failed or err != OK
		scene.free()
	quit(1 if failed else 0)


static func strip_prefix(bone: String) -> String:
	for p in ["mixamorig_", "mixamorig:", "mixamorig1_", "mixamorig1:"]:
		if bone.begins_with(p):
			return bone.substr(p.length())
	return bone


# Albedo only (no normal/roughness/specular maps: they cost too much on
# phones for characters this size on screen), at most MAX_TEXTURE px.
func _simplify_material(m: BaseMaterial3D) -> void:
	if m.albedo_texture:
		var img := m.albedo_texture.get_image()
		if img.is_compressed():
			img.decompress()
		if img.get_width() > MAX_TEXTURE:
			img.resize(MAX_TEXTURE, MAX_TEXTURE * img.get_height() / img.get_width(), Image.INTERPOLATE_LANCZOS)
		m.albedo_texture = ImageTexture.create_from_image(img)
	for t in [BaseMaterial3D.TEXTURE_NORMAL, BaseMaterial3D.TEXTURE_ROUGHNESS, BaseMaterial3D.TEXTURE_METALLIC,
			BaseMaterial3D.TEXTURE_EMISSION, BaseMaterial3D.TEXTURE_AMBIENT_OCCLUSION]:
		m.set_texture(t, null)
	m.normal_enabled = false
	m.emission_enabled = false
	m.metallic = 0.0
	m.roughness = 0.85
