extends Node3D
## First-person arms (the Mixamo soldier's arms and gloves, made by
## tools/blender/build_arms.py; the detail level follows the graphics quality).
## Every frame both hands go to their targets (Node3Ds inside the current
## weapon view, weapon_view.gd), so they follow the gun's sway, recoil and
## reload, and the left hand can take the magazine or work the bolt:
##  - the hand turns to the target's basis (X = thumb side for the right hand,
##    Y = wrist -> knuckles, Z = palm) with its palm on the target's origin;
##  - a two-bone IK bends shoulder -> elbow -> wrist, elbows pointing down and
##    out; the collarbone swings forward when the arm can't reach;
##  - half the wrist's twist goes to the forearm (no candy-wrapper wrists);
##  - fingers curl by the target's "curl" (index..pinky) and "thumb" metadata.
## Runs after player.gd's _process (child of the player), so there's no lag.
## Costs ~40 bone writes a frame, no physics, no animation player.

const MODEL_PATH := "res://assets/models/arms/%s_%s.glb"
const LODS := ["low", "med", "high"]
const FINGERS := ["Index", "Middle", "Ring", "Pinky"]
## Bend per finger joint at curl = 1 (degrees): knuckle, middle, tip.
const FINGER_BEND := [75.0, 95.0, 65.0]
const THUMB_BEND := [25.0, 35.0, 40.0]
const MAX_COLLARBONE := deg_to_rad(28.0)

## Where the middle of the shoulders sits, in this node's space (the view
## rig, metres before VIEW_SCALE; the eye is at the origin).
@export var shoulders := Vector3(0.0, -0.27, -0.06)
## Elbow directions (this node's space).
@export var right_pole := Vector3(0.55, -1.0, 0.25)
@export var left_pole := Vector3(-0.7, -1.0, 0.1)
## "arms" (whole arms, most guns) or "gloves" (hands + short sleeves, the
## Pistol); set before the node enters the tree.
@export var model_name := "arms"
## Size of the model (the IK works in its own space, so smaller hands just
## reach a little further with the collarbone).
@export var model_scale := 1.0

var skel: Skeleton3D
var right_target: Node3D
var left_target: Node3D
var _sides := {}   # "Right"/"Left" -> chain data (see _chain())


func _ready() -> void:
	var q: int = Settings.effective_quality()
	var model: Node3D = load(MODEL_PATH % [model_name, LODS[clampi(q, 0, 2)]]).instantiate()
	add_child(model)
	skel = model.find_children("*", "Skeleton3D", true, false)[0]
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# The rest pose (T-pose) box is nowhere near where the arms are drawn.
		mi.custom_aabb = AABB(Vector3(-3, -3, -3), Vector3(6, 6, 6))
	for side in ["Right", "Left"]:
		_sides[side] = _chain(side)
	# Face forward (-Z) with the shoulders at `shoulders`.
	var mid: Vector3 = (_sides.Right.arm_rest + _sides.Left.arm_rest) * 0.5
	var at := to_local(skel.global_transform * mid)  # with the model untouched
	var turn := Basis(Vector3.UP, PI).scaled(Vector3.ONE * model_scale)
	model.transform = Transform3D(turn, shoulders - turn * at)


## The hands' targets (from the weapon view). null = leave that arm alone.
func set_targets(right: Node3D, left: Node3D) -> void:
	right_target = right
	left_target = left


func _process(_delta: float) -> void:
	if not visible:
		return
	var to_skel := skel.global_transform.affine_inverse()
	if right_target:
		_solve(_sides.Right, right_target, to_skel, right_pole)
	if left_target:
		_solve(_sides.Left, left_target, to_skel, left_pole)


func _bone(n: String) -> int:
	return skel.find_bone(n)


# Rest data for one arm, all in skeleton space.
func _chain(side: String) -> Dictionary:
	var c := {
		"clav": _bone(side + "Shoulder"),
		"upper": _bone(side + "Arm"),
		"lower": _bone(side + "ForeArm"),
		"hand": _bone(side + "Hand"),
	}
	var g := func(b: int) -> Transform3D: return skel.get_bone_global_rest(b)
	var hand_rest: Transform3D = g.call(c.hand)
	var mid1: Vector3 = g.call(_bone(side + "HandMiddle1")).origin
	var idx1: Vector3 = g.call(_bone(side + "HandIndex1")).origin
	var pinky1: Vector3 = g.call(_bone(side + "HandPinky1")).origin
	var fwd := (mid1 - hand_rest.origin).normalized()
	var palm := (idx1 - pinky1).normalized().cross(fwd).normalized()
	if palm.y > 0.0:
		palm = -palm  # T-pose: palms face down
	palm = (palm - fwd * fwd.dot(palm)).normalized()
	var frame := Basis(fwd.cross(palm), fwd, palm)
	c.frame_inv = frame.inverse()
	var palm_point: Vector3 = hand_rest.origin + fwd * hand_rest.origin.distance_to(mid1) * 0.55 + palm * 0.022
	c.palm_local = hand_rest.basis.inverse() * (palm_point - hand_rest.origin)
	c.arm_rest = g.call(c.upper).origin
	c.l1 = g.call(c.upper).origin.distance_to(g.call(c.lower).origin)
	c.l2 = g.call(c.lower).origin.distance_to(hand_rest.origin)
	# Fingers: bone, rest rotation, local curl axis (curls towards the palm).
	var side_axis := fwd.cross(palm)
	c.fingers = []
	for f in FINGERS:
		var chain := []
		for j in 3:
			var b := _bone("%sHand%s%d" % [side, f, j + 1])
			if b >= 0:
				var axis: Vector3 = (g.call(b).basis.inverse() * side_axis).normalized()
				chain.append([b, skel.get_bone_rest(b).basis.get_rotation_quaternion(), axis])
		c.fingers.append(chain)
	var t1: Vector3 = g.call(_bone(side + "HandThumb1")).origin
	var t2: Vector3 = g.call(_bone(side + "HandThumb2")).origin
	var thumb_axis := (t2 - t1).normalized().cross(palm).normalized()
	c.thumb = []
	for j in 3:
		var b := _bone("%sHandThumb%d" % [side, j + 1])
		if b >= 0:
			var axis: Vector3 = (g.call(b).basis.inverse() * thumb_axis).normalized()
			c.thumb.append([b, skel.get_bone_rest(b).basis.get_rotation_quaternion(), axis])
	return c


func _solve(c: Dictionary, target: Node3D, to_skel: Transform3D, pole_dir: Vector3) -> void:
	var tg := to_skel * target.global_transform
	var tb := tg.basis.orthonormalized()
	# Hand orientation: rest hand frame -> target frame.
	var frame := Basis(tb.x, tb.y, tb.z)
	var spin: Basis = frame * (c.frame_inv as Basis)
	var hand_rest := skel.get_bone_global_rest(c.hand)
	var hand_basis: Basis = (spin * hand_rest.basis).orthonormalized()
	var wrist: Vector3 = tg.origin - hand_basis * (c.palm_local as Vector3)
	var reach: float = (c.l1 + c.l2) * 0.985

	# Collarbone: swing it towards the wrist if the arm is too short.
	var clav_rest := skel.get_bone_global_rest(c.clav)
	var clav_basis := clav_rest.basis
	var shoulder: Vector3 = c.arm_rest
	if shoulder.distance_to(wrist) > reach:
		var from: Vector3 = shoulder - clav_rest.origin
		var to: Vector3 = wrist - clav_rest.origin
		var axis := from.cross(to)
		if axis.length_squared() > 1e-8:
			axis = axis.normalized()
			var angle := 0.0
			var step := MAX_COLLARBONE / 6.0
			while angle < MAX_COLLARBONE and (clav_rest.origin + from.rotated(axis, angle)).distance_to(wrist) > reach:
				angle += step
			clav_basis = Basis(axis, angle) * clav_rest.basis
			shoulder = clav_rest.origin + from.rotated(axis, angle)
	var parent_clav := skel.get_bone_global_rest(skel.get_bone_parent(c.clav)).basis
	skel.set_bone_pose_rotation(c.clav, (parent_clav.inverse() * clav_basis).get_rotation_quaternion())

	# Two-bone IK: shoulder -> elbow -> wrist.
	var l1: float = c.l1
	var l2: float = c.l2
	var d := clampf(shoulder.distance_to(wrist), absf(l1 - l2) + 0.01, l1 + l2 - 0.001)
	var dir: Vector3 = (wrist - shoulder).normalized()
	var a := (l1 * l1 - l2 * l2 + d * d) / (2.0 * d)
	var h := sqrt(maxf(l1 * l1 - a * a, 0.0))
	var pole := (to_skel.basis * (global_basis * pole_dir)).normalized()
	var pv: Vector3 = pole - dir * pole.dot(dir)
	if pv.length_squared() < 1e-6:
		pv = Vector3.DOWN - dir * dir.y
	pv = pv.normalized()
	var elbow: Vector3 = shoulder + dir * a + pv * h
	var hand_at: Vector3 = shoulder + dir * d

	var upper_rest := skel.get_bone_global_rest(c.upper)
	var lower_rest := skel.get_bone_global_rest(c.lower)
	# Upper arm: the rest pose relative to the collarbone, then aimed at the elbow.
	var upper_basis := clav_basis * (clav_rest.basis.inverse() * upper_rest.basis)
	upper_basis = _aim(upper_basis, upper_basis * (upper_rest.basis.inverse() * (lower_rest.origin - upper_rest.origin)), elbow - shoulder)
	var lower_basis := upper_basis * (upper_rest.basis.inverse() * lower_rest.basis)
	var lower_to_hand := lower_rest.basis.inverse() * (hand_rest.origin - lower_rest.origin)
	lower_basis = _aim(lower_basis, lower_basis * lower_to_hand, hand_at - elbow)
	# Give the forearm half of the wrist's twist about the forearm's axis.
	var axis_local := lower_to_hand.normalized()
	var want_local: Basis = (lower_basis.inverse() * hand_basis) * (lower_rest.basis.inverse() * hand_rest.basis).inverse()
	var q: Quaternion = want_local.get_rotation_quaternion()
	var proj := axis_local * Vector3(q.x, q.y, q.z).dot(axis_local)
	var twist := Quaternion(proj.x, proj.y, proj.z, q.w)
	if twist.length_squared() > 1e-8:
		twist = twist.normalized()
		lower_basis = lower_basis * Basis(Quaternion.IDENTITY.slerp(twist, 0.5))
	skel.set_bone_pose_rotation(c.upper, (clav_basis.inverse() * upper_basis).get_rotation_quaternion())
	skel.set_bone_pose_rotation(c.lower, (upper_basis.inverse() * lower_basis).get_rotation_quaternion())
	skel.set_bone_pose_rotation(c.hand, (lower_basis.inverse() * hand_basis).get_rotation_quaternion())

	# Fingers.
	var curl: Array = target.get_meta("curl", [0.5, 0.5, 0.5, 0.5])
	for i in c.fingers.size():
		var amount: float = curl[i]
		var chain: Array = c.fingers[i]
		for j in chain.size():
			var e: Array = chain[j]
			skel.set_bone_pose_rotation(e[0], e[1] * Quaternion(e[2], deg_to_rad(FINGER_BEND[j] * amount)))
	var thumb: float = target.get_meta("thumb", 0.3)
	for j in c.thumb.size():
		var e: Array = c.thumb[j]
		skel.set_bone_pose_rotation(e[0], e[1] * Quaternion(e[2], deg_to_rad(THUMB_BEND[j] * thumb)))


# Basis `b` turned (smallest rotation) so its vector `from` points along `to`.
func _aim(b: Basis, from: Vector3, to: Vector3) -> Basis:
	var f := from.normalized()
	var t := to.normalized()
	var axis := f.cross(t)
	if axis.length_squared() < 1e-10:
		return b
	return Basis(axis.normalized(), f.angle_to(t)) * b
