extends MeshInstance3D
## A bullet hole "decal": a small dark quad stuck to a surface.
## (Real Decal nodes aren't supported by the Compatibility renderer.)

const ImpactEffect := preload("res://effects/impact_effect.gd")
const MAX_HOLES := 30      # oldest holes are removed beyond this
const LIFETIME := 12.0     # seconds before a hole fades out
const FADE_TIME := 1.0

var _age := 0.0


## Call right after adding the hole to the scene tree.
func setup(pos: Vector3, normal: Vector3) -> void:
	global_position = pos + normal * 0.005  # tiny offset avoids z-fighting
	ImpactEffect.orient_to_normal(self, normal)
	rotate_object_local(Vector3.BACK, randf() * TAU)
	scale = Vector3.ONE * randf_range(0.8, 1.2)
	add_to_group("bullet_holes")
	var holes := get_tree().get_nodes_in_group("bullet_holes")
	if holes.size() > MAX_HOLES:
		holes[0].queue_free()


func _process(delta: float) -> void:
	_age += delta
	if _age > LIFETIME:
		transparency = clampf((_age - LIFETIME) / FADE_TIME, 0.0, 1.0)
		if _age > LIFETIME + FADE_TIME:
			queue_free()
