extends SceneTree
## Automated check of the enemy types and waves, run against the real main scene:
##   godot --headless --path . --script res://tools/test_enemies.gd
## Prints PASS/FAIL per check and exits with code 1 if anything failed.
## With `-- --shots <folder>` (and without --headless) it also saves
## screenshots of the enemy line-up, a soldier aiming, the boss bar and more.

const Types := preload("res://enemy_types.gd")

var main: Node
var player: Node
var hud: Node
var failures := 0
var shots_dir := ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--shots")
	if i >= 0 and i + 1 < args.size():
		shots_dir = args[i + 1]
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		failures += 1


func frames(n: int) -> void:
	for i in n:
		await physics_frame


func seconds(t: float) -> void:
	await create_timer(t, true, true).timeout


func _run() -> void:
	change_scene_to_file("res://main.tscn")
	await frames(10)
	main = current_scene
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	main.get_node("SpawnTimer").stop()
	_clear_enemies()
	await frames(5)

	_test_wave_mix()
	await _test_types()
	await _test_runner()
	await _test_brute()
	await _test_soldier()
	await _test_exploder()
	await _test_boss_wave()
	await _test_lineup_shot()

	print("\n%s: %d failure(s)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _count(kinds: Array, kind: String) -> int:
	return kinds.filter(func(k: String) -> bool: return k == kind).size()


func _test_wave_mix() -> void:
	for n in [1, 2]:
		var k: Array = main.wave_kinds(n)
		check(_count(k, "normal") == k.size() and k.size() == main.enemies_in_wave(n),
				"wave %d: %d normal zombies only" % [n, k.size()])
	var w3: Array = main.wave_kinds(3)
	check(_count(w3, "runner") >= 1 and _count(w3, "soldier") == 0, "runners join in wave 3 (%s)" % [w3])
	var w4: Array = main.wave_kinds(4)
	check(_count(w4, "soldier") >= 1 and _count(w4, "runner") >= 1, "soldiers join in wave 4 (%s)" % [w4])
	check(_count(w4, "brute") == 0 and _count(w4, "boss") == 0 and _count(w4, "exploder") == 0,
			"no brutes or exploders before wave 5/6")
	var w5: Array = main.wave_kinds(5)
	check(main.is_boss_wave(5) and w5[0] == "boss" and _count(w5, "boss") == 1,
			"wave 5 is a boss wave: one Brute Boss, spawned first")
	check(_count(w5, "exploder") == 0, "no exploders in wave 5")
	check(w5.size() > 1 and w5.size() < main.enemies_in_wave(5) + 1, "boss waves have fewer other enemies (%d)" % w5.size())
	var w6: Array = main.wave_kinds(6)
	check(_count(w6, "exploder") >= 1 and _count(w6, "brute") >= 1 and _count(w6, "boss") == 0,
			"wave 6 adds exploders and brutes (%s)" % [w6])
	for n in [6, 7, 8, 9]:
		var k: Array = main.wave_kinds(n)
		var types := {}
		for kind in k:
			types[kind] = true
		check(types.size() >= 4, "wave %d mixes %d enemy types" % [n, types.size()])
	check(main.is_boss_wave(10) and main.wave_kinds(10)[0] == "boss" and not main.is_boss_wave(11),
			"every 5th wave is a boss wave")
	check(main.boss_hp(5) == 80 and main.boss_hp(10) == 120, "the boss gets tougher each boss wave")


# Each type has its own model, size, colours, health and voice.
func _test_types() -> void:
	var heights := {}
	for kind: String in Types.TYPES:
		var e := _spawn(kind, Vector3(0, 0, -20))
		await frames(2)
		var s: Dictionary = Types.TYPES[kind]
		check(e.hp == s.hp and e.max_hp == s.hp, "%s has %d HP" % [kind, s.hp])
		var ap: AnimationPlayer = e.get_node("Model/AnimationPlayer")
		var anims_ok := true
		for role: String in s.anims:
			anims_ok = anims_ok and ap.has_animation(s.anims[role])
		check(anims_ok and s.anims.has_all(["walk", "attack", "death", "idle"]),
				"%s has walk, attack, death and idle animations" % kind)
		check(ap.current_animation == s.anims.walk and ap.is_playing(), "%s walks with its walk animation" % kind)
		# The retargeted tracks reach the skeleton: the walk moves the bones.
		var skel: Skeleton3D = e._skel
		var foot := skel.find_bone("LeftFoot")
		var before := skel.get_bone_global_pose(foot).origin
		await seconds(0.3)
		check(skel.get_bone_global_pose(foot).origin.distance_to(before) > 0.01, "%s's legs move while walking" % kind)
		# The model's height matches the collision capsule (within 15%).
		var top: float = (skel.global_transform * skel.get_bone_global_rest(skel.find_bone("HeadTop_End")).origin).y - e.global_position.y
		check(absf(top - s.height) < s.height * 0.15, "%s's model is as tall as its capsule (%.2f / %.2f m)" % [kind, top, s.height])
		heights[kind] = (e.get_node("CollisionShape3D").shape as CapsuleShape3D).height
		if s.tint != Color.WHITE or s.glow != null:
			var recolored := false
			for mi: MeshInstance3D in e.meshes:
				for i in mi.mesh.get_surface_count():
					var m := mi.get_surface_override_material(i) as BaseMaterial3D
					if m and (s.glow == null or m.emission_enabled):
						recolored = true
			check(recolored, "%s gets its own tint / glow" % kind)
		_clear_enemies()
	check(heights.runner < heights.normal and heights.normal < heights.brute and heights.brute < heights.boss,
			"sizes: runner < zombie < brute < boss (%s)" % [heights])
	var voices := []
	for kind: String in Types.TYPES:
		voices.append(str(Types.TYPES[kind].growls))
	var distinct := {}
	for v in voices:
		distinct[v] = true
	check(distinct.size() >= 5, "types have their own voices (%d different sets)" % distinct.size())
	var meshes := {}
	for kind: String in Types.TYPES:
		meshes[Types.TYPES[kind].mesh] = true
	check(meshes.size() == 5, "five different characters (the Boss is a bigger, darker Brute)")
	for q in 3:
		check(Types.model_scene("soldier", q) != null, "the soldier has a %s detail level" % Types.LODS[q])


func _test_runner() -> void:
	_put_player(Vector3(-10, 0, -1))
	var e := _spawn("runner", Vector3(8, 0, -1), true)
	await seconds(0.6)
	var speed := Vector2(e.velocity.x, e.velocity.z).length()
	check(speed > 3.5, "runner is fast (%.1f m/s vs zombie %.1f)" % [speed, Types.TYPES.normal.speed])
	var n := _spawn("normal", Vector3(8, 0, 1), true)
	await seconds(0.6)
	check(Vector2(n.velocity.x, n.velocity.z).length() < 2.0, "the normal zombie is slower")
	e.take_damage(2)
	check(e.hp <= 0 and e.state == e.State.DEAD, "runner has low health (one pistol shot kills)")
	await seconds(2.5)
	# The death animation ends lying on the ground.
	var head_y: float = e.head_sphere().center.y - e.global_position.y
	check(head_y < 0.5, "a dead runner falls to the ground (head %.2f m up)" % head_y)
	check(n.rotation.x == 0.0, "(the zombie keeps its own death animation)")
	_clear_enemies()


func _test_brute() -> void:
	_put_player(Vector3(-10, 0, -1))
	var b := _spawn("brute", Vector3(6, 0, -1), true)
	await seconds(0.8)
	var speed := Vector2(b.velocity.x, b.velocity.z).length()
	check(speed > 0.5 and speed < 1.3, "brute is slow (%.1f m/s)" % speed)
	b.take_damage(5)
	await frames(2)
	check(b.hp == 20 and b.state == b.State.CHASE, "brute has lots of health and doesn't stagger")
	_clear_enemies()
	# Heavy punch.
	player.heal(100)
	var health: int = player.health
	var b2 := _spawn("brute", player.global_position + Vector3(1.6, 0, 0), true)
	await seconds(1.6)
	check(health - player.health >= 30, "a brute punch hurts a lot (-%d)" % (health - player.health))
	check(b2.state != b2.State.DEAD, "brute still standing")
	player.heal(100)
	_clear_enemies()


func _test_soldier() -> void:
	player.heal(100)
	_put_player(Vector3(-10, 0, -1))
	var s := _spawn("soldier", Vector3(10, 0, -1), true)
	check(s.get_node_or_null("Model") and s._muzzle != null, "soldier holds a gun")
	await frames(3)
	var start_d: float = s._flat_distance_to_player()
	await seconds(1.0)
	check(s._flat_distance_to_player() < start_d - 0.5 or s.state == s.State.AIM,
			"soldier closes in when too far (%.1f -> %.1f m)" % [start_d, s._flat_distance_to_player()])
	# Wait for the aim: the warning laser shows before every shot.
	var aimed := false
	var laser_seen := false
	var warned := false
	var t := 0.0
	while t < 8.0 and not aimed:
		await physics_frame
		t += 1.0 / 60.0
		if s.is_aiming():
			aimed = true
	check(aimed, "soldier stops and aims at the player")
	await frames(6)
	laser_seen = s._laser.visible or s._laser.global_transform.basis.z.length() > 1.0
	warned = s._sfx.stream == s.SOLDIER_WARNING
	check(laser_seen, "a red warning laser points at the player")
	check(warned, "a warning tone plays before the shot")
	var d: float = s._flat_distance_to_player()
	check(d >= s.SOLDIER_MIN_RANGE - 1.0 and d <= s.SOLDIER_MAX_RANGE + 1.0, "it shoots from a distance (%.1f m)" % d)
	_face(s)
	await _screenshot("soldier_aiming")
	var health: int = player.health
	var tracer_seen := false
	t = 0.0
	while t < 1.5 and not tracer_seen:
		await physics_frame
		t += 1.0 / 60.0
		tracer_seen = s._tracer.visible
	check(tracer_seen, "the shot leaves a visible tracer")
	await _screenshot("soldier_tracer")
	# Several shots at a player standing still: at least one hits.
	t = 0.0
	while t < 12.0 and player.health == health:
		await seconds(0.25)
		t += 0.25
	check(player.health < health and health - player.health <= 3 * s.SHOT_DAMAGE,
			"soldier shots hurt the player (-%d)" % (health - player.health))
	# Too close: it backs away.
	player.heal(100)
	_clear_enemies()
	_put_player(Vector3(0, 0, -1))
	var s2 := _spawn("soldier", Vector3(3.5, 0, -1), true)
	s2._shot_cooldown = 5.0
	await frames(3)
	var near_d: float = s2._flat_distance_to_player()
	await seconds(1.0)
	check(s2._flat_distance_to_player() > near_d + 0.5, "soldier backs away when the player is close (%.1f -> %.1f m)" % [near_d, s2._flat_distance_to_player()])
	if shots_dir != "":
		# Close-up of a soldier aiming (to check the gun in its hand).
		_clear_enemies()
		_put_player(Vector3(-6, 0, -1))
		var sc := _spawn("soldier", Vector3(1.5, 0, -1), true)
		sc._shot_cooldown = 0.0
		var tt := 0.0
		while tt < 4.0 and not sc.is_aiming():
			await physics_frame
			tt += 1.0 / 60.0
		_face(sc)
		player.head.rotation.x = deg_to_rad(4)
		await frames(4)
		while sc.is_aiming() and not sc._glint.visible:
			await physics_frame
		check(sc._glint.visible, "a red glint blinks at the soldier's gun while it aims")
		await _screenshot("soldier_closeup")
		player.heal(100)
	_clear_enemies()
	# No view through cover: behind the metal crate (x -3..0, z 1..3).
	_put_player(Vector3(-1.5, 0, 5.0))
	var s3 := _spawn("soldier", Vector3(-1.5, 0, -0.5), true)
	await frames(3)
	check(not s3.can_see_player(), "soldier can't see the player through the crate")
	_clear_enemies()
	player.heal(100)


func _test_exploder() -> void:
	player.heal(100)
	_put_player(Vector3(-10, 0, -1))
	var x := _spawn("exploder", Vector3(-3, 0, -1), true)
	_face(x)
	await frames(3)
	check(not x._glow_materials.is_empty(), "exploder glows")
	await seconds(0.5)
	check(Vector2(x.velocity.x, x.velocity.z).length() > 2.5, "exploder runs at the player")
	var health: int = player.health
	var armed := false
	var t := 0.0
	while t < 6.0 and not x.has_exploded():
		await physics_frame
		t += 1.0 / 60.0
		if x.state == x.State.ARMED:
			armed = true
	check(armed, "it arms (fast beeping) when close")
	check(x.has_exploded(), "and explodes next to the player")
	check(player.health < health, "the blast hurts the player (-%d)" % (health - player.health))
	check(not x.killed_by_player and x.state == x.State.DEAD, "a self-destruct counts as dead, with no points")
	await _screenshot("exploder_blast")
	await seconds(1.5)
	player.heal(100)
	_clear_enemies()
	# Killed: it still goes off, hurting the enemies around it, and chains.
	_put_player(Vector3(-10, 0, -1))
	var x1 := _spawn("exploder", Vector3(5, 0, 0), false)
	var x2 := _spawn("exploder", Vector3(7, 0, 0), false)
	var z := _spawn("normal", Vector3(5, 0, 1.5), false)
	var r := _spawn("runner", Vector3(4, 0, -1.2), false)
	await frames(2)
	x1.take_damage(5)
	await seconds(0.6)
	check(x1.has_exploded(), "a killed exploder explodes")
	check(z.hp <= 0 and r.hp <= 0, "its blast kills nearby enemies")
	check(x2.has_exploded(), "and sets off other exploders (chain)")
	check(player.health == 100, "the player far away is safe")
	_clear_enemies()


func _test_boss_wave() -> void:
	player.heal(100)
	_put_player(Vector3(-10, 0, -1))
	main.start_wave(5)
	main.get_node("SpawnTimer").stop()
	check("BOSS" in hud.banner_sub.text, "banner says BOSS WAVE ('%s')" % hud.banner_sub.text)
	main.spawn_enemy()
	await frames(3)
	var boss: Node = null
	for e in main.get_node("Enemies").get_children():
		if e.kind == "boss":
			boss = e
	check(boss != null, "the boss spawns first")
	if boss == null:
		return
	boss.set_physics_process(false)
	check(hud.boss_bar.visible and hud.boss_name.text == "BRUTE BOSS", "boss health bar shows (%s)" % hud.boss_name.text)
	check(hud.boss_bar.max_value == 80 and hud.boss_bar.value == 80, "bar starts full (%d/%d)" % [hud.boss_bar.value, hud.boss_bar.max_value])
	boss.take_damage(20)
	check(hud.boss_bar.value == 60, "bar drops when the boss is hit (%d)" % hud.boss_bar.value)
	await _screenshot("boss_bar")
	var score_before: int = main.score
	boss.take_damage(100)
	await frames(2)
	check(main.score == score_before + Types.TYPES.boss.points, "boss kill is worth %d points" % Types.TYPES.boss.points)
	await seconds(1.3)
	check(not hud.boss_bar.visible, "bar hides after the boss dies")
	# Waves still end once everything is dead.
	main._spawn_queue.clear()
	main._to_spawn = 0
	_clear_enemies()
	main._alive = 0


func _test_lineup_shot() -> void:
	if shots_dir == "":
		return
	_clear_enemies()
	# Open ground east of the player (x 1..11, z -2..2), looking along +X.
	_put_player(Vector3(-6, 0, 0))
	player.rotation.y = -PI / 2.0
	player.head.rotation.x = deg_to_rad(4)
	var kinds := ["runner", "normal", "soldier", "exploder", "brute", "boss"]
	for i in kinds.size():
		var e := _spawn(kinds[i], Vector3(3.0 + i * 1.2, 0, 2.3 - i * 0.95), false)
		e.rotation.y = PI / 2.0  # facing the player
	await seconds(0.5)
	await _screenshot("lineup")
	var first: Node = main.get_node("Enemies").get_child(0)
	first.take_damage(10)
	await seconds(1.6)
	await _screenshot("death_pose")
	_clear_enemies()


# --- Helpers ----------------------------------------------------------------

func _spawn(kind: String, pos: Vector3, active := true) -> Node:
	var e: Node3D = main.ENEMY_SCENE.instantiate()
	e.kind = kind
	e.position = pos
	main.get_node("Enemies").add_child(e)
	if not active:
		e.set_physics_process(false)
	return e


# Turns the player to look at an enemy (for screenshots).
func _face(e: Node3D) -> void:
	var d: Vector3 = e.global_position - player.global_position
	player.rotation.y = atan2(-d.x, -d.z)
	player.head.rotation.x = 0.0


func _put_player(pos: Vector3) -> void:
	player.global_position = pos
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0
	player.head.rotation.x = 0.0


# Out of the scene at once, freed at the end of the frame (like the game
# does; free() right after spawning upsets the renderer).
func _clear_enemies() -> void:
	var holder: Node = main.get_node("Enemies")
	for e in holder.get_children():
		holder.remove_child(e)
		e.queue_free()


func _screenshot(file_name: String) -> void:
	if shots_dir == "":
		return
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	img.save_png(shots_dir.path_join(file_name + ".png"))
	print("saved ", file_name)
