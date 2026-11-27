extends Node3D
## Spent casings thrown out of the player's gun. Cheap enough for phones:
##  - one MultiMesh per kind (pistol / rifle brass, red shotgun shells), so
##    all of them are 3 draw calls at most;
##  - no physics bodies: each casing flies on its own (gravity, spin), one ray
##    at spawn finds the floor below it, and it bounces there twice and lies
##    still until it fades;
##  - a fixed pool per kind; the oldest casing is reused when it runs out.
## They start at the view model's size (player.gd VIEW_SCALE) and grow to
## full size as they leave the gun, so they match both the gun and the floor.

const POOL := 24
const LIFE := 2.6            # s until a casing disappears
const GROW_TIME := 0.22      # s from view-model size to full size
const GRAVITY := 9.8
const BOUNCE := 0.3          # vertical speed kept per bounce
const MASK := 3              # world + props
const KINDS := {
	# radius, length (m), colour, metallic, roughness
	"pistol": [0.0048, 0.019, Color(0.86, 0.64, 0.27), 0.85, 0.32],
	"rifle": [0.0052, 0.042, Color(0.86, 0.64, 0.27), 0.85, 0.32],
	"shell": [0.0105, 0.062, Color(0.62, 0.08, 0.06), 0.1, 0.55],
}

var _sets := {}   # kind -> {mmi, items: Array[Dictionary], next: int}


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	for kind: String in KINDS:
		var k: Array = KINDS[kind]
		var mesh := CylinderMesh.new()
		mesh.top_radius = k[0]
		mesh.bottom_radius = k[0]
		mesh.height = k[1]
		mesh.radial_segments = 8
		mesh.rings = 1
		var mat := StandardMaterial3D.new()
		mat.albedo_color = k[2]
		mat.metallic = k[3]
		mat.roughness = k[4]
		mesh.material = mat
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = POOL
		mm.visible_instance_count = 0
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
		add_child(mmi)
		var items: Array[Dictionary] = []
		_sets[kind] = {"mmi": mmi, "items": items, "next": 0}


## Throws one casing of `kind` from `at` (world) with velocity `vel`;
## `start_scale` is its size relative to real at the start.
func spawn(kind: String, at: Vector3, basis: Basis, vel: Vector3, start_scale: float) -> void:
	if not _sets.has(kind):
		return
	var s: Dictionary = _sets[kind]
	var items: Array[Dictionary] = s.items
	var floor_y := at.y - 3.0
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space:
		var q := PhysicsRayQueryParameters3D.create(at, at + Vector3.DOWN * 3.0, MASK)
		q.exclude = _exclude()
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			floor_y = hit.position.y
	var c := {
		"pos": at, "vel": vel, "basis": basis,
		"spin": Vector3(randf_range(-30, 30), randf_range(-12, 12), randf_range(-30, 30)),
		"age": 0.0, "floor": floor_y + KINDS[kind][0], "bounces": 0, "start": start_scale,
	}
	if items.size() < POOL:
		items.append(c)
	else:
		items[s.next] = c
		s.next = (s.next + 1) % POOL


## Shows one casing of each kind at `at` (on = true) for the level's
## prewarm (main.gd), so their material is compiled before the first shot;
## on = false hides them again.
func warm(on: bool, at := Vector3.ZERO) -> void:
	for kind: String in _sets:
		var s: Dictionary = _sets[kind]
		if not (s.items as Array).is_empty():
			continue
		var mm: MultiMesh = s.mmi.multimesh
		mm.set_instance_transform(0, Transform3D(Basis(), at))
		mm.visible_instance_count = 1 if on else 0


## How many casings of `kind` are flying or lying around (tests).
func count(kind: String) -> int:
	return _sets[kind].items.size() if _sets.has(kind) else 0


func _exclude() -> Array[RID]:
	var out: Array[RID] = []
	var p := get_parent()
	if p is CollisionObject3D:
		out.append(p.get_rid())
	return out


func _process(delta: float) -> void:
	for kind: String in _sets:
		var s: Dictionary = _sets[kind]
		var items: Array[Dictionary] = s.items
		if items.is_empty():
			continue
		var mm: MultiMesh = s.mmi.multimesh
		var i := 0
		while i < items.size():
			var c: Dictionary = items[i]
			c.age += delta
			if c.age > LIFE:
				items.remove_at(i)
				s.next = 0
				continue
			var pos: Vector3 = c.pos
			var vel: Vector3 = c.vel
			var basis: Basis = c.basis
			var spin: Vector3 = c.spin
			if c.bounces < 3:
				vel.y -= GRAVITY * delta
				pos += vel * delta
				if spin.length_squared() > 0.0:
					basis = basis.rotated(spin.normalized(), spin.length() * delta)
				if pos.y < c.floor and vel.y < 0.0:
					pos.y = c.floor
					c.bounces += 1
					vel = Vector3(vel.x * 0.45, -vel.y * BOUNCE, vel.z * 0.45)
					spin *= 0.4
					if c.bounces >= 3 or vel.y < 0.4:
						c.bounces = 3
						# Lie on its side.
						var along := basis.y
						along.y = 0.0
						if along.length_squared() < 1e-4:
							along = Vector3.RIGHT
						along = along.normalized()
						basis = Basis(along.cross(Vector3.UP), along, Vector3.UP).orthonormalized()
				c.pos = pos
				c.vel = vel
				c.basis = basis
				c.spin = spin
			var grow := clampf(c.age / GROW_TIME, 0.0, 1.0)
			var sc: float = lerpf(c.start, 1.0, grow)
			# Shrink away at the end of its life.
			sc *= clampf((LIFE - c.age) / 0.3, 0.0, 1.0)
			mm.set_instance_transform(i, Transform3D(basis.scaled(Vector3.ONE * sc), pos))
			i += 1
		mm.visible_instance_count = items.size()
