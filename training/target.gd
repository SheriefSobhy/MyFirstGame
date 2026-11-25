extends StaticBody3D
## A Training Arena target (training/training.gd), built in code: one merged
## vertex-coloured mesh each, so every target is a single draw call.
##  - "paper": a board with a dark silhouette. Never falls; keeps its bullet
##    holes. The silhouette's head counts as a headshot (double damage).
##  - "metal": a steel plate on a stand. Rings when hit, falls back and stands
##    up again after training_config.gd METAL_RESET seconds.
##  - "popup": an orange silhouette lying flat that the challenges raise
##    (pop_up()) and that drops when hit.
## Any kind slides left/right when move_half > 0 (moving targets).
## The gun treats targets like enemies (take_damage, is_head_hit, hp), so hit
## markers and damage numbers show and the training stats count them.

signal hit(target: Node3D, damage: int, headshot: bool)

const Config := preload("res://training_config.gd")
const Synth := preload("res://effects/synth_sounds.gd")
const BULLET_HOLE_SCENE := preload("res://effects/bullet_hole.tscn")
const FALL_TIME := 0.18
const RISE_TIME := 0.15
const PAPER_HP := 1000000   # paper never "dies"
const STAND := 0.6          # m: boards start this high (on their posts)...
const POPUP_STAND := 0.15   # ...pop-ups just above the ground

## "paper", "metal" or "popup".
@export var kind := "paper"
## Size multiplier (far targets are bigger).
@export var size := 1.0
## Moving targets: half the slide length along X (0 = it stays put), and speed.
@export var move_half := 0.0
@export var move_speed := 0.0

var hp := PAPER_HP
var is_up := true
## How many times it was hit (for tests).
var hits := 0

static var _meshes := {}
static var _materials := {}

var _st := STAND           # this target's stand height
var _hinge: Node3D
var _shape: CollisionShape3D
var _sound: AudioStreamPlayer3D
var _tween: Tween
var _reset_timer := 0.0
var _base_x := 0.0
var _move_time := 0.0


func _ready() -> void:
	collision_layer = 1
	collision_mask = 0
	_base_x = position.x
	_move_time = randf() * 10.0
	_st = stand_height(kind)
	_hinge = Node3D.new()
	_hinge.name = "Hinge"
	_hinge.position.y = _st + 0.35 * size if kind == "metal" else _st
	add_child(_hinge)
	var board := MeshInstance3D.new()
	board.name = "Board"
	board.mesh = _mesh(kind, size)
	board.position.y = -_hinge.position.y
	board.material_override = _material(kind)
	_hinge.add_child(board)
	# The stand or legs stay put while the face falls.
	var stand := MeshInstance3D.new()
	stand.name = "Stand"
	stand.mesh = _stand_mesh(kind, size)
	stand.material_override = _material("paper")
	add_child(stand)
	_shape = CollisionShape3D.new()
	var box := BoxShape3D.new()
	var face := face_size()
	box.size = Vector3(face.x, face.y, 0.08)
	_shape.shape = box
	_shape.position = Vector3(0, face_center_y(), 0)
	add_child(_shape)
	_sound = AudioStreamPlayer3D.new()
	_sound.unit_size = 12.0
	_sound.max_distance = 140.0
	_sound.position.y = face_center_y()
	add_child(_sound)
	hp = PAPER_HP if kind == "paper" else 1
	if kind == "popup":
		_set_down(true)


func _physics_process(delta: float) -> void:
	if move_half > 0.0:
		_move_time += delta
		position.x = _base_x + pingpong(_move_time * move_speed, move_half * 2.0) - move_half
	if _reset_timer > 0.0:
		_reset_timer -= delta
		if _reset_timer <= 0.0:
			stand_up()


static func stand_height(k: String) -> float:
	return POPUP_STAND if k == "popup" else STAND


## Width and height of the hittable face (m).
func face_size() -> Vector2:
	match kind:
		"metal":
			return Vector2(0.5, 0.5) * size
		_:
			return Vector2(0.62, 0.95) * size


## Height (local) of the middle of the face.
func face_center_y() -> float:
	if kind == "metal":
		return _st + 0.35 * size + 0.25 * size
	return _st + 0.475 * size


## The middle of the face in world space (for tests and the challenges).
func aim_point() -> Vector3:
	return to_global(Vector3(0, face_center_y(), 0.05))


## The silhouette's head (paper and pop-up targets), in world space.
func head_point() -> Vector3:
	return to_global(Vector3(0, _st + 0.78 * size, 0.05))


## Called by the gun (and explosions, which have no headshot).
func take_damage(amount: int, hit_position := Vector3.ZERO, hit_normal := Vector3.UP, headshot := false) -> void:
	if not is_up:
		return
	hits += 1
	match kind:
		"paper":
			_add_hole(hit_position, hit_normal)
			_wobble()
		"metal":
			_sound.stream = Synth.ding()
			_sound.pitch_scale = randf_range(0.95, 1.08)
			_sound.play()
			hp = 0
			fall()
			_reset_timer = Config.METAL_RESET
		"popup":
			_add_hole(hit_position, hit_normal)
			hp = 0
			fall()
	hit.emit(self, amount, headshot)


## True if a bullet from `from` along `dir` goes through the silhouette's head.
func is_head_hit(from: Vector3, dir: Vector3) -> bool:
	if kind == "metal" or not is_up:
		return false
	var lf := to_local(from)
	var ld := global_basis.inverse() * dir
	if absf(ld.z) < 1e-4:
		return false
	var t := (0.02 - lf.z) / ld.z
	if t < 0.0:
		return false
	var p := lf + ld * t
	return absf(p.x) <= 0.1 * size and absf(p.y - (_st + 0.78 * size)) <= 0.1 * size


## Knocked down (metal and pop-up targets): falls back, can't be hit.
func fall() -> void:
	is_up = false
	_shape.set_deferred("disabled", true)
	_animate(-PI / 2.0, FALL_TIME)


## Back up (metal plates after METAL_RESET, Reset Targets).
func stand_up() -> void:
	_reset_timer = 0.0
	is_up = true
	hp = PAPER_HP if kind == "paper" else 1
	_shape.set_deferred("disabled", false)
	_animate(0.0, RISE_TIME)


## Pop-up targets: rise (with a blip) for the challenges.
func pop_up() -> void:
	if kind != "popup":
		return
	_clear_holes()
	_sound.stream = Synth.blip()
	_sound.pitch_scale = 1.0
	_sound.play()
	stand_up()


## Pop-up targets: back down without being hit.
func pop_down() -> void:
	if is_up:
		fall()
		hp = 0


## Reset Targets: everything up (pop-ups down) and bullet holes gone.
func reset() -> void:
	_clear_holes()
	hits = 0
	if kind == "popup":
		_set_down(true)
	else:
		stand_up()


func _set_down(instant: bool) -> void:
	is_up = false
	hp = 0
	_reset_timer = 0.0
	_shape.set_deferred("disabled", true)
	if instant:
		if _tween:
			_tween.kill()
		_hinge.rotation.x = -PI / 2.0
	else:
		_animate(-PI / 2.0, FALL_TIME)


func _animate(angle: float, time: float) -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT if angle == 0.0 else Tween.EASE_IN)
	_tween.tween_property(_hinge, "rotation:x", angle, time)


# Paper: a small shake back when hit.
func _wobble() -> void:
	if _tween and _tween.is_running():
		return
	_tween = create_tween().set_trans(Tween.TRANS_SINE)
	_tween.tween_property(_hinge, "rotation:x", -0.06, 0.05)
	_tween.tween_property(_hinge, "rotation:x", 0.0, 0.15)


func _add_hole(pos: Vector3, normal: Vector3) -> void:
	if pos == Vector3.ZERO:
		return  # explosions
	var hole: Node3D = BULLET_HOLE_SCENE.instantiate()
	_hinge.add_child(hole)
	hole.setup(pos, normal)
	hole.add_to_group("target_holes")


func _clear_holes() -> void:
	for h in _hinge.get_children():
		if h.is_in_group("target_holes"):
			h.queue_free()


# --- Looks: one merged vertex-coloured mesh per kind and size ----------------------

static func _material(k: String) -> StandardMaterial3D:
	var key := "metal" if k == "metal" else "paper"
	if not _materials.has(key):
		var m := StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.vertex_color_is_srgb = true
		if key == "metal":
			m.metallic = 0.65
			m.roughness = 0.35
		else:
			m.roughness = 0.9
		_materials[key] = m
	return _materials[key]


static func _mesh(k: String, s: float) -> ArrayMesh:
	var key := "%s_%.2f" % [k, s]
	if _meshes.has(key):
		return _meshes[key]
	var b := _batch()
	var st := stand_height(k)
	if k == "metal":
		var steel := Color(0.62, 0.64, 0.66)
		var y := st + 0.35 * s + 0.25 * s
		_cyl(b, 0.25 * s, 0.03, Transform3D(Basis(Vector3.RIGHT, PI / 2.0), Vector3(0, y, 0)), steel, 20)
		_box(b, Vector3(0.08, 0.08, 0.02) * s, Vector3(0, y, 0.02), Color(0.85, 0.2, 0.15))  # aim spot
		_box(b, Vector3(0.06, 0.1, 0.04) * s, Vector3(0, st + 0.35 * s + 0.02, 0), steel)  # hinge
	else:
		var board := Color(0.92, 0.86, 0.72) if k == "paper" else Color(1.0, 0.55, 0.15)
		var dark := Color(0.12, 0.12, 0.13)
		var mid := st + 0.475 * s
		_box(b, Vector3(0.62 * s, 0.95 * s, 0.03), Vector3(0, mid, 0), board)
		_box(b, Vector3(0.4 * s, 0.55 * s, 0.01), Vector3(0, st + 0.33 * s, 0.018), dark)      # body
		_box(b, Vector3(0.2 * s, 0.2 * s, 0.01), Vector3(0, st + 0.78 * s, 0.018), dark)       # head
		_box(b, Vector3(0.12 * s, 0.12 * s, 0.01), Vector3(0, st + 0.4 * s, 0.024), board)     # chest ring
		_box(b, Vector3(0.05 * s, 0.05 * s, 0.01), Vector3(0, st + 0.4 * s, 0.03), Color(0.85, 0.2, 0.15))
	_meshes[key] = _commit(b)
	return _meshes[key]


# What doesn't fall: the plate's post and foot, the paper board's wooden legs,
# the pop-up's low base.
static func _stand_mesh(k: String, s: float) -> ArrayMesh:
	var key := "stand_%s_%.2f" % [k, s]
	if _meshes.has(key):
		return _meshes[key]
	var b := _batch()
	var dark := Color(0.2, 0.2, 0.22)
	match k:
		"metal":
			var top := STAND + 0.35 * s
			_box(b, Vector3(0.06, top, 0.06), Vector3(0, top * 0.5, -0.04), dark)
			_box(b, Vector3(0.5 * s, 0.05, 0.3), Vector3(0, 0.025, -0.04), dark)
		"paper":
			for x in [-0.22, 0.22]:
				_box(b, Vector3(0.05, STAND + 0.1, 0.05), Vector3(x * s, (STAND + 0.1) * 0.5, -0.03), Color(0.35, 0.25, 0.15))
		_:
			_box(b, Vector3(0.75 * s, POPUP_STAND, 0.25), Vector3(0, POPUP_STAND * 0.5, -0.05), dark)
	_meshes[key] = _commit(b)
	return _meshes[key]


static func _batch() -> Dictionary:
	return {"v": PackedVector3Array(), "n": PackedVector3Array(), "c": PackedColorArray(), "i": PackedInt32Array()}


static func _append(b: Dictionary, arr: Array, xf: Transform3D, color: Color) -> void:
	var base: int = b.v.size()
	var nb := xf.basis.inverse().transposed()
	for v: Vector3 in arr[Mesh.ARRAY_VERTEX]:
		b.v.append(xf * v)
		b.c.append(color)
	for n: Vector3 in arr[Mesh.ARRAY_NORMAL]:
		b.n.append((nb * n).normalized())
	for j: int in arr[Mesh.ARRAY_INDEX]:
		b.i.append(base + j)


static func _box(b: Dictionary, sz: Vector3, center: Vector3, color: Color) -> void:
	var m := BoxMesh.new()
	m.size = sz
	_append(b, m.get_mesh_arrays(), Transform3D(Basis(), center), color)


static func _cyl(b: Dictionary, radius: float, height: float, xf: Transform3D, color: Color, segs: int) -> void:
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = height
	m.radial_segments = segs
	m.rings = 1
	_append(b, m.get_mesh_arrays(), xf, color)


static func _commit(b: Dictionary) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = b.v
	arrays[Mesh.ARRAY_NORMAL] = b.n
	arrays[Mesh.ARRAY_COLOR] = b.c
	arrays[Mesh.ARRAY_INDEX] = b.i
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
