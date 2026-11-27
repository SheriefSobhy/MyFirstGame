extends Node3D
## One weapon's first-person model. player.gd makes one per weapon under its
## Gun node (turned so the barrel points forward). It loads the model for the
## graphics quality (assets/models/guns/<id>_<lod>.glb, made by
## tools/blender/build_guns.py), finds the moving parts and animates them:
##  - each shot: the slide / bolt kicks back, the revolver's cylinder turns;
##    the pump and the sniper's bolt are worked after the shot (cycle());
##  - reload: the left hand takes the magazine out and puts a new one in, then
##    works the bolt / charging handle; the revolver swings its cylinder out;
##    the shotgun loads shell by shell. Guns without parts (one mesh) only
##    tilt (player.gd).
## It also holds the two hand targets the arms reach for (fp_arms.gd). A
## target's basis is the hand's frame (X = towards the thumb side, Y = wrist
## -> knuckles, Z = the way the palm faces) and its "curl" / "thumb" metadata
## bend the fingers. During reloads the targets are moved onto the parts, so
## the hands follow the magazine, bolt or pump.
## Everything inside is in gun space: +X along the barrel, +Y up, +Z right.

signal eject(count: int)  # spent casings leave the gun now (player.gd spawns them)

const WeaponModel := preload("res://weapon_model.gd")
const WeaponSkins := preload("res://weapon_skins.gd")
const MODEL_PATH := "res://assets/models/guns/%s_%s.glb"
const LODS := ["low", "med", "high"]

## Hand shapes. fwd = wrist -> knuckles, palm = where the palm faces (gun
## space); at = offset of the palm from the hand's spot; curl = index, middle,
## ring, pinky (0 = straight .. 1 = fist), thumb (0..1).
const HANDS := {
	# Right hand round a pistol grip: knuckles along the grip, palm on its right.
	"grip": {"fwd": Vector3(0.94, -0.3, -0.12), "palm": Vector3(-0.15, 0.0, -1.0), "at": Vector3(-0.012, 0.0, 0.02),
			"curl": [0.45, 0.85, 0.9, 0.95], "thumb": 0.7},
	# Right hand round a shotgun's stock wrist.
	"stock": {"fwd": Vector3(0.5, -0.85, -0.1), "palm": Vector3(0.0, -0.2, -1.0), "at": Vector3(-0.005, 0.005, 0.022),
			"curl": [0.5, 0.85, 0.9, 0.95], "thumb": 0.7},
	# Left hand under a handguard / pump, palm up, fingers round its right side.
	"support": {"fwd": Vector3(0.25, 0.35, 1.0), "palm": Vector3(0.0, 1.0, 0.35), "at": Vector3(0.0, -0.012, -0.012),
			"curl": [0.7, 0.75, 0.8, 0.85], "thumb": 0.5},
	# Left hand over the right one on a pistol grip.
	"cup": {"fwd": Vector3(0.94, -0.3, 0.1), "palm": Vector3(0.1, 0.0, 1.0), "at": Vector3(0.008, -0.012, -0.012),
			"curl": [0.8, 0.85, 0.9, 0.95], "thumb": 0.6},
	# Pistol (two-hand "thumbs forward" grip): the right hand high on the
	# grip, thumb along the frame's left side pointing forward...
	"pistol_grip": {"fwd": Vector3(0.9, -0.4, -0.15), "palm": Vector3(-0.1, 0.0, -1.0), "at": Vector3(-0.012, 0.0, 0.02),
			"curl": [0.35, 0.85, 0.9, 0.95], "thumb": 0.15},
	# ...the left hand wrapped under and round it from the left, fingers over
	# the right hand's fingers, its thumb forward under the slide.
	"pistol_support": {"fwd": Vector3(0.55, -0.8, 0.25), "palm": Vector3(0.2, 0.1, 1.0), "at": Vector3(0.006, -0.01, -0.012),
			"curl": [0.8, 0.85, 0.9, 0.95], "thumb": 0.05},
	# Holding a magazine / shell, palm towards the gun.
	"hold": {"fwd": Vector3(0.4, 0.9, 0.1), "palm": Vector3(0.0, 0.0, 1.0), "at": Vector3(0.0, 0.0, -0.015),
			"curl": [0.7, 0.75, 0.8, 0.85], "thumb": 0.6},
	# Pinching a charging handle / bolt knob from above.
	"pinch": {"fwd": Vector3(0.3, -0.2, 1.0), "palm": Vector3(0.0, -1.0, 0.0), "at": Vector3(0.0, 0.02, 0.0),
			"curl": [0.75, 0.85, 0.9, 0.9], "thumb": 0.8},
}
## Right hand / left hand shape per weapon "hold" (weapon_stats.gd).
const HOLDS := {
	"pistol": ["grip", "cup"],
	"handgun": ["pistol_grip", "pistol_support"],
	"rifle": ["grip", "support"],
	"shotgun": ["stock", "support"],
}

var stats: Dictionary
var model: Node3D
var parts := {}            # part name ("mag", "slide", "bolt"...) -> Node3D
var right_target: Node3D   # where the right / left hand goes (fp_arms.gd)
var left_target: Node3D
var port: Node3D           # ejection port
var tip := Vector3.ZERO    # muzzle, gun space
var aabb: AABB

var _rest := {}            # Node3D -> Transform3D (parts and hand targets)
var _hold_left := ""
var _tween: Tween          # reload / cycle
var _kick: Tween           # per-shot part kick
var _slide_locked := false
var _hand_meta := {}       # hand target -> [curl, thumb] of its hold (reset())
# Pistol: a copy of the magazine that falls out of view on a reload (made
# with the model, so a reload never instantiates or compiles anything).
var _drop_mag: Node3D
var _drop_t := -1.0        # s since it was let go (-1 = not falling)
var _drop_from: Transform3D   # its start, in _view_root space
var _drop_vel := Vector3.ZERO
var _drop_spin := Vector3.ZERO
var _view_root: Node3D     # the camera's child holding the view model


## Builds the model. quality: Settings.Quality LOW / MEDIUM / HIGH.
func setup(w: Dictionary, quality: int) -> void:
	stats = w
	name = "View_" + str(w.view_model)
	var scene: PackedScene = load(MODEL_PATH % [w.view_model, LODS[clampi(quality, 0, 2)]])
	model = scene.instantiate()
	add_child(model)
	WeaponModel.no_shadows(model)
	var info := WeaponModel.measure(model)
	aabb = info.aabb
	tip = info.tip
	for c in model.get_children():
		if c is Node3D and c.name != "body":
			parts[String(c.name)] = c
	_add_pivots()
	for p: Node3D in parts.values():
		_rest[p] = p.transform
	var hold: Array = HOLDS[w.hold]
	right_target = _hand_target("RightHand", hold[0], Vector3.ZERO)
	left_target = _hand_target("LeftHand", hold[1], w.left_hand)
	_hold_left = hold[1]
	port = Node3D.new()
	port.name = "Port"
	port.position = w.port
	add_child(port)
	WeaponSkins.apply(model, Progress.skin_of(w.name))
	for t: Node3D in [right_target, left_target]:
		_hand_meta[t] = [t.get_meta("curl"), t.get_meta("thumb")]
	if String(w.view_model) == "pistol" and parts.has("mag"):
		_drop_mag = parts.mag.duplicate()
		_drop_mag.name = "DroppedMag"
		_drop_mag.visible = false
		add_child(_drop_mag)


func _enter_tree() -> void:
	_view_root = self
	while _view_root.get_parent() is Node3D and not (_view_root.get_parent() is Camera3D):
		_view_root = _view_root.get_parent()


# The dropped magazine falls (view space, life-size gravity, spinning) until
# it is out of sight.
func _process(delta: float) -> void:
	if _drop_t < 0.0:
		return
	_drop_t += delta
	if _drop_t > 0.7 or not visible:
		_drop_t = -1.0
		_drop_mag.visible = false
		return
	var t := _drop_t
	var down := (_view_root.global_basis.inverse() * Vector3.DOWN).normalized()
	var xf := _drop_from
	xf.origin += _drop_vel * t + down * (4.9 * t * t)
	xf.basis = Basis(_drop_spin.normalized(), _drop_spin.length() * t) * xf.basis
	_drop_mag.global_transform = _view_root.global_transform * xf

func _hand_target(node_name: String, hand: String, at: Vector3) -> Node3D:
	var t := Node3D.new()
	t.name = node_name
	add_child(t)
	_set_hand(t, hand, at)
	_rest[t] = t.transform
	return t


## Puts hand shape `hand` (HANDS) on target `t`, palm at `at` (in t's parent's space).
func _set_hand(t: Node3D, hand: String, at: Vector3) -> void:
	var h: Dictionary = HANDS[hand]
	var fwd: Vector3 = h.fwd.normalized()
	var palm: Vector3 = (h.palm - fwd * fwd.dot(h.palm)).normalized()
	t.transform = Transform3D(Basis(fwd.cross(palm), fwd, palm), at + h.at)
	t.set_meta("curl", h.curl)
	t.set_meta("thumb", h.thumb)


# Parts that turn about a hinge get a pivot node there.
func _add_pivots() -> void:
	match String(stats.view_model):
		"lmg":   # the feed cover hinges at its front
			_pivot("cover", Vector3(parts.cover.position.x + 0.12, parts.cover.position.y - 0.015, 0.0))
		"sniper":  # the bolt turns about the barrel's axis line
			_pivot("bolt", Vector3(parts.bolt.position.x, parts.bolt.position.y + 0.006, 0.0))
		"revolver":  # the cylinder swings out to the left on its crane
			_pivot("cylinder", parts.cylinder.position + Vector3(0.0, -0.022, -0.016))


func _pivot(part: String, at: Vector3) -> void:
	var p: Node3D = parts[part]
	var pivot := Node3D.new()
	pivot.name = part + "_pivot"
	pivot.position = at
	model.add_child(pivot)
	p.reparent(pivot, true)
	parts[part + "_pivot"] = pivot


func part(part_name: String) -> Node3D:
	return parts.get(part_name)


## Everything back to rest (weapon switch, cancelled reload).
func reset() -> void:
	for t: Tween in [_tween, _kick]:
		if t:
			t.kill()
	for n: Node3D in _rest:
		if n.get_parent() != _home(n):
			n.reparent(_home(n), false)
		n.transform = _rest[n]
		n.visible = true
	if _slide_locked and parts.has("slide"):
		parts.slide.position = _rest[parts.slide].origin + Vector3(-0.022, 0, 0)
	for t: Node3D in _hand_meta:
		t.set_meta("curl", _hand_meta[t][0])
		t.set_meta("thumb", _hand_meta[t][1])
	position = Vector3.ZERO
	if _drop_mag:
		_drop_t = -1.0
		_drop_mag.visible = false


func _home(n: Node3D) -> Node:
	if n == right_target or n == left_target:
		return self
	for k: String in ["cover", "bolt", "cylinder"]:
		if n == parts.get(k):
			return parts[k + "_pivot"] if parts.has(k + "_pivot") else model
	return model


# --- Shots -------------------------------------------------------------------

## A shot. empty = that was the last round (the pistol's slide stays back).
func fire(empty: bool) -> void:
	if _kick:
		_kick.kill()
	_kick = create_tween()
	match String(stats.view_model):
		"pistol":
			# Slide slams back (the casing leaves at the back of its travel)
			# and springs home; after the last round it stays locked back.
			# The trigger and the index finger snap back meanwhile.
			var slide: Node3D = parts.slide
			var rest: Vector3 = _rest[slide].origin
			_kick.tween_property(slide, "position", rest + Vector3(-0.03, 0, 0), 0.022).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			_kick.tween_callback(eject.emit.bind(1))
			if empty:
				_slide_locked = true
				_kick.tween_property(slide, "position", rest + Vector3(-0.022, 0, 0), 0.03)
			else:
				_kick.tween_property(slide, "position", rest, 0.045).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
			var trig: Node3D = parts.get("trigger")
			if trig:
				var tr: Vector3 = _rest[trig].origin
				trig.position = tr + Vector3(-0.004, 0, 0)
				_kick.parallel().tween_property(trig, "position", tr, 0.09).set_delay(0.03)
			var curl: Array = (_hand_meta[right_target][0] as Array).duplicate()
			_kick.parallel().tween_method(func(v: float) -> void:
				var c := curl.duplicate()
				c[0] = curl[0] + v
				right_target.set_meta("curl", c), 0.18, 0.0, 0.1)
		"ak", "smg":
			var bolt: Node3D = parts.bolt
			var rest: Vector3 = _rest[bolt].origin
			var back := 0.075 if stats.view_model == "ak" else 0.03
			var t: float = minf(stats.fire_delay * 0.4, 0.04)
			_kick.tween_property(bolt, "position", rest + Vector3(-back, 0, 0), t)
			_kick.tween_property(bolt, "position", rest, t * 1.2)
			eject.emit(1)
		"revolver":
			var cyl: Node3D = parts.cylinder
			var r: Vector3 = cyl.rotation
			_kick.tween_interval(0.05)
			_kick.tween_property(cyl, "rotation", Vector3(r.x + TAU / 6.0, r.y, r.z), 0.09).set_trans(Tween.TRANS_SINE)
			_kick.tween_callback(func() -> void: cyl.rotation.x = wrapf(cyl.rotation.x, 0.0, TAU))
		"shotgun", "sniper":
			pass  # worked in cycle()
		_:
			eject.emit(1)
	_kick.tween_interval(0.01)


## Pump / bolt after a shot, `delay` s after it (shotgun, sniper).
func cycle(delay: float) -> void:
	_new_tween()
	match String(stats.view_model):
		"shotgun":
			var pump: Node3D = parts.pump
			var rest: Vector3 = _rest[pump].origin
			_tween.tween_interval(delay)
			_tween.tween_property(pump, "position", rest + Vector3(-0.075, 0, 0), 0.13).set_trans(Tween.TRANS_SINE)
			_tween.tween_callback(eject.emit.bind(1))
			_tween.tween_property(pump, "position", rest, 0.13).set_trans(Tween.TRANS_SINE)
		"sniper":
			_tween.tween_interval(delay - 0.12)
			_bolt_cycle(_tween, true)


# Sniper bolt: the right hand leaves the grip, lifts the bolt, pulls it back
# (the casing flies), pushes it home and goes back to the grip.
func _bolt_cycle(t: Tween, with_casing: bool) -> void:
	var pivot: Node3D = parts.bolt_pivot
	var r0: Vector3 = pivot.rotation
	var p0: Vector3 = pivot.position
	var knob := _knob()
	t.tween_property(right_target, "position", knob, 0.12).set_trans(Tween.TRANS_SINE)
	t.parallel().tween_property(right_target, "basis", _hand_basis("pinch"), 0.12)
	t.tween_callback(right_target.reparent.bind(pivot, true))
	t.tween_property(pivot, "rotation", r0 + Vector3(-1.1, 0, 0), 0.08)
	t.tween_property(pivot, "position", p0 + Vector3(-0.085, 0, 0), 0.1).set_trans(Tween.TRANS_SINE)
	if with_casing:
		t.tween_callback(eject.emit.bind(1))
	t.tween_property(pivot, "position", p0, 0.09).set_trans(Tween.TRANS_SINE)
	t.tween_property(pivot, "rotation", r0, 0.07)
	t.tween_callback(right_target.reparent.bind(self, true))
	t.tween_property(right_target, "transform", _rest[right_target], 0.14).set_trans(Tween.TRANS_SINE)


# The sniper's bolt knob (the bolt part's point furthest to the right).
func _knob() -> Vector3:
	var bolt: Node3D = parts.bolt
	var best := bolt.global_position
	var mi := bolt as MeshInstance3D
	if mi:
		var hi := -INF
		for v: Vector3 in mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
			var g := mi.global_transform * v
			var l := to_local(g)
			if l.z > hi:
				hi = l.z
				best = g
	return to_local(best) + Vector3(0, 0.0, 0.012)


func _hand_basis(hand: String) -> Basis:
	var h: Dictionary = HANDS[hand]
	var fwd: Vector3 = h.fwd.normalized()
	var palm: Vector3 = (h.palm - fwd * fwd.dot(h.palm)).normalized()
	return Basis(fwd.cross(palm), fwd, palm)


func _new_tween() -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()


# --- Reload --------------------------------------------------------------------

## Reload animation over `time` s (already sped up by upgrades: f = time /
## stats.reload_time scales the sound cue times). `pose` is the node that
## tilts the whole gun (player.gd's WeaponReload).
func reload(time: float, pose: Node3D) -> void:
	reset()
	_new_tween()
	_tween.set_parallel(true)
	var f: float = time / stats.reload_time
	var cues: Array = stats.reload_sounds.map(func(e: Array) -> float: return e[0] * f)
	# Muzzle up a little and inwards, top rolled right: the magazine well
	# turns towards the left hand.
	var tilt := Vector3(deg_to_rad(10), deg_to_rad(8), deg_to_rad(-24))
	var lift := Vector3(-0.015, 0.02, 0.02)
	match String(stats.view_model):
		"pistol":
			_pistol_reload(cues, f)
			tilt = Vector3(deg_to_rad(10), deg_to_rad(14), deg_to_rad(-32))
			lift = Vector3(-0.02, 0.035, -0.01)
		"rifle":
			_mag_swap(cues[0], cues[1], Vector3(0.02, -0.26, 0.0), 0.0)
		"ak":
			_mag_swap(cues[0], cues[1], Vector3(0.06, -0.26, 0.0), 0.5)
			_charge(cues[2], parts.bolt, 0.08)
		"smg":
			_mag_swap(cues[0], cues[1], Vector3(0.02, -0.26, 0.0), 0.0)
			_charge(cues[2], parts.charger, 0.065, parts.bolt)
		"sniper":
			_mag_swap(cues[0], cues[1], Vector3(0.0, -0.22, 0.0), 0.0)
			var t := create_tween()
			t.tween_interval(cues[2] - 0.1 * f)
			_bolt_cycle(t, false)
		"lmg":
			_lmg_reload(cues, f)
			tilt = Vector3(deg_to_rad(6), deg_to_rad(8), deg_to_rad(-16))
		"revolver":
			_revolver_reload(cues, f)
			tilt = Vector3(deg_to_rad(18), deg_to_rad(10), deg_to_rad(30))
			lift = Vector3(-0.03, 0.04, 0.03)
		"shotgun":
			_shotgun_reload(cues, f)
			tilt = Vector3(deg_to_rad(6), deg_to_rad(6), deg_to_rad(-30))
			lift = Vector3(-0.015, 0.02, 0.02)
	# Tilt the gun towards the left hand, hold, bring it back.
	if pose:
		var into := minf(0.3, time * 0.18)
		_tween.tween_property(pose, "rotation", tilt, into).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_tween.tween_property(pose, "position", lift, into).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_tween.tween_property(pose, "rotation", Vector3.ZERO, into).set_delay(time - into).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_tween.tween_property(pose, "position", Vector3.ZERO, into).set_delay(time - into).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


# Left hand: to the magazine just before `t_out`, pulls it out along `away`
# (gun space; `rock` rad tips it forward first, for the curved AK magazine),
# the new one comes back up along the same path and seats at `t_in`; then the
# hand returns to its hold.
func _mag_swap(t_out: float, t_in: float, away: Vector3, rock: float) -> void:
	var mag: Node3D = parts.get("mag")
	if mag == null:
		return
	var rest: Transform3D = _rest[mag]
	var reach := maxf(t_out - 0.18, 0.0)
	var grab := rest.origin + Vector3(0.0, -0.045, -0.018)
	_tween.tween_property(left_target, "position", grab, t_out - reach + 0.05).set_delay(reach).set_trans(Tween.TRANS_SINE)
	_tween.tween_property(left_target, "basis", _hand_basis("hold"), t_out - reach + 0.05).set_delay(reach)
	_tween.tween_callback(left_target.reparent.bind(mag, true)).set_delay(t_out + 0.05)
	var out := rest
	out.origin += away
	out.basis = out.basis.rotated(Vector3.BACK, -rock)
	var gone := (t_in - t_out) * 0.42
	_tween.tween_property(mag, "transform", out, gone).set_delay(t_out + 0.05).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	# Back up with a fresh one (the same mesh) and seat it.
	_tween.tween_property(mag, "transform", rest, t_in - t_out - gone - 0.05).set_delay(t_out + 0.05 + gone).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_tween.tween_callback(left_target.reparent.bind(self, true)).set_delay(t_in)
	_tween.tween_property(left_target, "transform", _rest[left_target], 0.22).set_delay(t_in + 0.02).set_trans(Tween.TRANS_SINE)


# Pistol (cues: mag release, magazine seated, slide release if empty; f =
# speed factor): the gun tilts (reload()), the left hand lets go and drops
# below the magazine well, the right thumb presses the release and the empty
# magazine falls out; the left hand goes down out of view, comes back with a
# fresh magazine (the hand stays on it), lines it up under the well and
# pushes it home (the gun bumps). An empty gun's slide then snaps forward
# under the right thumb. The left hand goes back round the grip.
func _pistol_reload(cues: Array, f: float) -> void:
	var mag: Node3D = parts.get("mag")
	if mag == null:
		return
	var rest: Transform3D = _rest[mag]
	var t_out: float = cues[0]
	var t_in: float = cues[1]
	var hold := _hand_basis("hold")
	# Where the palm sits on a magazine: on its left side, low.
	var grip_on := Vector3(0.0, -0.05, -0.02)
	# 1. Left hand off the grip, under the well, ready to catch nothing.
	var under := rest.origin + grip_on + Vector3(0.0, -0.06, -0.03)
	_tween.tween_property(left_target, "position", under, 0.22 * f).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(left_target, "basis", hold, 0.22 * f).set_trans(Tween.TRANS_SINE)
	_tween.tween_method(_set_curl.bind(left_target, -1.0), 0.0, 1.0, 0.22 * f)
	# 2. Right thumb on the release.
	var thumb0: float = _hand_meta[right_target][1]
	_tween.tween_method(func(v: float) -> void: right_target.set_meta("thumb", v), thumb0, 0.95, 0.1 * f).set_delay(t_out - 0.12 * f)
	_tween.tween_method(func(v: float) -> void: right_target.set_meta("thumb", v), 0.95, thumb0, 0.12 * f).set_delay(t_out + 0.04 * f)
	# 3. The empty magazine drops (the copy falls; the real one is hidden
	# until the hand brings it back).
	_tween.tween_callback(_drop_magazine).set_delay(t_out)
	# 4. Left hand down out of view (to the pouch), back with the new one.
	var pouch := Transform3D(rest.basis.rotated(Vector3.BACK, 0.5).rotated(Vector3.RIGHT, -0.4),
			rest.origin + Vector3(-0.12, -0.34, -0.1))
	var below := rest
	below.origin += Vector3(0.0, -0.055, 0.0)
	var t_down := t_out + 0.05 * f
	var t_pouch := t_out + 0.3 * f
	var t_below := t_in - 0.12 * f
	_tween.tween_property(left_target, "position", pouch.origin + grip_on, t_pouch - t_down).set_delay(t_down).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_tween.tween_callback(func() -> void:
		mag.transform = pouch
		mag.visible = true
		left_target.reparent(mag, true)).set_delay(t_pouch)
	# Up and lined up under the well (the hand rides on the magazine)...
	_tween.tween_property(mag, "transform", below, t_below - t_pouch - 0.04 * f).set_delay(t_pouch + 0.04 * f).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	# ...then pushed home, and the gun takes the bump.
	_tween.tween_property(mag, "transform", rest, t_in - t_below).set_delay(t_below).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_bump(t_in, Vector3(0.0, 0.009, 0.0))
	_tween.tween_callback(left_target.reparent.bind(self, true)).set_delay(t_in + 0.03 * f)
	var t_back := t_in + 0.06 * f
	if _slide_locked:
		# 5. Slide release: thumb down on the stop, the slide flies home.
		var t_rel: float = cues[2] if cues.size() > 2 else t_in + 0.28 * f
		_tween.tween_method(func(v: float) -> void: right_target.set_meta("thumb", v), thumb0, 1.0, 0.1 * f).set_delay(t_rel - 0.1 * f)
		_tween.tween_method(func(v: float) -> void: right_target.set_meta("thumb", v), 1.0, thumb0, 0.15 * f).set_delay(t_rel + 0.03 * f)
		var slide: Node3D = parts.slide
		_tween.tween_property(slide, "position", _rest[slide].origin, 0.035).set_delay(t_rel).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		_tween.tween_callback(func() -> void: _slide_locked = false).set_delay(t_rel)
		_bump(t_rel + 0.03, Vector3(-0.004, 0.006, 0.0))
	# 6. Left hand back round the grip.
	_tween.tween_property(left_target, "transform", _rest[left_target], 0.3 * f).set_delay(t_back).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_method(_set_curl.bind(left_target, 1.0), 0.0, 1.0, 0.3 * f).set_delay(t_back)


# Blends a hand's finger curl between its hold and the "hold" (magazine)
# shape: towards = -1 goes to the magazine shape, 1 back to the hold.
func _set_curl(v: float, t: Node3D, towards: float) -> void:
	var a: Array = _hand_meta[t][0]
	var b: Array = HANDS.hold.curl
	var k := v if towards < 0.0 else 1.0 - v
	var c := []
	for i in a.size():
		c.append(lerpf(a[i], b[i], k))
	t.set_meta("curl", c)


func _drop_magazine() -> void:
	var mag: Node3D = parts.mag
	_drop_from = _view_root.global_transform.affine_inverse() * mag.global_transform
	var out := _view_root.global_basis.inverse() * (mag.global_basis * Vector3.DOWN)
	_drop_vel = out.normalized() * 0.45
	_drop_spin = Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(4, 6))
	_drop_mag.visible = true
	_drop_t = 0.0
	_drop_mag.global_transform = mag.global_transform
	mag.visible = false


# The whole gun (and the hands on it) jolts by `by` (parent space) at `t`.
func _bump(t: float, by: Vector3) -> void:
	_tween.tween_property(self, "position", by, 0.035).set_delay(t).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "position", Vector3.ZERO, 0.14).set_delay(t + 0.035).set_trans(Tween.TRANS_SINE)


# Left hand pulls a charging handle / bolt back `dist` m at `t` and lets go
# (`also` moves with it, e.g. the bolt inside an AR).
func _charge(t: float, handle: Node3D, dist: float, also: Node3D = null) -> void:
	if handle == null:
		return
	var rest: Vector3 = _rest[handle].origin
	var at := rest + Vector3(0.0, 0.01, 0.03 if handle.name == "bolt" else 0.0)
	var start := t - 0.12
	_tween.tween_property(left_target, "position", at, 0.16).set_delay(start - 0.16).set_trans(Tween.TRANS_SINE)
	_tween.tween_property(left_target, "basis", _hand_basis("pinch"), 0.16).set_delay(start - 0.16)
	_tween.tween_callback(left_target.reparent.bind(handle, true)).set_delay(start)
	_tween.tween_property(handle, "position", rest + Vector3(-dist, 0, 0), 0.1).set_delay(start).set_trans(Tween.TRANS_SINE)
	_tween.tween_property(handle, "position", rest, 0.06).set_delay(start + 0.14)
	if also:
		var r2: Vector3 = _rest[also].origin
		_tween.tween_property(also, "position", r2 + Vector3(-dist, 0, 0), 0.1).set_delay(start)
		_tween.tween_property(also, "position", r2, 0.06).set_delay(start + 0.14)
	_tween.tween_callback(left_target.reparent.bind(self, true)).set_delay(start + 0.12)
	_tween.tween_property(left_target, "transform", _rest[left_target], 0.2).set_delay(start + 0.2).set_trans(Tween.TRANS_SINE)



# LMG: open the feed cover, swap the box, close the cover, charge.
func _lmg_reload(cues: Array, f: float) -> void:
	var cover: Node3D = parts.cover_pivot
	var c0: Vector3 = cover.rotation
	var lift_at: Vector3 = to_local(parts.cover.global_position) + Vector3(-0.08, 0.02, 0.0)
	_tween.tween_property(left_target, "position", lift_at, 0.25 * f).set_trans(Tween.TRANS_SINE)
	_tween.tween_property(left_target, "basis", _hand_basis("pinch"), 0.25 * f)
	_tween.tween_callback(left_target.reparent.bind(parts.cover, true)).set_delay(0.25 * f)
	_tween.tween_property(cover, "rotation", c0 + Vector3(0, 0, deg_to_rad(-75)), 0.25 * f).set_delay(0.25 * f).set_trans(Tween.TRANS_SINE)
	_tween.tween_callback(left_target.reparent.bind(self, true)).set_delay(0.5 * f)
	_mag_swap(maxf(cues[0], 0.75 * f), cues[1], Vector3(0.0, -0.24, -0.06), 0.0)
	var close: float = cues[1] + 0.45 * f
	_tween.tween_property(left_target, "position", lift_at + Vector3(0.0, 0.06, 0.0), 0.2 * f).set_delay(close - 0.2 * f)
	_tween.tween_property(cover, "rotation", c0, 0.14 * f).set_delay(close).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_tween.tween_property(left_target, "transform", _rest[left_target], 0.25 * f).set_delay(close + 0.15 * f)
	_charge(cues[2], parts.get("bolt"), 0.07)


# Revolver: swing the cylinder out, punch the empties out, load, close.
func _revolver_reload(cues: Array, f: float) -> void:
	var swing: Node3D = parts.cylinder_pivot
	var s0: Vector3 = swing.rotation
	var opened := s0 + Vector3(deg_to_rad(-85), 0, 0)
	var cyl: Node3D = parts.cylinder
	var front: Vector3 = _rest[cyl].origin + Vector3(0.05, -0.03, -0.04)
	# Left thumb pushes the cylinder out.
	_tween.tween_property(left_target, "position", front, 0.2 * f).set_trans(Tween.TRANS_SINE)
	_tween.tween_property(swing, "rotation", opened, 0.16 * f).set_delay(cues[0] + 0.05 * f).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween.tween_callback(eject.emit.bind(6)).set_delay(cues[1])
	# Hand away to fetch rounds, back to the cylinder's rear, then closes it.
	var fetch := front + Vector3(-0.08, -0.16, -0.05)
	_tween.tween_property(left_target, "position", fetch, 0.3 * f).set_delay(cues[1] + 0.1 * f).set_trans(Tween.TRANS_SINE)
	_tween.tween_property(left_target, "position", front + Vector3(-0.08, 0.0, -0.035), 0.3 * f).set_delay(cues[2] - 0.3 * f).set_trans(Tween.TRANS_SINE)
	_tween.tween_property(swing, "rotation", s0, 0.12 * f).set_delay(cues[3] - 0.05 * f).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_tween.tween_property(cyl, "rotation", Vector3.ZERO, 0.01).set_delay(cues[3])
	_tween.tween_property(left_target, "transform", _rest[left_target], 0.3 * f).set_delay(cues[3] + 0.05 * f).set_trans(Tween.TRANS_SINE)


# Shotgun: the left hand takes a shell to the loading port for each shell
# sound, then racks the pump.
func _shotgun_reload(cues: Array, f: float) -> void:
	var load_at := Vector3(0.2, -0.045, 0.012)
	var below := load_at + Vector3(-0.04, -0.12, 0.05)
	var pump: Node3D = parts.get("pump")
	for i in cues.size() - 1:
		var t: float = cues[i]
		_tween.tween_property(left_target, "position", below, 0.16 * f).set_delay(maxf(t - 0.32 * f, 0.0)).set_trans(Tween.TRANS_SINE)
		_tween.tween_property(left_target, "basis", _hand_basis("hold"), 0.16 * f).set_delay(maxf(t - 0.32 * f, 0.0))
		_tween.tween_property(left_target, "position", load_at, 0.14 * f).set_delay(t - 0.14 * f).set_trans(Tween.TRANS_SINE)
	var rack: float = cues[cues.size() - 1]
	_tween.tween_property(left_target, "transform", _rest[left_target], 0.2 * f).set_delay(rack - 0.32 * f).set_trans(Tween.TRANS_SINE)
	if pump:
		var rest: Vector3 = _rest[pump].origin
		_tween.tween_callback(left_target.reparent.bind(pump, true)).set_delay(rack - 0.1 * f)
		_tween.tween_property(pump, "position", rest + Vector3(-0.075, 0, 0), 0.13).set_delay(rack - 0.08 * f).set_trans(Tween.TRANS_SINE)
		_tween.tween_property(pump, "position", rest, 0.13).set_delay(rack - 0.08 * f + 0.15).set_trans(Tween.TRANS_SINE)
		_tween.tween_callback(left_target.reparent.bind(self, true)).set_delay(rack + 0.32)
