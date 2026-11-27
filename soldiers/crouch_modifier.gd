extends SkeletonModifier3D
## Combat mode: a procedural crouch on top of the soldier's animation (the
## Mixamo set has no crouch clip), for hiding behind low cover. The hips go
## down CROUCH_DROP m, the feet stay where the animation put them (two-bone
## leg IK, knees forward) and the upper body leans forward CROUCH_LEAN
## degrees. `influence` (0 = standing, 1 = crouched) blends it in and out;
## tactical_soldier.gd drives it. Works in skeleton space, so the model's
## scale and facing don't matter.

const Cfg := preload("res://soldiers/soldiers_config.gd")
const LEGS := [["LeftUpLeg", "LeftLeg", "LeftFoot"], ["RightUpLeg", "RightLeg", "RightFoot"]]

## The character's forward direction in world space (set by the soldier).
var forward := Vector3.FORWARD
var _hips := -1
var _spine := -1
var _legs: Array[PackedInt32Array] = []


func _ready() -> void:
	var skel := get_skeleton()
	if skel == null:
		return
	_hips = skel.find_bone("Hips")
	_spine = skel.find_bone("Spine")
	for leg: Array in LEGS:
		var ids := PackedInt32Array()
		for bone: String in leg:
			ids.append(skel.find_bone(bone))
		if not ids.has(-1):
			_legs.append(ids)


func _process_modification() -> void:
	var skel := get_skeleton()
	if skel == null or _hips < 0 or influence <= 0.001:
		return
	# Skeleton-space directions and the drop in skeleton units.
	var to_skel := skel.global_basis.inverse()
	var up := (to_skel * Vector3.UP).normalized()
	var fwd := (to_skel * forward)
	fwd = (fwd - up * fwd.dot(up)).normalized()
	var units := (to_skel * Vector3.UP).length()  # skeleton units per metre
	# Where the animation put the feet (and how they're turned).
	var feet: Array[Transform3D] = []
	for leg in _legs:
		feet.append(skel.get_bone_global_pose(leg[2]))
	var hips := skel.get_bone_global_pose(_hips)
	hips.origin -= up * Cfg.CROUCH_DROP * units
	skel.set_bone_global_pose(_hips, hips)
	if _spine >= 0:
		var spine := skel.get_bone_global_pose(_spine)
		var right := fwd.cross(up).normalized()
		spine.basis = Basis(right, -deg_to_rad(Cfg.CROUCH_LEAN)) * spine.basis
		skel.set_bone_global_pose(_spine, spine)
	for i in _legs.size():
		_bend_leg(skel, _legs[i], feet[i], fwd)


# Two-bone IK: thigh and shin turned so the foot ends up back at `foot`
# (its animated pose), the knee bending towards `fwd`.
func _bend_leg(skel: Skeleton3D, leg: PackedInt32Array, foot: Transform3D, fwd: Vector3) -> void:
	var thigh := skel.get_bone_global_pose(leg[0])
	var shin := skel.get_bone_global_pose(leg[1])
	var ankle := skel.get_bone_global_pose(leg[2])
	var a := thigh.origin
	var l1 := a.distance_to(shin.origin)
	var l2 := shin.origin.distance_to(ankle.origin)
	var target := foot.origin
	var to_target := target - a
	var d := clampf(to_target.length(), absf(l1 - l2) + 0.001, l1 + l2 - 0.001)
	var dir := to_target.normalized()
	var bend := (fwd - dir * fwd.dot(dir)).normalized()
	var cos_a := clampf((l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d), -1.0, 1.0)
	var knee := a + dir * (cos_a * l1) + bend * (sqrt(1.0 - cos_a * cos_a) * l1)
	thigh.basis = _turn(shin.origin - a, knee - a) * thigh.basis
	skel.set_bone_global_pose(leg[0], thigh)
	shin = skel.get_bone_global_pose(leg[1])
	ankle = skel.get_bone_global_pose(leg[2])
	shin.basis = _turn(ankle.origin - shin.origin, target - shin.origin) * shin.basis
	skel.set_bone_global_pose(leg[1], shin)
	# The foot keeps the animation's orientation (flat on the ground).
	ankle = skel.get_bone_global_pose(leg[2])
	ankle.basis = foot.basis
	skel.set_bone_global_pose(leg[2], ankle)


static func _turn(from: Vector3, to: Vector3) -> Basis:
	if from.length_squared() < 1e-8 or to.length_squared() < 1e-8:
		return Basis.IDENTITY
	return Basis(Quaternion(from.normalized(), to.normalized()))
