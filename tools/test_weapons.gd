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
	await _test_new_weapons()
	await _test_switch_inputs()
	await _test_grenades()
	await _test_ammo_box()
	await _test_touch_layout()

	print("\n%s: %d failure(s)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _test_start_state() -> void:
	check(player.weapon_index == 0, "starts with the pistol")
	check(player.has_weapon(0) and not player.has_weapon(1) and not player.has_weapon(2) \
			and not player.has_weapon(3), "rifle, shotgun and sniper still need their pickups")
	for idx in [4, 5, 6, 7]:
		check(player.has_weapon(idx), "%s is available from the start" % Weapons.LIST[idx].name)
	check(Weapons.LIST.size() == 8, "8 weapons in total")
	check(player.grenades == 3, "starts with 3 grenades")
	check(hud.grenade_label.text == "Grenades: 3", "HUD shows grenade count (got '%s')" % hud.grenade_label.text)
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


# Every gun but the sniper aims down its sights: the gun moves to the
# centre, the view zooms a little, the crosshair goes and the spread tightens.
func _test_aim_down_sights() -> void:
	var touch: Control = hud.touch_controls
	for slot in [0, 1, 2, 4, 5, 6, 7]:
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
	check(player.weapon_index == 4, "touch SWITCH goes on to the SMG")
	for i in 3:
		touch._touch_down(0, touch._button_center("switch"))
		touch._touch_up(0, touch._button_center("switch"))
		await seconds(0.5)
	touch._touch_down(0, touch._button_center("switch"))
	touch._touch_up(0, touch._button_center("switch"))
	await seconds(0.5)
	check(player.weapon_index == 0, "touch SWITCH wraps around to the pistol")
	check(not touch.is_wheel_open(), "a quick SWITCH tap doesn't open the weapon wheel")
	# Keys 5-8 pick the new guns.
	for k in 4:
		_press_key(KEY_5 + k)
		await seconds(0.5)
		check(player.weapon_index == 4 + k, "key %d selects the %s" % [5 + k, Weapons.LIST[4 + k].name])
	await _test_weapon_wheel()
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
	for idx in Weapons.LIST.size():
		player.switch_to(idx)
		await seconds(0.6)
		await _screenshot("hip_%d_%s" % [idx, Weapons.LIST[idx].name.to_lower().replace(" ", "_")])


# SMG, AK, LMG and Revolver: fire rate, damage, magazine, reload and feel.
func _test_new_weapons() -> void:
	_put_player(Vector3(0, 0, 10))
	# SMG: very fast, low damage, 35 rounds.
	player.switch_to(4)
	await seconds(0.5)
	check(hud.weapon_label.text == "SMG" and hud.ammo_label.text == "35 / 140",
			"HUD shows SMG 35 / 140 (got '%s' '%s')" % [hud.weapon_label.text, hud.ammo_label.text])
	player.touch_shoot = true
	await seconds(0.55)
	player.touch_shoot = false
	var smg_fired: int = 35 - player.ammo()
	check(smg_fired >= 9 and smg_fired <= 12, "SMG fires very fast, ~18 shots/s (fired %d in 0.55 s)" % smg_fired)
	await seconds(1.0)
	var e := _enemy_in_front(6.0)
	await frames(2)
	await _tap_trigger()
	check(e.hp == 2, "SMG does 1 damage per bullet (enemy hp %d)" % e.hp)
	_clear_enemies()
	player.start_reload()
	await seconds(1.9)
	check(player.ammo() == 35, "SMG reloads to 35")

	# AK: full auto, 2 damage, strong recoil, 30 rounds.
	player.switch_to(5)
	await seconds(0.5)
	check(hud.weapon_label.text == "AK Rifle" and hud.ammo_label.text == "30 / 90",
			"HUD shows AK Rifle 30 / 90 (got '%s' '%s')" % [hud.weapon_label.text, hud.ammo_label.text])
	var pitch_before: float = player.head.rotation.x
	player.touch_shoot = true
	await seconds(0.55)
	player.touch_shoot = false
	var ak_fired: int = 30 - player.ammo()
	var ak_climb: float = rad_to_deg(player.head.rotation.x - pitch_before)
	check(ak_fired >= 5 and ak_fired <= 6, "AK is full auto, ~9 shots/s (fired %d)" % ak_fired)
	check(ak_climb > ak_fired * 0.4, "AK has strong recoil: view climbs %.1f deg" % ak_climb)
	check(Weapons.LIST[5].view_kick > Weapons.LIST[1].view_kick * 3.0
			and Weapons.LIST[5].recoil > Weapons.LIST[1].recoil, "AK kicks harder than the assault rifle")
	await seconds(1.0)
	_put_player(Vector3(0, 0, 10))
	e = _enemy_in_front(6.0)
	await frames(2)
	await _tap_trigger()
	check(e.hp == 1, "AK does 2 damage per bullet (enemy hp %d)" % e.hp)
	_clear_enemies()

	# LMG: 100 rounds, slow reload, slower walking.
	player.switch_to(6)
	await seconds(0.5)
	check(hud.weapon_label.text == "LMG" and hud.ammo_label.text == "100 / 200",
			"HUD shows LMG 100 / 200 (got '%s' '%s')" % [hud.weapon_label.text, hud.ammo_label.text])
	player.touch_shoot = true
	await seconds(1.0)
	player.touch_shoot = false
	var lmg_fired: int = 100 - player.ammo()
	check(lmg_fired >= 10 and lmg_fired <= 12, "LMG is full auto (fired %d in 1 s)" % lmg_fired)
	_put_player(Vector3(0, 0, 10))
	player.touch_move = Vector2(0, -1)
	await frames(5)
	var lmg_speed := Vector2(player.velocity.x, player.velocity.z).length()
	player.touch_move = Vector2.ZERO
	await frames(2)
	check(lmg_speed < player.WALK_SPEED * 0.8 and lmg_speed > player.WALK_SPEED * 0.6,
			"walking is slower with the LMG (%.1f m/s vs %.1f)" % [lmg_speed, player.WALK_SPEED])
	player.start_reload()
	await seconds(3.0)
	check(player.is_reloading(), "LMG reload is slow (still reloading after 3 s)")
	await seconds(1.7)
	check(not player.is_reloading() and player.ammo() == 100, "LMG reload done after 4.5 s (ammo %d)" % player.ammo())
	player.switch_to(5)
	await seconds(0.5)
	_put_player(Vector3(0, 0, 10))
	player.touch_move = Vector2(0, -1)
	await frames(5)
	var ak_speed := Vector2(player.velocity.x, player.velocity.z).length()
	player.touch_move = Vector2.ZERO
	check(ak_speed > lmg_speed + 0.8, "the AK walks faster than the LMG (%.1f vs %.1f m/s)" % [ak_speed, lmg_speed])

	# Revolver: 6 rounds, one-shot kill, slow semi-auto fire.
	player.switch_to(7)
	await seconds(0.5)
	check(hud.weapon_label.text == "Revolver" and hud.ammo_label.text == "6 / 24",
			"HUD shows Revolver 6 / 24 (got '%s' '%s')" % [hud.weapon_label.text, hud.ammo_label.text])
	player.touch_shoot = true
	await seconds(0.8)
	player.touch_shoot = false
	await frames(2)
	check(player.ammo() == 5, "revolver is semi-auto: holding fires once (ammo %d)" % player.ammo())
	await seconds(0.3)
	_put_player(Vector3(0, 0, 10))
	e = _enemy_in_front(6.0)
	await frames(2)
	await _tap_trigger()
	check(e.hp <= 0, "revolver kills in one shot")
	_clear_enemies()
	await seconds(0.2)
	await _tap_trigger(false)
	check(player.ammo() == 4, "revolver: slow fire blocks a quick second shot (ammo %d)" % player.ammo())
	player.start_reload()
	await seconds(3.2)
	check(player.ammo() == 6 and player.reserve() == 22, "revolver reloads to 6 (%d / %d)" % [player.ammo(), player.reserve()])
	player.switch_to(0)
	await seconds(0.5)


# Touch SWITCH held: the weapon wheel opens; dragging picks a slot.
func _test_weapon_wheel() -> void:
	var touch: Control = hud.touch_controls
	touch.size = Vector2(1280, 720)
	touch.visible = true
	player.switch_to(0)
	await seconds(0.5)
	var start: Vector2 = touch._button_center("switch")
	touch._touch_down(0, start)
	await seconds(0.35)
	check(touch.is_wheel_open(), "holding SWITCH opens the weapon wheel")
	await _screenshot("weapon_wheel")
	# Slot 6 (LMG) sits at -90 + 6 * 45 = 180 degrees: straight left.
	touch._touch_drag(0, start + Vector2(-90, 0))
	check(touch._wheel_pick == 6, "dragging left highlights the LMG (slot %d)" % touch._wheel_pick)
	touch._touch_up(0, start + Vector2(-90, 0))
	await seconds(0.5)
	check(player.weapon_index == 6 and not touch.is_wheel_open(), "letting go picks the LMG and closes the wheel")
	# A drag opens it at once; letting go near the start picks nothing.
	touch._touch_down(0, start)
	touch._touch_drag(0, start + Vector2(0, -30))
	check(touch.is_wheel_open(), "dragging from SWITCH opens the wheel right away")
	touch._touch_drag(0, start + Vector2(0, -100))
	check(touch._wheel_pick == 0, "dragging up highlights the pistol")
	touch._touch_drag(0, start + Vector2(5, -5))
	touch._touch_up(0, start + Vector2(5, -5))
	await seconds(0.5)
	check(player.weapon_index == 6, "letting go back at the button cancels")
	# Slots not owned yet (picked up later) can't be chosen.
	player._owned[3] = false
	touch._touch_down(0, start)
	touch._touch_drag(0, start + Vector2(80, 80))  # 135 degrees: slot 3, the sniper
	check(touch._wheel_pick == -1, "a weapon you don't have can't be picked on the wheel")
	touch._touch_up(0, start + Vector2(80, 80))
	player._owned[3] = true
	touch.visible = false
	player.switch_to(0)
	await seconds(0.5)


# Frag grenades: arc preview, throw, bounce, 3 s fuse, falloff damage, effects.
func _test_grenades() -> void:
	const Grenade := preload("res://effects/grenade.gd")
	_clear_enemies()
	_put_player(Vector3(0, 0, 10))
	player.switch_to(0)
	await seconds(0.5)
	player.grenades = 3
	player.emit_status()
	check(Grenade.damage_at(0.0, 7.0, 10) == 10 and Grenade.damage_at(3.5, 7.0, 10) == 5
			and Grenade.damage_at(7.0, 7.0, 10) == 0, "grenade damage falls off with distance")

	# Looking ahead: the arc curves from the hand out to the landing ring.
	if shots_dir != "":
		player.head.rotation.x = deg_to_rad(-4)
		player.start_grenade()
		await seconds(0.2)
		await _screenshot("grenade_preview_level")
		player.cancel_grenade()
		await seconds(0.9)
	# Holding G shows the arc; a slight downward look lands it a few metres away.
	player.head.rotation.x = deg_to_rad(-20)
	await frames(2)
	_press_action("grenade", true)
	await frames(3)
	check(player.is_holding_grenade() and player._preview.visible, "holding G shows the throw preview")
	check(player._preview_marker.visible, "the preview marks where the grenade lands")
	var landing: Vector3 = player._preview_marker.global_position
	var arc: Array = player.throw_arc().points
	check(arc.size() > 5 and arc[arc.size() / 2].y > landing.y + 0.3, "the preview is an arc (%d points)" % arc.size())
	await _screenshot("grenade_preview")
	_press_action("grenade", false)
	await frames(2)
	var g: RigidBody3D = _find_grenade()
	check(g != null, "releasing G throws a grenade")
	check(not player._preview.visible, "the preview hides after the throw")
	check(player.grenades == 2 and hud.grenade_label.text == "Grenades: 2", "grenade count goes down (HUD '%s')" % hud.grenade_label.text)
	# Watch it fly: it should bounce (vertical speed flips up) and rest near the preview.
	var bounced := false
	var last_vy := 0.0
	var t0 := Time.get_ticks_msec()
	while is_instance_valid(g) and g.fuse > 0.3:
		if last_vy < -1.0 and g.linear_velocity.y > 0.3:
			bounced = true
		last_vy = g.linear_velocity.y
		await physics_frame
	check(bounced, "the grenade bounces")
	if is_instance_valid(g):
		var first_hit := Vector2(landing.x, landing.z)
		check(Vector2(g.global_position.x, g.global_position.z).distance_to(first_hit) < 4.0,
				"it lands near the previewed spot (%.1f m off)" % Vector2(g.global_position.x, g.global_position.z).distance_to(first_hit))
	while is_instance_valid(g):
		await physics_frame
	var fuse_time := (Time.get_ticks_msec() - t0) / 1000.0
	check(absf(fuse_time - 3.0) < 0.2, "explodes 3 s after the throw (%.2f s)" % fuse_time)
	var fx := _find_explosion()
	check(fx != null, "an explosion effect is spawned")
	if fx:
		var light: OmniLight3D = fx.find_children("*", "OmniLight3D", false, false)[0]
		check(light.visible and light.light_energy > 1.0, "the explosion flashes a light")
		check(fx.find_children("*", "CPUParticles3D", false, false).size() == 3, "fireball, smoke and spark particles")
		check(fx.find_children("*", "AudioStreamPlayer3D", false, false).size() == 1, "explosion sound plays")
		check(player._shake > 0.3, "the camera shakes (%.2f)" % player._shake)
	await _screenshot("grenade_explosion")
	await seconds(0.5)
	check(fx == null or not is_instance_valid(fx) or not fx._light.visible, "the light flash fades out")

	# Area damage with falloff: a grenade at rest in the open, enemies around it.
	await seconds(1.0)
	# An open patch of the yard (x 1..11, z -2..2); the player well away at x -6.
	_put_player(Vector3(-6, 0, -1))
	var center := Vector3(5, 0.1, 0)
	var near := _enemy_at(center + Vector3(1.0, 0, 0))     # 10*(1-1.3/7) ~ 8: dies
	var mid := _enemy_at(center + Vector3(-5.4, 0, 0))     # ~2 damage: survives on 1 HP
	var far := _enemy_at(center + Vector3(6.0, 0, 5.6))    # 8.2 m: out of range
	await frames(2)
	var health_before: int = player.health
	var g2: RigidBody3D = Grenade.new()
	g2.thrower = player
	g2.fuse = 0.2
	main.add_child(g2)
	g2.global_position = center
	await seconds(0.5)
	check(near.hp <= 0, "enemy 1.4 m away is killed")
	check(mid.hp > 0 and mid.hp < 3, "enemy ~5.5 m away is only hurt (hp %d)" % mid.hp)
	check(far.hp == 3, "enemy 8.2 m away is untouched")
	check(player.health == health_before, "the player 11 m away isn't hurt")
	_clear_enemies()
	# Cover works: an enemy behind the metal crate (x -3..0, z 1..3) is safe.
	await seconds(1.0)
	var hidden := _enemy_at(Vector3(-1.5, 0, -0.5))
	var exposed := _enemy_at(Vector3(-4.0, 0, 6.0))
	await frames(2)
	var g4: RigidBody3D = Grenade.new()
	g4.thrower = player
	g4.fuse = 0.2
	main.add_child(g4)
	g4.global_position = Vector3(-1.5, 0.1, 4.5)
	await seconds(0.5)
	check(hidden.hp == 3, "the blast doesn't go through the crate (hp %d)" % hidden.hp)
	check(exposed.hp < 3, "an enemy in the open at the same range is hit (hp %d)" % exposed.hp)
	_clear_enemies()
	# Too close: the thrower gets hurt.
	await seconds(1.0)
	var g3: RigidBody3D = Grenade.new()
	g3.thrower = player
	g3.fuse = 0.2
	main.add_child(g3)
	g3.global_position = player.global_position + Vector3(1.5, 0.1, 0)
	await seconds(0.5)
	check(player.health < health_before and player.health > 0, "standing next to it hurts the player (%d)" % player.health)
	player.heal(100)

	# Touch GRENADE button: hold for the preview, let go to throw.
	var touch: Control = hud.touch_controls
	touch.size = Vector2(1280, 720)
	touch.visible = true
	var gpos: Vector2 = touch._button_center("grenade")
	check(touch._button_at(gpos) == "grenade", "touch GRENADE button exists")
	var count: int = player.grenades
	touch._touch_down(0, gpos)
	await frames(2)
	check(player.is_holding_grenade() and player._preview.visible, "holding GRENADE shows the preview")
	touch._touch_up(0, gpos)
	await frames(2)
	check(player.grenades == count - 1 and _find_grenade() != null, "letting go of GRENADE throws")
	await seconds(3.5)
	# None left: nothing happens.
	player.grenades = 0
	player.emit_status()
	await seconds(1.0)
	touch._touch_down(0, gpos)
	await frames(2)
	check(not player.is_holding_grenade(), "no grenades left: GRENADE does nothing")
	touch._touch_up(0, gpos)
	touch.visible = false
	player.grenades = 3
	player.emit_status()
	await seconds(1.0)


func _find_grenade() -> RigidBody3D:
	for n in main.get_children():
		if n is RigidBody3D and n.has_method("explode"):
			return n
	return null


func _find_explosion() -> Node3D:
	for n in main.get_children():
		if n.get_script() == preload("res://effects/explosion.gd") and n.with_sound:
			return n
	return null


func _enemy_at(pos: Vector3) -> Node:
	var e: Node3D = main.ENEMY_SCENE.instantiate()
	e.position = Vector3(pos.x, 0.0, pos.z)
	main.get_node("Enemies").add_child(e)
	e.set_physics_process(false)
	return e


func _press_action(action: String, pressed: bool) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _test_ammo_box() -> void:
	player._reserve[1] = 10
	player._reserve[3] = 25  # sniper already full
	player._reserve[6] = 100
	player.grenades = 2
	var box: Node3D = main.get_node("Pickups/AmmoBox1")
	_put_player(box.global_position)
	await frames(5)
	check(player._reserve[1] == 40, "ammo box adds 30 rifle rounds (%d)" % player._reserve[1])
	check(player._reserve[6] == 150, "ammo box adds 50 LMG rounds (%d)" % player._reserve[6])
	check(player.grenades == 3 and hud.grenade_label.text == "Grenades: 3", "ammo box gives +1 grenade (%d)" % player.grenades)
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
	for i in Weapons.LIST.size():
		if player.has_weapon(i) and Weapons.LIST[i].max_reserve > 0:
			player._reserve[i] = Weapons.LIST[i].max_reserve
	player.grenades = player.MAX_GRENADES
	_put_player(box.global_position)
	await frames(5)
	check(box._active, "ammo box stays when all ammo and grenades are full")
	check(player.grenades == player.MAX_GRENADES, "grenades stop at %d" % player.MAX_GRENADES)
	# One more grenade short: the box is used again, but only up to the max.
	player.grenades = player.MAX_GRENADES - 1
	await frames(5)
	check(not box._active and player.grenades == player.MAX_GRENADES, "a box tops grenades up to the max of 5")
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
	# No two buttons overlap (the GRENADE button is new).
	var names: Array = touch.BUTTONS.keys()
	var overlap := false
	for i in names.size():
		for j in range(i + 1, names.size()):
			var d: float = touch._button_center(names[i]).distance_to(touch._button_center(names[j]))
			if d < touch.BUTTONS[names[i]].radius + touch.BUTTONS[names[j]].radius + 4.0:
				overlap = true
	check(not overlap, "touch buttons don't overlap")
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
