extends SceneTree
## Automated check of the weapon system, run against the real main scene:
##   godot --headless --path . --script res://tools/test_weapons.gd
## Prints PASS/FAIL per check and exits with code 1 if anything failed.
## With `-- --shots <folder>` (and without --headless) it also saves
## screenshots of each weapon, the scope and a pickup into <folder>.

const Weapons := preload("res://weapon_stats.gd")

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
	# No enemies wandering into the tests; the tests spawn their own.
	main.get_node("SpawnTimer").stop()
	_clear_enemies()
	await frames(5)

	await _test_start_state()
	_test_pickup_placement()
	await _test_pistol()
	await _test_weapon_pickups()
	await _test_rifle()
	await _test_shotgun()
	await _test_aim_down_sights()
	await _test_sniper()
	await _test_switch_inputs()
	await _test_ammo_box()
	await _test_touch_layout()

	print("\n%s: %d failure(s)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _test_start_state() -> void:
	check(player.weapon_index == 0, "starts with the pistol")
	check(player.has_weapon(0) and not player.has_weapon(1) and not player.has_weapon(2) \
			and not player.has_weapon(3), "only the pistol is owned at start")
	check(hud.weapon_label.text == "Pistol", "HUD shows weapon name (got '%s')" % hud.weapon_label.text)
	check(hud.ammo_label.text == "12 / ∞", "HUD shows pistol ammo 12 / ∞ (got '%s')" % hud.ammo_label.text)
	player.switch_to(2)
	await frames(30)
	check(player.weapon_index == 0, "can't switch to a weapon you don't have")
	await _screenshot("pistol")


func _test_pickup_placement() -> void:
	var space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
	var map: RID = main.get_world_3d().navigation_map
	for p: Node3D in main.get_node("Pickups").get_children():
		var q := PhysicsShapeQueryParameters3D.new()
		var shape := CylinderShape3D.new()
		shape.radius = 0.45
		shape.height = 1.2
		q.shape = shape
		q.transform = Transform3D(Basis(), p.global_position + Vector3(0, 0.7, 0))
		q.collision_mask = 3
		q.exclude = [player.get_rid()]
		var hits := space.intersect_shape(q, 4)
		var names := hits.map(func(h: Dictionary) -> String: return h.collider.name)
		check(hits.is_empty(), "%s is not inside an obstacle %s" % [p.name, names])
		var nav_point := NavigationServer3D.map_get_closest_point(map, p.global_position)
		var d := Vector2(nav_point.x - p.global_position.x, nav_point.z - p.global_position.z).length()
		check(d < 0.6, "%s is on walkable ground (%.2f m from navmesh)" % [p.name, d])


func _test_pistol() -> void:
	_put_player(Vector3(0, 0, 10))
	# Semi-auto: holding the trigger fires once.
	player.touch_shoot = true
	await seconds(0.8)
	player.touch_shoot = false
	await frames(2)
	check(player.ammo() == 11, "pistol is semi-auto: holding fires one shot (ammo %d)" % player.ammo())
	for i in 3:
		await seconds(0.2)
		await _tap_trigger()
	check(player.ammo() == 8, "pistol: one shot per press (ammo %d)" % player.ammo())
	# Two pistol hits kill an enemy (2 dmg, 3 HP).
	var e := _enemy_in_front(6.0)
	await frames(2)
	await _tap_trigger()
	check(e.hp == 1, "pistol does 2 damage (enemy hp %d)" % e.hp)
	await seconds(0.2)
	await _tap_trigger()
	check(e.hp <= 0, "two pistol hits kill an enemy")
	_clear_enemies()
	# Reload with unlimited reserve.
	await seconds(0.2)
	player.start_reload()
	check(hud.ammo_label.text == "Reloading...", "HUD shows Reloading...")
	await seconds(1.5)
	check(player.ammo() == 12 and player.reserve() == -1, "pistol reloads to 12, reserve stays unlimited")


func _test_weapon_pickups() -> void:
	for idx in [1, 2, 3]:
		var p: Node3D = main.get_node("Pickups").get_child(idx - 1)
		_put_player(p.global_position)
		await frames(5)
		check(player.has_weapon(idx), "walking over %s gives %s" % [p.name, Weapons.LIST[idx].name])
		check(not p._active, "%s disappears after pickup" % p.name)
		await seconds(0.5)
		check(player.weapon_index == idx, "switches to the new %s" % Weapons.LIST[idx].name)
	await seconds(1.0)
	var rifle_pickup: Node = main.get_node("Pickups/RiflePickup")
	check(not rifle_pickup._active, "weapon pickups don't respawn")
	_put_player(Vector3(0, 0, 10))


func _test_rifle() -> void:
	player.switch_to(1)
	await seconds(0.5)
	check(hud.weapon_label.text == "Assault Rifle" and hud.ammo_label.text == "30 / 90",
			"HUD shows Assault Rifle 30 / 90 (got '%s' '%s')" % [hud.weapon_label.text, hud.ammo_label.text])
	player.touch_shoot = true
	await seconds(0.55)
	player.touch_shoot = false
	var fired: int = 30 - player.ammo()
	check(fired >= 5 and fired <= 7, "rifle is full auto, about 10 shots/s (fired %d in 0.55 s)" % fired)
	check(player._spread > 0.0, "rifle spread grows while firing (%.2f deg)" % player._spread)
	await seconds(1.0)
	check(player._spread == 0.0, "rifle spread recovers")
	player.start_reload()
	await seconds(2.1)
	check(player.ammo() == 30 and player.reserve() == 90 - fired,
			"rifle reload takes from reserve (%d / %d)" % [player.ammo(), player.reserve()])
	var e := _enemy_in_front(6.0)
	await frames(2)
	player.touch_shoot = true
	await seconds(0.55)
	player.touch_shoot = false
	check(e.hp <= 0, "rifle (1 dmg) kills in 3 hits (enemy hp %d)" % e.hp)
	_clear_enemies()


func _test_shotgun() -> void:
	player.switch_to(2)
	await seconds(0.5)
	check(hud.ammo_label.text == "6 / 18", "shotgun 6 / 18 (got '%s')" % hud.ammo_label.text)
	var e := _enemy_in_front(3.0)
	await frames(2)
	await _tap_trigger()
	check(player.ammo() == 5, "shotgun uses one shell per shot")
	check(e.hp <= 0, "shotgun at close range kills (8 pellets, enemy hp %d)" % e.hp)
	_clear_enemies()
	# Pump: can't fire again right away.
	await seconds(0.3)
	await _tap_trigger(false)
	check(player.ammo() == 5, "shotgun pump delay blocks a quick second shot")
	await seconds(0.8)
	var far := _enemy_in_front(16.0)
	await frames(2)
	await _tap_trigger()
	check(player.ammo() == 4 and far.hp == 3, "shotgun has short range (enemy at 16 m untouched)")
	_clear_enemies()


func _test_sniper() -> void:
	player.switch_to(3)
	await seconds(0.5)
	check(hud.ammo_label.text == "5 / 15", "sniper 5 / 15 (got '%s')" % hud.ammo_label.text)
	var touch: Control = hud.touch_controls
	var aim_pos: Vector2 = touch._button_center("aim")
	check(touch._button_at(aim_pos) == "aim", "touch AIM button exists for the sniper")
	player.toggle_aim()
	await seconds(0.3)
	check(player.is_scoped() and hud.scope_overlay.visible and not hud.crosshair.visible,
			"aiming shows the black scope overlay")
	check(absf(player.camera.fov - 18.0) < 0.5, "scope zooms in (fov %.1f)" % player.camera.fov)
	check(not player.weapon_sway.visible, "gun model hidden while scoped")
	await _screenshot("sniper_scope")
	var e := _enemy_in_front(15.0)
	await frames(2)
	await _tap_trigger()
	check(e.hp <= 0, "sniper one-shot kills")
	_clear_enemies()
	await seconds(0.4)
	await _tap_trigger(false)
	check(player.ammo() == 4, "sniper bolt delay blocks a quick second shot")
	player.toggle_aim()
	await seconds(0.3)
	check(not player.is_scoped() and not hud.scope_overlay.visible and hud.crosshair.visible,
			"AIM again leaves the scope")
	player.toggle_aim()
	await seconds(0.2)
	player.switch_to(0)
	await seconds(0.5)
	check(not player.is_scoped() and absf(player.camera.fov - 75.0) < 0.5, "switching weapons leaves the scope")
	check(touch._button_at(aim_pos) == "aim", "touch AIM button also shown for the pistol")


# Pistol, rifle and shotgun aim down their sights: the gun moves to the
# centre, the view zooms a little, the crosshair goes and the spread tightens.
func _test_aim_down_sights() -> void:
	var touch: Control = hud.touch_controls
	for slot in 3:
		player.switch_to(slot)
		await seconds(0.5)
		var w: Dictionary = Weapons.LIST[slot]
		check(player.can_aim() and touch._button_at(touch._button_center("aim")) == "aim",
				"%s can aim (touch AIM button shown)" % w.name)
		var hip_x: float = player.weapon_sway.position.x
		player.toggle_aim()
		await seconds(0.35)
		check(player.is_aiming() and not player.is_scoped() and not hud.scope_overlay.visible,
				"%s aims down the sights (no scope overlay)" % w.name)
		check(absf(player.camera.fov - w.ads_fov) < 0.5, "%s zooms to fov %.0f (got %.1f)" % [w.name, w.ads_fov, player.camera.fov])
		check(not hud.crosshair.visible and player.weapon_sway.visible, "%s: sights replace the crosshair, gun stays visible" % w.name)
		check(hud.aim_dot.visible == (w.sight == "iron"), "%s: small aim dot only with iron sights" % w.name)
		check(hip_x > 0.1 and absf(player.weapon_sway.position.x) < 0.02,
				"%s moves to the centre of the screen (x %.3f -> %.3f)" % [w.name, hip_x, player.weapon_sway.position.x])
		await _screenshot("ads_%d_%s" % [slot, w.name.to_lower().replace(" ", "_")])
		player.toggle_aim()
		await seconds(0.35)
		check(not player.is_aiming() and absf(player.camera.fov - 75.0) < 0.5 and hud.crosshair.visible,
				"%s: AIM again goes back to the hip" % w.name)
	var rifle: Node = player._views[1]
	check(rifle.get_node_or_null("RedDotSight") != null, "assault rifle has a red dot sight")

	# Aiming slows walking.
	player.switch_to(1)
	await seconds(0.5)
	player.toggle_aim()
	await seconds(0.3)
	player.touch_move = Vector2(0, -1)
	await frames(5)
	var ads_speed := Vector2(player.velocity.x, player.velocity.z).length()
	player.touch_move = Vector2.ZERO
	check(absf(ads_speed - player.WALK_SPEED * player.ADS_MOVE_SCALE) < 0.3, "aiming slows walking (%.1f m/s)" % ads_speed)
	# Reloading lowers the sights.
	player.start_reload()
	await frames(3)
	check(not player.is_aiming(), "reloading stops aiming")
	await seconds(2.3)
	player.switch_to(0)
	await seconds(0.5)


func _test_switch_inputs() -> void:
	player.switch_to(0)
	await seconds(0.5)
	_press_key(KEY_3)
	await seconds(0.5)
	check(player.weapon_index == 2, "key 3 selects the shotgun")
	_wheel(MOUSE_BUTTON_WHEEL_DOWN)
	await seconds(0.5)
	check(player.weapon_index == 3, "mouse wheel down: next weapon")
	_wheel(MOUSE_BUTTON_WHEEL_UP)
	await seconds(0.5)
	check(player.weapon_index == 2, "mouse wheel up: previous weapon")
	var touch: Control = hud.touch_controls
	touch._touch_down(0, touch._button_center("switch"))
	touch._touch_up(0, touch._button_center("switch"))
	await seconds(0.5)
	check(player.weapon_index == 3, "touch SWITCH cycles to the next weapon")
	touch._touch_down(0, touch._button_center("switch"))
	touch._touch_up(0, touch._button_center("switch"))
	await seconds(0.5)
	check(player.weapon_index == 0, "touch SWITCH wraps around to the pistol")
	# Switch animation blocks firing while the gun is lowered.
	player.switch_to(1)
	await frames(3)
	check(player._switching and player.weapon_reload.position.y < 0.0, "switch animation lowers the gun")
	var before: int = player._mag[1]
	player.touch_shoot = true
	await frames(3)
	player.touch_shoot = false
	check(player._mag[1] == before, "can't fire while switching")
	await seconds(0.5)
	check(not player._switching and player.weapon_reload.position.is_zero_approx(), "gun is raised again")
	for idx in [1, 2, 3]:
		player.switch_to(idx)
		await seconds(0.6)
		await _screenshot(Weapons.LIST[idx].name.to_lower().replace(" ", "_"))


func _test_ammo_box() -> void:
	player._reserve[1] = 10
	player._reserve[3] = 25  # sniper already full
	var box: Node3D = main.get_node("Pickups/AmmoBox1")
	_put_player(box.global_position)
	await frames(5)
	check(player._reserve[1] == 40, "ammo box adds 30 rifle rounds (%d)" % player._reserve[1])
	check(player._reserve[3] == 25, "full weapons stay at their max")
	check(player._reserve[0] == -1, "pistol stays unlimited")
	check(not box._active, "ammo box disappears when taken")
	_put_player(Vector3(0, 0, 10))
	Engine.time_scale = 10.0
	await seconds(25.0)
	check(not box._active, "ammo box still gone after 25 s")
	await seconds(6.0)
	Engine.time_scale = 1.0
	check(box._active, "ammo box respawns after 30 s")
	# A full box isn't wasted.
	for i in 4:
		if player.has_weapon(i) and Weapons.LIST[i].max_reserve > 0:
			player._reserve[i] = Weapons.LIST[i].max_reserve
	_put_player(box.global_position)
	await frames(5)
	check(box._active, "ammo box stays when all ammo is full")
	if shots_dir != "":
		_put_player(box.global_position + Vector3(0, 0, 2.5))
		player.rotation.y = 0.0
		player.head.rotation.x = deg_to_rad(-20)
		await seconds(0.3)
		await _screenshot("ammo_box")
		_put_player(Vector3(0, 0, 10))
		# Look at the weapon pickups (shown again for the picture).
		for p: Node in main.get_node("Pickups").get_children():
			p._set_active(true)
		_put_player(Vector3(2.5, 0, 7.0))
		player.head.rotation.x = deg_to_rad(-25)
		await seconds(0.3)
		await _screenshot("rifle_pickup")


func _test_touch_layout() -> void:
	_put_player(Vector3(0, 0, 10))
	var touch: Control = hud.touch_controls
	touch.size = Vector2(1280, 720)
	touch.visible = true
	var joy: Vector2 = touch._joy_home()
	# Left half, away from the joystick: aims, doesn't move.
	var yaw: float = player.rotation.y
	touch._touch_down(0, Vector2(300, 250))
	touch._touch_drag(0, Vector2(360, 250))
	check(touch._fingers.has("look") and not touch._fingers.has("joy"), "touch on the left half aims")
	check(player.rotation.y != yaw and player.touch_move == Vector2.ZERO, "left-half drag turns the view without moving")
	touch._touch_up(0, Vector2(360, 250))
	# Joystick + aim + shoot at the same time (three fingers).
	touch._touch_down(1, joy + Vector2(0, -60))
	check(touch._fingers.has("joy") and player.touch_move.y < -0.5, "touch on the joystick moves forward")
	touch._touch_down(2, Vector2(800, 200))
	touch._touch_down(3, touch._button_center("shoot"))
	yaw = player.rotation.y
	touch._touch_drag(2, Vector2(850, 200))
	check(touch._fingers.has("joy") and touch._fingers.has("look") and touch._fingers.has("shoot")
			and player.touch_shoot and player.rotation.y != yaw and player.touch_move != Vector2.ZERO,
			"move, aim and shoot at the same time")
	touch._touch_up(3, touch._button_center("shoot"))
	touch._touch_up(2, Vector2(850, 200))
	touch._touch_up(1, joy + Vector2(0, -60))
	check(touch._fingers.is_empty() and player.touch_move == Vector2.ZERO and not player.touch_shoot,
			"releasing all fingers stops moving and shooting")
	touch.visible = false


# --- Helpers ----------------------------------------------------------------

func _put_player(pos: Vector3) -> void:
	player.global_position = pos
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0
	player.head.rotation.x = 0.0


## Presses and releases the trigger. With wait_ready, first waits until the
## weapon could fire (fire delay over), like a player tapping at a normal pace.
func _tap_trigger(wait_ready := true) -> void:
	while wait_ready and player._fire_cooldown > 0.0:
		await physics_frame
	player.touch_shoot = true
	await frames(2)
	player.touch_shoot = false
	await frames(2)


## Spawns a standing-still enemy straight ahead and aims at its chest.
func _enemy_in_front(distance: float) -> Node:
	player.head.rotation.x = -atan2(0.5, distance)
	var e: Node3D = main.ENEMY_SCENE.instantiate()
	var fwd: Vector3 = -player.global_basis.z
	e.position = player.global_position + fwd * distance
	e.rotation.y = player.rotation.y
	main.get_node("Enemies").add_child(e)
	e.set_physics_process(false)  # stand still
	return e


func _clear_enemies() -> void:
	for e in main.get_node("Enemies").get_children():
		e.free()


func _press_key(key: Key) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = key
	ev.keycode = key
	ev.pressed = true
	Input.parse_input_event(ev)
	var up := ev.duplicate()
	up.pressed = false
	Input.parse_input_event(up)


func _wheel(button: MouseButton) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	Input.parse_input_event(ev)
	var up := ev.duplicate()
	up.pressed = false
	Input.parse_input_event(up)


func _screenshot(file_name: String) -> void:
	if shots_dir == "":
		return
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	img.save_png(shots_dir.path_join(file_name + ".png"))
	print("saved ", file_name)
