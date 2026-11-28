extends SceneTree
## Step 3 of the enemy model build (tools/blender/build_enemies.bat runs all
## steps), after Godot has imported assets/models/enemies/*.glb:
##  1. their extracted textures are set to VRAM compression (+ mipmaps), so
##     phones get ETC2/ASTC and desktop/web S3TC/BPTC (reimport afterwards);
##  2. the Mixamo animation FBX files (art_source/mixamo/, not in git) are
##     retargeted onto each character's skeleton and saved as
##     assets/models/enemies/<id>_anims.res (an AnimationLibrary that
##     enemy.gd adds to the model; track paths are "Skeleton3D:<bone>" from
##     the skeleton's parent). All LODs of a character share it.
##
## Retargeting: the animation files were made on other Mixamo rigs whose rest
## poses differ a little, so each bone's rotation is carried over as a change
## from the T-pose in skeleton space (target = src_pose * src_rest^-1 *
## target_rest), not copied. The hips also move, scaled by hip height. Forward
## root motion is removed from the looping clips (the game moves the enemy);
## its speed is kept as the animation's "ground_speed" metadata (m/s at model
## scale 1) so enemy.gd can match the feet to the walking speed. Death clips
## keep theirs (the body falls back). Hit reactions stay procedural.
##   godot --headless --path . --script res://tools/mixamo_anims.gd [-- --textures-only]

const SRC := "res://art_source/mixamo/"
const OUT := "res://assets/models/enemies/"
const FPS := 30.0

## Animation sets: name in the library -> [FBX file, loops, special].
## special: "" | "pose" (a still pose: the clip's first frame).
const ZOMBIE_SET := {
	"idle": ["Zombie Idle", true, ""],
	"walk": ["Zombie Walk", true, ""],
	"run": ["Zombie Running", true, ""],
	"attack": ["Zombie Attack", false, ""],
	"death": ["Zombie Death", false, ""],
}
## "idle" (the rifle-up pose), "walk", "shoot", "death": the zombie mode's
## soldier (enemy.gd) uses those. The Combat soldier (tactical_soldier.gd)
## also blends the rest by velocity (see its "Animation" section).
const SOLDIER_SET := {
	"idle": ["Firing Rifle", true, "pose"],
	"walk": ["Rifle Walk", true, ""],
	"shoot": ["Firing Rifle", false, ""],
	"death": ["Dying", false, ""],
	"relaxed": ["Rifle Idle", true, ""],
	"aim": ["Rifle Aiming Idle", true, ""],
	"run": ["Rifle Run", true, ""],
	"walk_back": ["Walk Backward", true, ""],
	"walk_left": ["Walk Left", true, ""],
	"walk_right": ["Walk Right", true, ""],
	"crouch": ["Idle Crouching", true, ""],
	"hit": ["Hit Reaction", false, ""],
}
## Combat missions' hostage (missions/hostage.gd) on the Exploder's mesh
## (the Ch35 officer, without the glow). Each entry may list a fallback FBX
## after the special: used while the wanted clip isn't in art_source/mixamo/
## yet (download the Mixamo clips named first, "Without Skin", 30 fps, and
## rerun with `-- --only hostage`).
const HOSTAGE_SET := {
	"idle": ["Terrified", true, "", "Rifle Walk", "pose"],
	"walk": ["Walking", true, "", "Rifle Walk", ""],
	"run": ["Running", true, "", "Rifle Walk", ""],
	"death": ["Dying", false, ""],
}
const CHARACTERS := {
	"zombie": ZOMBIE_SET,
	"runner": ZOMBIE_SET,
	"brute": ZOMBIE_SET,
	"exploder": ZOMBIE_SET,
	"soldier": SOLDIER_SET,
	"hostage": HOSTAGE_SET,
}
## Characters that reuse another one's mesh (id -> mesh id).
const MESH_OF := {"hostage": "exploder"}

var _sources := {}  # file -> {skel: Skeleton3D, anim: Animation, path: String}


func _initialize() -> void:
	_set_texture_imports()
	var args := OS.get_cmdline_user_args()
	if "--textures-only" in args:
		quit(0)
		return
	var only := ""
	if args.has("--only"):
		only = args[args.find("--only") + 1]
	var failed := false
	for id: String in CHARACTERS:
		if only != "" and id != only:
			continue
		var scene: Node = load(OUT + MESH_OF.get(id, id) + "_high.glb").instantiate()
		var skel: Skeleton3D = scene.find_children("*", "Skeleton3D", true, false)[0]
		var lib := AnimationLibrary.new()
		var set_def: Dictionary = CHARACTERS[id]
		for anim_name: String in set_def:
			var def: Array = set_def[anim_name]
			if def.size() > 3 and not FileAccess.file_exists(SRC + def[0] + ".fbx"):
				print("%s %s: no %s.fbx yet, placeholder %s" % [id, anim_name, def[0], def[3]])
				def = [def[3], def[1], def[4]]
			var src := _source(def[0])
			if src.is_empty():
				failed = true
				continue
			var a := _retarget(src, skel, def[1], def[2] == "pose")
			lib.add_animation(anim_name, a)
			print("%s %-10s %5.2f s  %3d tracks  ground %.2f m/s %s  %d steps" % [id, anim_name, a.length, a.get_track_count(), a.get_meta("ground_speed", 0.0), a.get_meta("ground_dir", Vector2.ZERO), a.get_meta("steps", 0)])
			if anim_name == "attack":
				print("  strike at %.2f s" % a.get_meta("hit_time"))
		var path := OUT + id + "_anims.res"
		var err := ResourceSaver.save(lib, path, ResourceSaver.FLAG_COMPRESS)
		print("%s -> %s (%s, %d KB)" % [id, path, error_string(err), FileAccess.get_file_as_bytes(path).size() / 1024])
		failed = failed or err != OK
		scene.free()
	for s: Dictionary in _sources.values():
		s.root.free()
	quit(1 if failed else 0)


# Extracted model textures: VRAM compressed with mipmaps (not "detect 3D",
# which only switches over when the editor sees them used).
func _set_texture_imports() -> void:
	for f in DirAccess.get_files_at(OUT):
		if not f.ends_with(".import") or f.ends_with(".glb.import"):
			continue
		var cfg := ConfigFile.new()
		if cfg.load(OUT + f) != OK:
			continue
		if cfg.get_value("params", "compress/mode", 0) == 2:
			continue
		cfg.set_value("params", "compress/mode", 2)
		cfg.set_value("params", "mipmaps/generate", true)
		cfg.set_value("params", "detect_3d/compress_to", 0)
		cfg.save(OUT + f)
		print("VRAM compression: ", f.get_basename())


func _source(file: String) -> Dictionary:
	if _sources.has(file):
		return _sources[file]
	var doc := FBXDocument.new()
	var state := FBXState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(SRC + file + ".fbx"), state) != OK:
		push_error("can't read %s.fbx" % file)
		return {}
	var root := doc.generate_scene(state)
	var skel: Skeleton3D = root.find_children("*", "Skeleton3D", true, false)[0]
	var ap: AnimationPlayer = root.find_children("*", "AnimationPlayer", true, false)[0]
	var anim: Animation = ap.get_animation(ap.get_animation_list()[0])
	var bones := {}  # stripped name -> source bone index
	for b in skel.get_bone_count():
		bones[_strip(skel.get_bone_name(b))] = b
	var tracks := {}  # source bone index -> {rot: track, pos: track}
	for t in anim.get_track_count():
		var bone_name := String(anim.track_get_path(t).get_concatenated_subnames())
		var b := skel.find_bone(bone_name)
		if b < 0:
			continue
		if not tracks.has(b):
			tracks[b] = {}
		match anim.track_get_type(t):
			Animation.TYPE_ROTATION_3D:
				tracks[b].rot = t
			Animation.TYPE_POSITION_3D:
				tracks[b].pos = t
	_sources[file] = {"root": root, "skel": skel, "anim": anim, "bones": bones, "tracks": tracks}
	return _sources[file]


static func _strip(bone: String) -> String:
	for p in ["mixamorig_", "mixamorig:", "mixamorig1_", "mixamorig1:"]:
		if bone.begins_with(p):
			return bone.substr(p.length())
	return bone


func _retarget(src: Dictionary, dst: Skeleton3D, loop: bool, pose: bool) -> Animation:
	var sk: Skeleton3D = src.skel
	var anim: Animation = src.anim
	var tracks: Dictionary = src.tracks
	var length: float = anim.length
	var frames := 1 if pose else maxi(int(round(length * FPS)) + 1, 2)
	var src_order := _parent_first(sk)
	var dst_order := _parent_first(dst)
	var src_rest_glob := []
	for b in sk.get_bone_count():
		src_rest_glob.append(sk.get_bone_global_rest(b).basis.get_rotation_quaternion())
	var dst_rest_glob := []
	for b in dst.get_bone_count():
		dst_rest_glob.append(dst.get_bone_global_rest(b).basis.get_rotation_quaternion())
	# Target bone -> source bone (by name), only bones the clip animates.
	var bone_map := {}
	for b in dst.get_bone_count():
		var s: int = src.bones.get(dst.get_bone_name(b), -1)
		if s >= 0 and tracks.has(s) and tracks[s].has("rot"):
			bone_map[b] = s
	var hips := dst.find_bone("Hips")
	var src_hips: int = src.bones.get("Hips", -1)
	var hip_scale := dst.get_bone_rest(hips).origin.y / sk.get_bone_rest(src_hips).origin.y

	var out := Animation.new()
	out.length = 1.0 if pose else length
	out.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	var rot_track := {}
	for b: int in bone_map:
		var t := out.add_track(Animation.TYPE_ROTATION_3D)
		out.track_set_path(t, NodePath("Skeleton3D:%s" % dst.get_bone_name(b)))
		rot_track[b] = t
	var pos_t := out.add_track(Animation.TYPE_POSITION_3D)
	out.track_set_path(pos_t, NodePath("Skeleton3D:Hips"))

	var hip_offsets: Array[Vector3] = []
	var reach: Array[Vector2] = []  # (time, how far the hands are in front of the hips)
	var feet: Array[float] = []      # left foot - right foot, forwards (steps)
	for f in frames:
		var time := minf(f / FPS, length)
		var src_glob := {}
		for b: int in src_order:
			var local: Quaternion
			if tracks.has(b) and tracks[b].has("rot"):
				local = anim.rotation_track_interpolate(tracks[b].rot, time)
			else:
				local = sk.get_bone_rest(b).basis.get_rotation_quaternion()
			var p := sk.get_bone_parent(b)
			src_glob[b] = (src_glob[p] * local) if p >= 0 else local
		var dst_glob := {}
		for b: int in dst_order:
			var p := dst.get_bone_parent(b)
			var g: Quaternion
			if bone_map.has(b):
				var s: int = bone_map[b]
				g = src_glob[s] * src_rest_glob[s].inverse() * dst_rest_glob[b]
			else:
				var rest_local := dst.get_bone_rest(b).basis.get_rotation_quaternion()
				g = (dst_glob[p] * rest_local) if p >= 0 else rest_local
			dst_glob[b] = g.normalized()
			if rot_track.has(b):
				var local: Quaternion = (dst_glob[p].inverse() * g) if p >= 0 else g
				out.rotation_track_insert_key(rot_track[b], time, local.normalized())
		var pos := _bone_positions(dst, dst_order, dst_glob)
		var hips_z: float = pos[hips].z
		reach.append(Vector2(time, maxf(pos[dst.find_bone("RightHand")].z, pos[dst.find_bone("LeftHand")].z) - hips_z))
		feet.append(pos[dst.find_bone("LeftFoot")].z - pos[dst.find_bone("RightFoot")].z)
		var src_pos: Vector3 = sk.get_bone_rest(src_hips).origin
		if tracks[src_hips].has("pos"):
			src_pos = anim.position_track_interpolate(tracks[src_hips].pos, time)
		hip_offsets.append((src_pos - sk.get_bone_rest(src_hips).origin) * hip_scale)

	# Root motion: looping clips walk in place (the straight line from the
	# first to the last frame is taken out, the sway stays).
	var drift := hip_offsets[hip_offsets.size() - 1] - hip_offsets[0]
	drift.y = 0.0
	if loop and not pose:
		out.set_meta("ground_speed", drift.length() / length)
		# Which way the clip walks, in the soldier's frame (x = its right,
		# y = forward; the model faces +Z and is turned round in enemy.gd).
		var d2 := Vector2(-drift.x, drift.z)
		out.set_meta("ground_dir", d2.normalized() if d2.length() > 0.01 else Vector2.ZERO)
	for f in frames:
		var off := hip_offsets[f]
		if loop:
			var k := float(f) / maxf(frames - 1, 1)
			off -= hip_offsets[0].lerp(hip_offsets[0] + drift, k) * Vector3(1, 0, 1)
		out.position_track_insert_key(pos_t, minf(f / FPS, length), dst.get_bone_rest(hips).origin + off)
	_drop_still_keys(out)
	if not loop:
		# The strike: when a hand is furthest in front (in the first 2/3 of the
		# clip; the end is the recovery). enemy.gd lines it up with the damage.
		var best := Vector2(0.0, -INF)
		for r in reach:
			if r.x < length * 0.67 and r.y > best.y:
				best = r
		out.set_meta("hit_time", best.x)
	elif not pose:
		# Footsteps per loop: each time the feet pass each other (heavy
		# enemies thud on each one).
		var steps := 0
		for f in range(1, feet.size()):
			if signf(feet[f]) != signf(feet[f - 1]):
				steps += 1
		out.set_meta("steps", maxi(steps, 2))
	return out


# Every bone's position (skeleton space, hips at the origin) from the
# bones' global rotations.
static func _bone_positions(sk: Skeleton3D, order: Array[int], glob: Dictionary) -> Dictionary:
	var pos := {}
	for b in order:
		var p := sk.get_bone_parent(b)
		pos[b] = (pos[p] + (glob[p] as Quaternion) * sk.get_bone_rest(b).origin) if p >= 0 else Vector3.ZERO
	return pos


# Bones in an order where each parent comes before its children.
static func _parent_first(sk: Skeleton3D) -> Array[int]:
	var order: Array[int] = []
	var todo := Array(sk.get_parentless_bones())
	while not todo.is_empty():
		var b: int = todo.pop_front()
		order.append(b)
		todo.append_array(Array(sk.get_bone_children(b)))
	return order


# Tracks that never move (fingers in most clips) keep only their first key.
static func _drop_still_keys(a: Animation) -> void:
	for t in a.get_track_count():
		var n := a.track_get_key_count(t)
		if n < 2:
			continue
		var first: Variant = a.track_get_key_value(t, 0)
		var still := true
		for k in range(1, n):
			var v: Variant = a.track_get_key_value(t, k)
			if v is Quaternion and absf((v as Quaternion).dot(first)) < 0.99999:
				still = false
				break
			if v is Vector3 and (v as Vector3).distance_to(first) > 0.0005:
				still = false
				break
		if still:
			for k in range(n - 1, 0, -1):
				a.track_remove_key(t, k)


