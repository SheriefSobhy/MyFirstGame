extends RefCounted
## Helpers for the gun models. All the models have the barrel along +X, but
## they come in different sizes, so instead of hand-tuning a scale and muzzle
## position for each gun, they're measured from the mesh once at load.


## Returns {"aabb": AABB, "tip": Vector3} in the model's own space.
## "tip" is the centre of the barrel's end: the average of the vertices in the
## front-most 3% of the gun.
static func measure(model: Node3D) -> Dictionary:
	var points := PackedVector3Array()
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		var xform := mi.transform
		var p := mi.get_parent()
		while p != model and p is Node3D:
			xform = (p as Node3D).transform * xform
			p = p.get_parent()
		for s in mi.mesh.get_surface_count():
			for v: Vector3 in mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
				points.append(xform * v)
	var aabb := AABB(points[0], Vector3.ZERO)
	for v in points:
		aabb = aabb.expand(v)
	var front := aabb.end.x - aabb.size.x * 0.03
	var tip := Vector3.ZERO
	var count := 0
	for v in points:
		if v.x >= front:
			tip += v
			count += 1
	tip /= count
	tip.x = aabb.end.x
	return {"aabb": aabb, "tip": tip}


## Turns off shadows on every mesh under `node` (view models, pickups...).
static func no_shadows(node: Node) -> void:
	for mi: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## The top of the gun at `x` (along the barrel), in the model's own space:
## the highest vertex within 4% of the gun's length of that spot. Used as the
## iron sight line when aiming down the sights.
static func top_at(model: Node3D, aabb: AABB, x: float) -> Vector3:
	var band := aabb.size.x * 0.04
	var top := aabb.position.y
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		var xform := mi.transform
		var p := mi.get_parent()
		while p != model and p is Node3D:
			xform = (p as Node3D).transform * xform
			p = p.get_parent()
		for s in mi.mesh.get_surface_count():
			for v: Vector3 in mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
				var w := xform * v
				if absf(w.x - x) <= band:
					top = maxf(top, w.y)
	return Vector3(x, top, aabb.get_center().z)


## Adds a small reflex (red dot) sight on top of the gun at `spot` (model
## space, from top_at). `model_scale` is the scale the model is drawn at, so
## the sight can be built in metres. Returns the centre of the sight window
## in model space: line that up with the camera to aim through it.
## Made of boxes, a tinted glass quad and a glowing dot; no image files.
static func add_red_dot(model: Node3D, spot: Vector3, model_scale: float) -> Vector3:
	var sight := Node3D.new()
	sight.name = "RedDotSight"
	sight.position = spot
	sight.scale = Vector3.ONE / model_scale  # children below are in metres
	model.add_child(sight)

	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.07, 0.07, 0.08)
	metal.metallic = 0.6
	metal.roughness = 0.45
	# Base, two side posts and a top bar framing the window.
	_box(sight, metal, Vector3(0.036, 0.006, 0.022), Vector3(0.0, 0.003, 0.0))
	_box(sight, metal, Vector3(0.007, 0.026, 0.003), Vector3(0.0, 0.019, -0.0125))
	_box(sight, metal, Vector3(0.007, 0.026, 0.003), Vector3(0.0, 0.019, 0.0125))
	_box(sight, metal, Vector3(0.007, 0.003, 0.028), Vector3(0.0, 0.0335, 0.0))

	var window_center := Vector3(0.0, 0.019, 0.0)
	var glass := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.022, 0.026)
	glass.mesh = quad
	var glass_mat := StandardMaterial3D.new()
	glass_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	glass_mat.albedo_color = Color(0.55, 0.8, 1.0, 0.12)
	glass.material_override = glass_mat
	glass.position = window_center
	glass.rotation.y = PI / 2.0  # face along the barrel
	sight.add_child(glass)

	var dot := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.0009
	sphere.height = 0.0018
	sphere.radial_segments = 8
	sphere.rings = 4
	dot.mesh = sphere
	var dot_mat := StandardMaterial3D.new()
	dot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dot_mat.albedo_color = Color(1.0, 0.12, 0.05)
	dot.material_override = dot_mat
	dot.position = window_center
	sight.add_child(dot)

	return spot + window_center / model_scale


static func _box(parent: Node3D, material: Material, size: Vector3, pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.material_override = material
	mi.position = pos
	parent.add_child(mi)
