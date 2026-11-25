extends Node3D
## The Training Arena's weapon rack (training/training.gd): one slot per
## weapon in weapon_stats.gd, in a row along the node's X axis, facing its +Z.
## Each slot shows the gun (with its Armory skin) on a pegboard with its name.
## Walk up to a slot and press E / tap TAKE to switch to that gun.
## Built in code: the boards are one merged mesh, the guns their own models.

const Weapons := preload("res://weapon_stats.gd")
const WeaponModel := preload("res://weapon_model.gd")
const WeaponSkins := preload("res://weapon_skins.gd")
const SLOT_WIDTH := 1.5     # m between slot centres
const GUN_HEIGHT := 1.35    # m, where the guns hang
const BOARD_SIZE := Vector2(1.3, 1.1)

var _models: Array[Node3D] = []


func _ready() -> void:
	var board_mesh := _build_boards()
	var boards := MeshInstance3D.new()
	boards.name = "Boards"
	boards.mesh = board_mesh
	add_child(boards)
	for i in Weapons.LIST.size():
		var w: Dictionary = Weapons.LIST[i]
		var at := slot_local(i)
		var model: Node3D = w.model.instantiate()
		var aabb: AABB = WeaponModel.measure(model).aabb
		var s: float = w.pickup_length / aabb.size.x
		var basis := Basis.from_scale(Vector3.ONE * s)
		model.transform = Transform3D(basis, at + Vector3(0, GUN_HEIGHT, 0.12) - basis * aabb.get_center())
		WeaponSkins.apply(model, Progress.skin_of(w.name))
		add_child(model)
		_models.append(model)
		var label := Label3D.new()
		label.text = w.name
		label.font_size = 56
		label.pixel_size = 0.0035
		label.outline_size = 10
		label.modulate = Color(1.0, 0.85, 0.45)
		label.position = at + Vector3(0, GUN_HEIGHT - 0.42, 0.1)
		add_child(label)


## Slot i's spot on the floor in front of the rack, local.
func slot_local(i: int) -> Vector3:
	var n := Weapons.LIST.size()
	return Vector3((i - (n - 1) * 0.5) * SLOT_WIDTH, 0, 0)


## Slot i's spot in world space (in front of the boards, on the floor).
func slot_position(i: int) -> Vector3:
	return to_global(slot_local(i) + Vector3(0, 0, 0.6))


## The slot nearest to `pos` within `reach` m (flat distance), or -1.
func nearest(pos: Vector3, reach: float) -> int:
	var best := -1
	var best_d := reach
	for i in Weapons.LIST.size():
		var p := slot_position(i)
		var d := Vector2(p.x - pos.x, p.z - pos.z).length()
		if d < best_d:
			best_d = d
			best = i
	return best


# Pegboards with a frame and two pegs per slot, one mesh.
func _build_boards() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat normals
	var board := Color(0.78, 0.74, 0.66)
	var frame := Color(0.18, 0.18, 0.2)
	var peg := Color(0.6, 0.6, 0.62)
	for i in Weapons.LIST.size():
		var at := slot_local(i) + Vector3(0, GUN_HEIGHT, 0)
		_box(st, Vector3(BOARD_SIZE.x, BOARD_SIZE.y, 0.05), at + Vector3(0, -0.05, 0), board)
		_box(st, Vector3(BOARD_SIZE.x + 0.08, 0.06, 0.08), at + Vector3(0, BOARD_SIZE.y * 0.5 - 0.05, 0.02), frame)
		_box(st, Vector3(BOARD_SIZE.x + 0.08, 0.06, 0.08), at + Vector3(0, -BOARD_SIZE.y * 0.5 - 0.05, 0.02), frame)
		for x in [-0.3, 0.3]:
			_box(st, Vector3(0.03, 0.03, 0.16), at + Vector3(x, -0.08, 0.08), peg)
	# A shelf along the bottom.
	var n := Weapons.LIST.size()
	_box(st, Vector3(n * SLOT_WIDTH, 0.05, 0.4), Vector3(0, GUN_HEIGHT - BOARD_SIZE.y * 0.5 - 0.12, 0.15), frame)
	st.generate_normals()
	var mesh := st.commit()
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = 0.85
	mesh.surface_set_material(0, m)
	return mesh


func _box(st: SurfaceTool, size: Vector3, center: Vector3, color: Color) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	var arr := bm.get_mesh_arrays()
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	st.set_color(color)
	for j: int in arr[Mesh.ARRAY_INDEX]:
		st.add_vertex(v[j] + center)
