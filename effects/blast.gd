extends RefCounted
## Explosion damage shared by grenades and exploder enemies: enemies and the
## player inside the radius take damage that falls off with distance, walls
## and crates give cover, and the player's camera shakes. Also spawns the
## explosion visuals and sound (explosion.gd).

const Explosion := preload("res://effects/explosion.gd")
const Haptics := preload("res://effects/haptics.gd")
const LOS_MASK := 3              # walls and props that block the blast
const SHAKE_RANGE := 25.0        # camera shake fades out at this distance
const MAX_SHAKE := 1.2


## pos: where it goes off. source: the grenade or exploder itself (never
## damaged by its own blast). player: the player node (may be null).
static func detonate(source: Node3D, pos: Vector3, radius: float, max_damage: int,
		player: Node3D, player_radius: float, player_max_damage: int) -> void:
	var tree := source.get_tree()
	var space := source.get_world_3d().direct_space_state
	var exclude := _exclusions(tree, source, player)

	# Visuals and sound, with a scorch mark if the floor is just below.
	var fx := Explosion.new()
	tree.current_scene.add_child(fx)
	var down := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 0.1, pos + Vector3.DOWN * 1.0, LOS_MASK)
	down.exclude = exclude
	var ground := space.intersect_ray(down)
	if ground.is_empty():
		fx.setup(pos)
	else:
		fx.setup(pos, ground.normal, ground.position)

	var center := pos + Vector3.UP * 0.2
	for enemy: Node3D in tree.get_nodes_in_group("enemies"):
		if enemy == source:
			continue
		var chest := enemy.global_position + Vector3.UP * 1.1
		var dmg := damage_at(center.distance_to(chest), radius, max_damage)
		if dmg > 0 and _in_sight(space, center, chest, exclude):
			enemy.take_damage(dmg, chest, (chest - center).normalized())

	# Explosive barrels in range go up a moment later (chain reactions).
	for barrel: Node3D in tree.get_nodes_in_group("explosive_barrels"):
		if barrel == source or barrel.exploded:
			continue
		var mid := barrel.global_position + Vector3.UP * 0.5
		if center.distance_to(mid) < radius:
			var ex := exclude.duplicate()
			ex.append((barrel as CollisionObject3D).get_rid())
			if _in_sight(space, center, mid, ex):
				barrel.ignite()

	if is_instance_valid(player) and not player.get("is_dead"):
		var body := player.global_position + Vector3.UP * 1.0
		var d := center.distance_to(body)
		var dmg := damage_at(d, player_radius, player_max_damage)
		if dmg > 0 and _in_sight(space, center, body, exclude):
			player.take_damage(dmg)
		if player.has_method("add_shake"):
			player.add_shake(MAX_SHAKE * clampf(1.0 - d / SHAKE_RANGE, 0.0, 1.0))
		Haptics.explosion(clampf(1.0 - d / SHAKE_RANGE, 0.0, 1.0))


## Damage with linear falloff: `max_damage` at the centre, 0 at `radius`.
static func damage_at(distance: float, radius: float, max_damage: int) -> int:
	if distance >= radius:
		return 0
	return roundi(max_damage * (1.0 - distance / radius))


# True if nothing solid (walls, crates...) is between the blast and `target`.
static func _in_sight(space: PhysicsDirectSpaceState3D, from: Vector3, target: Vector3, exclude: Array[RID]) -> bool:
	var q := PhysicsRayQueryParameters3D.create(from, target, LOS_MASK)
	q.exclude = exclude
	return space.intersect_ray(q).is_empty()


# Enemies, the player and the source don't block the blast.
static func _exclusions(tree: SceneTree, source: Node, player: Node) -> Array[RID]:
	var ex: Array[RID] = []
	for n in [source, player]:
		if is_instance_valid(n) and n is CollisionObject3D:
			ex.append((n as CollisionObject3D).get_rid())
	for e in tree.get_nodes_in_group("enemies"):
		if e is CollisionObject3D:
			ex.append((e as CollisionObject3D).get_rid())
	return ex
