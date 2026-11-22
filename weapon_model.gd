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
