extends SceneTree
## Automated check of the combat feedback, run against the real main scene:
##   godot --headless --path . --script res://tools/test_combat_feel.gd
## Headshots, hit markers, damage numbers, hit reactions, haptics, touch aim
## assist, kill streaks and the low-health effects.
## Prints PASS/FAIL per check and exits with code 1 if anything failed.
## With `-- --shots <folder>` (and without --headless) it also saves
## screenshots of a headshot, a kill streak and the low-health vignette.

const Types := preload("res://enemy_types.gd")
const Haptics := preload("res://effects/haptics.gd")

var main: Node
var player: Node
var hud: Node
var fb: Node
var failures := 0
var shots_dir := ""
var _saved := {}
var settings: Node  # the Settings autoload (autoload names don't compile in a SceneTree script)


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
	settings = root.get_node("Settings")
	for key in ["damage_numbers", "haptics", "aim_assist"]:
		_saved[key] = settings.get(key)
		settings.set(key, true)
	change_scene_to_file("res://main.tscn")
	await frames(10)
	main = current_scene
	player = main.get_node("Player")
	hud = main.get_node("HUD")
	fb = hud.feedback
	main.get_node("SpawnTimer").stop()
	_clear_enemies()
	await frames(5)

	_test_settings()
	await _test_head_hitboxes()
	await _test_headshot()
	await _test_body_shot()
	await _test_hit_reactions()
	await _test_death_throw()
	await _test_haptics()
	await _test_kill_streaks()
	await _test_aim_assist_pull()
	await _test_aim_assist_slowdown()
	await _test_low_health()
	await _test_settings_menu()

	for key in _saved:
		settings.set(key, _saved[key])
	print("\n%s: %d failure(s)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _test_settings() -> void:
	var fresh: Node = load("res://settings.gd").new()
	check(fresh.damage_numbers and fresh.haptics and fresh.aim_assist,
			"damage numbers, vibration and aim assist default to on")
	fresh.free()
	check(fb != null and fb.get_parent() == hud, "HUD has the combat feedback layer")
	check(fb.get_index() < hud.touch_controls.get_index(), "feedback is drawn under the touch controls")
	var screen: Vector2 = fb.get_viewport_rect().size
	check(fb.size == screen and fb._vignette.size == screen,
			"feedback layer and vignette cover the screen (%s, %s, screen %s)" % [fb.size, fb._vignette.size, screen])


# Every type's head sphere sits at the top of the body, follows the rig and
# is a sensible size.
func _test_head_hitboxes() -> void:
	_put_player(Vector3(0, 0, 10))
	for kind: String in Types.TYPES:
		var e := _spawn(kind, Vector3(3, 0, 0))
		await frames(3)
		var head: Dictionary = e.head_sphere()
		var ok := not head.is_empty()
		if ok:
			var y: float = head.center.y - e.global_position.y
			var h: float = e.stats.height
			ok = y > h * 0.55 and y < h + 0.05 and head.radius > 0.07 and head.radius < h * 0.2
			check(ok, "%s: head hitbox at %.2f m of %.2f, radius %.2f" % [kind, y, h, head.radius])
		else:
			check(false, "%s has a head hitbox" % kind)
		e.free()


func _test_headshot() -> void:
	_put_player(Vector3(0, 0, 10))
	player.switch_to(0)  # pistol: 2 damage, a normal zombie has 3 HP
	await seconds(0.5)
	var e := _spawn("normal", player.global_position + Vector3(0, 0, -6))
	await frames(3)
	_aim_at(e.head_sphere().center)
	await frames(1)
	var cam: Camera3D = player.camera
	check(e.is_head_hit(cam.global_position, -cam.global_basis.z), "aiming at the head counts as a head hit")
	var hits := []
	player.enemy_hit.connect(func(_e: Node, dmg: int, _p: Vector3, head: bool, killed: bool) -> void:
		hits.append([dmg, head, killed]), CONNECT_ONE_SHOT)
	await _tap_trigger()
	check(hits.size() == 1 and hits[0][0] == 4 and hits[0][1], "headshot does double damage (%s)" % [hits])
	check(e.hp <= 0, "one pistol headshot kills a zombie (hp %d)" % e.hp)
	check(fb.marker_kind == "kill", "kill shows the red kill marker (%s)" % fb.marker_kind)
	check(fb._headshot_label.visible, "HEADSHOT popup shows")
	check(fb._headshot_sound.playing, "headshot sound plays")
	check(fb._kill_sound.playing, "kill sound plays")
	check(fb.numbers_showing() >= 1 and fb._numbers[(fb._next_number + fb.NUMBER_POOL - 1) % fb.NUMBER_POOL].text == "40",
			"damage number shows 40 (4 damage x10)")
	await _screenshot("headshot")
	await seconds(1.0)
	check(fb.marker_kind == "" and not fb._headshot_label.visible, "marker and popup fade out")
	_clear_enemies()


func _test_body_shot() -> void:
	_put_player(Vector3(0, 0, 10))
	await seconds(0.3)
	var e := _spawn("normal", player.global_position + Vector3(0, 0, -6))
	await frames(3)
	_aim_at(e.global_position + Vector3.UP * 0.9)
	await frames(1)
	var cam: Camera3D = player.camera
	check(not e.is_head_hit(cam.global_position, -cam.global_basis.z), "a chest shot is not a head hit")
	var before: int = fb.numbers_showing()
	await _tap_trigger()
	check(e.hp == 1, "body shot does normal damage (hp %d)" % e.hp)
	check(fb.marker_kind == "hit", "a hit shows the white hit marker (%s)" % fb.marker_kind)
	check(fb.numbers_showing() > before or fb.numbers_showing() >= 1, "damage number shows")
	# Numbers off: no new number.
	settings.damage_numbers = false
	await seconds(fb.NUMBER_TIME + 0.1)
	await _tap_trigger()
	check(fb.numbers_showing() == 0, "no damage numbers when the setting is off")
	settings.damage_numbers = true
	_clear_enemies()


func _test_hit_reactions() -> void:
	_put_player(Vector3(0, 0, 10))
	await seconds(0.3)
	# Knockback: a zombie is pushed away from the player.
	var e := _spawn("normal", player.global_position + Vector3(0, 0, -5), true)
	e.speed_scale = 0.0
	await frames(5)
	var z0: float = e.global_position.z
	e.take_damage(1, e.global_position + Vector3(0, 1.0, 0.35), Vector3(0, 0, 1))
	check(e.state == e.State.HIT, "a zombie staggers when hit")
	await frames(2)
	check(absf(e.get_node("Model").rotation.x) > 0.02, "the model flinches")
	await seconds(0.3)
	check(e.global_position.z < z0 - 0.08, "knocked back away from the shot (%.2f m)" % (z0 - e.global_position.z))
	await seconds(0.4)
	check(absf(e.get_node("Model").rotation.x) < 0.01, "the flinch settles")
	e.free()
	# Brutes don't stagger, but still flinch (less) and are pushed less.
	var b := _spawn("brute", player.global_position + Vector3(0, 0, -6), true)
	b.speed_scale = 0.0
	await frames(5)
	b.take_damage(1, b.global_position + Vector3(0, 1.2, 0.6), Vector3(0, 0, 1))
	check(b.state != b.State.HIT, "a brute doesn't stagger")
	check(b._push.length() > 0.1 and b._push.length() < 0.6, "a brute is pushed less (%.2f m/s)" % b._push.length())
	await frames(2)
	check(absf(b.get_node("Model").rotation.x) > 0.005, "a brute still flinches")
	b.free()
	# Effects by type: blood for zombies, sparks for the exploder.
	var before := _count_effects()
	var x := _spawn("exploder", player.global_position + Vector3(2, 0, -6), true)
	await frames(2)
	x.take_damage(1, x.global_position + Vector3.UP, Vector3(0, 0, 1))
	var after := _count_effects()
	check(after.sparks > before.sparks and after.blood == before.blood, "exploder hits throw sparks, not blood")
	x.free()
	var s := _spawn("soldier", player.global_position + Vector3(-2, 0, -6), true)
	await frames(2)
	s.take_damage(1, s.global_position + Vector3.UP, Vector3(0, 0, 1), true)
	var blood := _count_effects()
	check(blood.blood >= after.blood + 2, "a headshot throws a second burst of blood")
	s.free()


func _test_death_throw() -> void:
	_put_player(Vector3(0, 0, 10))
	var e := _spawn("runner", player.global_position + Vector3(0, 0, -6), true)
	await frames(3)
	var z0: float = e.global_position.z
	e.take_damage(10, e.global_position + Vector3(0, 1.0, 0.3), Vector3(0, 0, 1), true)
	check(e.state == e.State.DEAD, "runner killed")
	await seconds(0.8)
	check(e.global_position.z < z0 - 0.3, "the body is thrown back (%.2f m)" % (z0 - e.global_position.z))
	check(e.rotation.x > deg_to_rad(60), "and falls over backwards (%.0f°)" % rad_to_deg(e.rotation.x))
	_clear_enemies()
	# Shot from behind: falls forwards.
	var f := _spawn("runner", player.global_position + Vector3(0, 0, -6), true)
	await frames(3)
	f.rotation.y = 0.0  # facing away from the player (it faces -Z)
	f.take_damage(10, f.global_position + Vector3(0, 1.0, 0.3), Vector3(0, 0, 1))
	await seconds(0.8)
	check(f.rotation.x < -deg_to_rad(60), "shot in the back: falls forwards (%.0f°)" % rad_to_deg(f.rotation.x))
	_clear_enemies()


func _test_haptics() -> void:
	_put_player(Vector3(0, 0, 10))
	await seconds(0.3)
	Haptics.history.clear()
	await _tap_trigger()
	check(Haptics.history.has("shot"), "a shot asks for a light vibration (%s)" % [Haptics.history])
	await seconds(0.2)
	player.take_damage(1)
	check(Haptics.history.has("damage"), "taking damage vibrates")
	player.heal(100)
	await seconds(0.2)
	fb.on_kill()
	check(Haptics.history.back() == "kill", "a kill vibrates")
	await seconds(0.2)
	Haptics.history.clear()
	Haptics.shot()
	Haptics.explosion(1.0)
	check(Haptics.history == ["shot", "explosion"], "an explosion overrides a light pulse")
	Haptics.shot()
	check(Haptics.history.back() == "explosion", "a light pulse doesn't cut a strong one short")
	await seconds(0.2)
	settings.haptics = false
	Haptics.history.clear()
	Haptics.kill()
	Haptics.damage()
	check(Haptics.history.is_empty(), "no vibration when the setting is off")
	settings.haptics = true


func _test_kill_streaks() -> void:
	await seconds(fb.STREAK_WINDOW + 0.1)
	fb.on_kill()
	check(fb.streak == 1 and not fb._streak_label.visible, "a single kill: no streak popup")
	await seconds(0.3)
	fb.on_kill()
	check(fb.streak == 2 and fb.last_streak_text == "DOUBLE KILL" and fb._streak_label.visible, "two quick kills: DOUBLE KILL")
	await seconds(0.3)
	fb.on_kill()
	check(fb.last_streak_text == "TRIPLE KILL", "three: TRIPLE KILL")
	await _screenshot("triple_kill")
	fb.on_kill()
	fb.on_kill()
	check(fb.last_streak_text == "RAMPAGE", "five: RAMPAGE (%s)" % fb.last_streak_text)
	await seconds(fb.STREAK_WINDOW + 0.1)
	fb.on_kill()
	check(fb.streak == 1, "the streak ends after %.1f s without a kill" % fb.STREAK_WINDOW)
	# Real kills count through main.gd.
	await seconds(fb.STREAK_WINDOW + 0.1)
	_put_player(Vector3(0, 0, 10))
	for i in 2:
		var e := _spawn("normal", player.global_position + Vector3(i * 2 - 1, 0, -6), true)
		await frames(1)
		e.take_damage(10, e.global_position + Vector3.UP, Vector3(0, 0, 1))
	check(fb.last_streak_text == "DOUBLE KILL" and fb.streak == 2, "killing two enemies quickly is a double kill")
	_clear_enemies()


# An enemy 7° to the right: aiming in with the touch controls turns towards
# it; with the mouse (or the setting off) nothing moves.
func _test_aim_assist_pull() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE  # touch play: the mouse is never captured
	hud._was_captured = false  # ...and letting it go isn't a pause request
	player.switch_to(0)
	await seconds(0.5)
	for mode in ["touch", "mouse", "off"]:
		_put_player(Vector3(0, 0, 10))
		player.touch_active = mode != "mouse"
		settings.aim_assist = mode != "off"
		var a := deg_to_rad(7.0)
		var e := _spawn("normal", player.global_position + Vector3(sin(a), 0, -cos(a)) * 8.0, true)
		await frames(3)
		_aim_at(player.global_position + Vector3(0, e.stats.height * 0.6, -8.0))
		var before := _angle_to(e)
		player.toggle_aim()
		await seconds(0.6)
		var after := _angle_to(e)
		if mode == "touch":
			check(player.assist_target() == e, "touch: aiming in picks the enemy near the crosshair")
			check(after < before * 0.4, "touch: aiming in pulls the view to the enemy (%.1f° -> %.1f°)" % [before, after])
		else:
			check(absf(after - before) < 0.2, "%s: no pull (%.1f° -> %.1f°)" % [mode, before, after])
		player.toggle_aim()
		await seconds(0.3)
		_clear_enemies()
	# Not through walls: an enemy behind a box isn't pulled to.
	player.touch_active = true
	settings.aim_assist = true
	_put_player(Vector3(0, 0, 10))
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	shape.shape.size = Vector3(4, 4, 0.3)
	wall.add_child(shape)
	main.add_child(wall)
	wall.global_position = player.global_position + Vector3(0, 1.5, -4)
	var hidden := _spawn("normal", player.global_position + Vector3(0.8, 0, -8), true)
	await frames(3)
	player.toggle_aim()
	await frames(5)
	check(player.assist_target() == null, "no aim assist on enemies behind walls")
	player.toggle_aim()
	wall.free()
	hidden.free()
	await seconds(0.3)
	player.touch_active = false


func _test_aim_assist_slowdown() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	hud._was_captured = false
	_put_player(Vector3(0, 0, 10))
	player.touch_active = true
	var e := _spawn("normal", player.global_position + Vector3(0, 0, -8), true)
	await frames(3)
	_aim_at(e.global_position + Vector3.UP)
	await frames(2)
	check(player.assist_enemy_under_crosshair() == e, "the assist sees the enemy under the crosshair")
	var y0: float = player.rotation.y
	player.look(Vector2(50, 0), true)
	var slowed := absf(player.rotation.y - y0)
	player.rotation.y = y0
	player.look(Vector2(50, 0), false)
	var normal := absf(player.rotation.y - y0)
	check(slowed < normal * 0.7, "touch look slows down over an enemy (%.4f vs %.4f)" % [slowed, normal])
	player.rotation.y = y0
	# Off the enemy: full speed.
	_aim_at(e.global_position + Vector3(3, 1, 0))
	await frames(2)
	check(player.assist_enemy_under_crosshair() == null, "nothing under the crosshair when looking away")
	player.touch_active = false
	_clear_enemies()


func _test_low_health() -> void:
	player.heal(100)
	await frames(2)
	check(not fb.vignette_showing(), "no vignette at full health")
	player.take_damage(player.health - 30)
	await frames(3)
	check(fb.is_low_health() and fb.vignette_showing(), "low health shows the red vignette")
	await seconds(0.1)
	check(fb._heart_sound.playing, "low health plays a heartbeat")
	await seconds(0.8)  # after the red damage flash has faded
	await _screenshot("low_health")
	player.take_damage(15)
	await frames(2)
	check(fb.low_health_amount() > 0.6, "lower health: stronger effect (%.2f)" % fb.low_health_amount())
	player.heal(100)
	await frames(3)
	check(not fb.vignette_showing(), "healed: the vignette goes away")


func _test_settings_menu() -> void:
	var menu: Control = hud.settings_menu
	menu.open()
	await frames(2)
	var aim: CheckButton = menu.get_node("%AimAssist")
	check(aim.button_pressed == settings.aim_assist, "settings screen shows the aim assist setting")
	aim.button_pressed = false
	check(not settings.aim_assist, "aim assist toggle switches the setting")
	aim.button_pressed = true
	var numbers: CheckButton = menu.get_node("%DamageNumbers")
	numbers.button_pressed = false
	check(not settings.damage_numbers, "damage numbers toggle switches the setting")
	numbers.button_pressed = true
	var vib: CheckButton = menu.get_node("%Vibration")
	vib.button_pressed = false
	check(not settings.haptics, "vibration toggle switches the setting")
	vib.button_pressed = true
	var panel: Control = menu.get_node("Panel")
	var vp := menu.get_viewport_rect().size
	check(panel.get_global_rect().end.y <= vp.y and panel.get_global_rect().position.y >= 0.0,
			"settings panel fits on screen (%s in %s)" % [panel.get_global_rect(), vp])
	menu.visible = false  # close without saving the test values


# --- Helpers ------------------------------------------------------------------

func _spawn(kind: String, pos: Vector3, frozen := false) -> Node3D:
	var e: Node3D = main.ENEMY_SCENE.instantiate()
	e.kind = kind
	e.position = pos
	e.died.connect(main._on_enemy_died.bind(e))  # as main.gd spawn_enemy() does
	main.get_node("Enemies").add_child(e)
	# Turn it to face the player.
	var to: Vector3 = player.global_position - e.global_position
	e.rotation.y = atan2(-to.x, -to.z)
	if frozen:
		e.speed_scale = 0.0
	return e


func _aim_at(target: Vector3) -> void:
	var from: Vector3 = player.camera.global_position
	var to := target - from
	player.rotation.y = atan2(-to.x, -to.z)
	player.head.rotation.x = atan2(to.y, Vector2(to.x, to.z).length())


func _angle_to(e: Node3D) -> float:
	var from: Vector3 = player.camera.global_position
	var to: Vector3 = e.global_position + Vector3.UP * e.stats.height * 0.6 - from
	return rad_to_deg((-player.head.global_basis.z).angle_to(to.normalized()))


func _count_effects() -> Dictionary:
	var n := {"blood": 0, "sparks": 0}
	for c in current_scene.get_children():
		if c.is_queued_for_deletion():
			continue
		if c.scene_file_path.ends_with("blood_hit.tscn"):
			n.blood += 1
		elif c.scene_file_path.ends_with("impact_sparks.tscn"):
			n.sparks += 1
	return n


func _put_player(pos: Vector3) -> void:
	player.global_position = pos
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0
	player.head.rotation.x = 0.0


func _tap_trigger(wait_ready := true) -> void:
	while wait_ready and player._fire_cooldown > 0.0:
		await physics_frame
	player.touch_shoot = true
	await frames(2)
	player.touch_shoot = false
	await frames(2)


func _clear_enemies() -> void:
	for e in main.get_node("Enemies").get_children():
		e.free()


func _screenshot(file_name: String) -> void:
	if shots_dir == "":
		return
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	img.save_png(shots_dir.path_join(file_name + ".png"))
	print("saved ", file_name)
