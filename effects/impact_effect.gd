extends Node3D
## One-shot impact effect (sparks/dust or blood): fires every child particle
## emitter once, plays a random sound, then removes itself.

## Sounds to pick from at random (optional). Played by the child "Sound" node.
@export var sounds: Array = []
## Seconds before the effect node is freed (longer than the longest particle).
@export var lifetime := 1.5


## Call right after adding the effect to the scene tree.
func setup(pos: Vector3, normal: Vector3) -> void:
	global_position = pos + normal * 0.02
	orient_to_normal(self, normal)
	for child in get_children():
		if child is CPUParticles3D:
			child.restart()
	var sound := get_node_or_null("Sound") as AudioStreamPlayer3D
	if sound and not sounds.is_empty():
		sound.stream = sounds.pick_random()
		sound.pitch_scale = randf_range(0.9, 1.1)
		sound.play()


func _process(delta: float) -> void:
	lifetime -= delta
	if lifetime <= 0.0:
		queue_free()


## Rotates a node so its +Z axis points out of the surface along `normal`.
static func orient_to_normal(node: Node3D, normal: Vector3) -> void:
	var up := Vector3.UP if absf(normal.y) < 0.99 else Vector3.RIGHT
	node.look_at(node.global_position - normal, up)
