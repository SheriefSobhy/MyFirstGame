extends Node3D
## First-person arms holding the current gun, made from Quaternius' CC0 SWAT
## character. On load (once, nothing runs per frame):
## 1. Only the arm triangles of the body mesh are kept, and the head, legs
##    and feet are hidden, so the torso never shows up in front of the camera.
## 2. A small two-bone IK solve puts both hands on the gun and curls the
##    fingers. This runs again only when the weapon changes (see grip()); the
##    arms follow the weapon's sway/recoil/reload because they're children
##    of WeaponRecoil.
## The hand targets and poles are in this node's space (= WeaponRecoil space,
## where the gun grip is at the origin). The left_hand_* exports are the
## pistol pose; other guns' left-hand spots are in weapon_stats.gd.

const ARM_BONES := ["UpperArm", "LowerArm", "Hand", "Index", "Middle", "Ring", "Pinky", "Thumb"]
const FINGERS := ["Index", "Middle", "Ring", "Pinky"]

@export var right_hand_pos := Vector3(0.028, -0.02, 0.06)
@export var right_hand_forward := Vector3(-0.2, 0.05, -1.0)  # wrist -> knuckles
@export var right_hand_back := Vector3(1.0, 0.15, 0.1)          # back of the hand
@export var right_elbow_pole := Vector3(0.6, -1.0, 0.3)
@export var left_hand_pos := Vector3(-0.035, -0.06, 0.05)
@export var left_hand_forward := Vector3(0.5, 0.35, -1.0)
@export var left_hand_back := Vector3(-0.8, -0.6, 0.0)
@export var left_elbow_pole := Vector3(-0.8, -1.0, 0.3)
@export var finger_curl_deg := 75.0
@export var thumb_curl_deg := 20.0

@onready var model: Node3D = $Swat
var skel: Skeleton3D


func _ready() -> void:
	skel = model.find_children("*", "Skeleton3D", true, false)[0]
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		if mi.name.ends_with("Body"):
			mi.mesh = _arms_only(mi.mesh)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		else:
			mi.visible = false
	grip(Vector3.ZERO, left_hand_pos, left_hand_forward, left_hand_back)


## Re-poses both arms. The player calls this on every weapon switch with the
## values from weapon_stats.gd:
##  - arms_offset moves the whole arm rig (the arms only reach ~35 cm, so for
##    long guns the rig slides forward to reach the handguard);
##  - left_pos is where the left hand holds the gun (WeaponRecoil space).
## The right hand always stays on the grip.
func grip(arms_offset: Vector3, left_pos: Vector3, left_forward: Vector3, left_back: Vector3) -> void:
	position = arms_offset
	skel.reset_bone_poses()
	_solve_arm("R", right_hand_pos - arms_offset, right_hand_forward, right_hand_back, right_elbow_pole)
	_solve_arm("L", left_pos - arms_offset, left_forward, left_back, left_elbow_pole)


# Keeps only triangles whose vertices are mostly skinned to arm/hand bones.
func _arms_only(src: Mesh) -> ArrayMesh:
	var keep_bone := PackedByteArray()
	keep_bone.resize(skel.get_bone_count())
	for i in skel.get_bone_count():
		var n := skel.get_bone_name(i)
		for prefix in ARM_BONES:
			if n.begins_with(prefix):
				keep_bone[i] = 1
	var out := ArrayMesh.new()
	for s in src.get_surface_count():
		var arr := src.surface_get_arrays(s)
		var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		var vcount: int = arr[Mesh.ARRAY_VERTEX].size()
		@warning_ignore("integer_division")
		var per: int = bones.size() / vcount  # bone slots per vertex (4 or 8)
		var on_arm := PackedByteArray()
		on_arm.resize(vcount)
		for v in vcount:
			var w := 0.0
			for k in per:
				if keep_bone[bones[v * per + k]]:
					w += weights[v * per + k]
			on_arm[v] = 1 if w > 0.5 else 0
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var kept := PackedInt32Array()
		for t in range(0, idx.size(), 3):
			if on_arm[idx[t]] and on_arm[idx[t + 1]] and on_arm[idx[t + 2]]:
				kept.append_array([idx[t], idx[t + 1], idx[t + 2]])
		if kept.is_empty():
			continue
		arr[Mesh.ARRAY_INDEX] = kept
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, src.surface_get_format(s) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
		out.surface_set_material(out.get_surface_count() - 1, src.surface_get_material(s))
	return out


# Rotates basis `b` (minimal rotation) so its Y axis points along `dir`.
func _aim_y(b: Basis, dir: Vector3) -> Basis:
	var from := b.y.normalized()
	var to := dir.normalized()
	if from.cross(to).length() < 1e-5:
		return b
	return Basis(Quaternion(from, to)) * b


func _solve_arm(side: String, hand_pos: Vector3, fwd: Vector3, back: Vector3, pole: Vector3) -> void:
	var upper := skel.find_bone("UpperArm." + side)
	var lower := skel.find_bone("LowerArm." + side)
	var hand := skel.find_bone("Hand." + side)
	# Everything below is in skeleton space.
	var to_skel := skel.global_transform.affine_inverse() * global_transform
	var basis_to_skel := to_skel.basis.orthonormalized()
	var target := to_skel * hand_pos
	var pole_dir := (basis_to_skel * pole).normalized()

	var g_upper := skel.get_bone_global_pose(upper)
	var g_lower := skel.get_bone_global_pose(lower)
	var g_hand := skel.get_bone_global_pose(hand)
	var s := g_upper.origin
	var l1 := s.distance_to(g_lower.origin)
	var l2 := g_lower.origin.distance_to(g_hand.origin)
	var d := clampf(s.distance_to(target), (l1 + l2) * 0.05, (l1 + l2) * 0.999)
	var dir := (target - s).normalized()
	target = s + dir * d
	var a := (l1 * l1 - l2 * l2 + d * d) / (2.0 * d)
	var h := sqrt(maxf(l1 * l1 - a * a, 0.0))
	var pv := (pole_dir - dir * pole_dir.dot(dir)).normalized()
	var elbow := s + dir * a + pv * h

	var parent_upper := skel.get_bone_global_pose(skel.get_bone_parent(upper)).basis
	var new_upper := _aim_y(g_upper.basis, elbow - s)
	skel.set_bone_pose_rotation(upper, (parent_upper.inverse() * new_upper).get_rotation_quaternion())
	var new_lower := _aim_y(new_upper * (g_upper.basis.inverse() * g_lower.basis), target - elbow)
	skel.set_bone_pose_rotation(lower, (new_upper.inverse() * new_lower).get_rotation_quaternion())

	# Hand: Y = wrist->knuckles, Z = back of the hand (the rig's convention).
	var y := (basis_to_skel * fwd).normalized()
	var z := (basis_to_skel * back).normalized()
	z = (z - y * z.dot(y)).normalized()
	var new_hand := Basis(y.cross(z), y, z)
	skel.set_bone_pose_rotation(hand, (new_lower.inverse() * new_hand).get_rotation_quaternion())

	# Curl the fingers around the grip (rotate about each bone's X axis).
	for f in FINGERS:
		for j in [2, 3, 4]:
			var b := skel.find_bone("%s%d.%s" % [f, j, side])
			if b >= 0:
				var rest := skel.get_bone_rest(b).basis.get_rotation_quaternion()
				skel.set_bone_pose_rotation(b, rest * Quaternion(Vector3.RIGHT, deg_to_rad(-finger_curl_deg)))
	for j in [2, 3]:
		var b := skel.find_bone("Thumb%d.%s" % [j, side])
		if b >= 0:
			var rest := skel.get_bone_rest(b).basis.get_rotation_quaternion()
			skel.set_bone_pose_rotation(b, rest * Quaternion(Vector3.RIGHT, deg_to_rad(-thumb_curl_deg)))
