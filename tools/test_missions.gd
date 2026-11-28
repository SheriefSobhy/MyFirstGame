extends SceneTree
## Automated check of Combat > Missions (missions/) on all 3 maps:
##   godot --headless --path . --script res://tools/test_missions.gd [-- --map town]
## Prints PASS/FAIL per check and exits with code 1 if anything failed.
##
## Config and progress (6 missions, unlock order, first / repeat rewards,
## best stars); the menu (Play > Combat > Waves | Missions > map > 5 slots,
## "Coming soon", locked slot 2); per map: the briefing (paused until
## START), Defend (zone ring, waves with pushers walking in, the capture bar
## filling only without the player inside, fail at full capture with the
## result screen, win when the timer runs out with 3 stars), Next Mission
## into Rescue (hostage held with unalerted guards, paths to him and on to
## extraction, guards alerted by shots, the USE button only near him, hold
## 3 s to free, he follows, ducks and takes damage, soldiers shoot at him,
## he dies = fail, extraction = win), dying = fail; Sabotage (targets,
## planting with USE wakes guards nearby, reinforcements, countdown + exit,
## the blasts, outside the exit = fail, inside = win), Extraction (positions
## on the way, the LZ hold clock, waves, the helicopter flying in with its
## rotor and sound, landing after 30 s, boarding = win), Hunt the Commander
## (his look, vest and health, bodyguards, intel ring, spotted = he runs and
## radios for backup, reaching his car = fail, killing him = win).

const M := preload("res://missions/missions_config.gd")
const Maps := preload("res://maps.gd")
const Progression := preload("res://progression_config.gd")
const SoldierCfg := preload("res://soldiers/soldiers_config.gd")

var failures := 0
var main: Node
var player: Node
var progress: Node
var map_id := ""
var _backup := {}


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + ("[%s] " % map_id if map_id != "" else "") + what)
	if not ok:
		failures += 1


func frames(n: int) -> void:
	for i in n:
		await physics_frame
		await process_frame


func seconds(t: float) -> void:
	await create_timer(t, true, true).timeout


func _run() -> void:
	progress = root.get_node("Progress")
	_backup_saves()
	progress.xp = Progression.xp_for_level(15)  # every map unlocked
	_test_config_and_progress()
	var only := ""
	var args := OS.get_cmdline_user_args()
	if args.has("--map"):
		only = args[args.find("--map") + 1]
	var first := true
	for m: Dictionary in Maps.LIST:
		if only != "" and m.id != only:
			continue
		map_id = m.id
		await _test_menu(m.id, first)
		first = false
		if main == null:
			continue
		await _test_briefing()
		await _test_defend()
		if main == null:
			continue
		await _test_rescue()
		if main == null or main.ui.next_button == null:
			continue
		await _test_sabotage()
		if main == null or main.ui.next_button == null:
			continue
		await _test_extraction()
		if main == null or main.ui.next_button == null:
			continue
		await _test_hunt()
	map_id = ""
	_finish()


func _finish() -> void:
	_restore_saves()
	print("\n%s: %d failure(s)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _test_config_and_progress() -> void:
	check(M.LIST.size() == 15, "15 missions")
	var types := ["defend", "rescue", "sabotage", "extraction", "hunt"]
	for map: Dictionary in Maps.LIST:
		var got: Array = range(1, M.SLOTS + 1).map(func(s: int) -> String: return M.in_slot(map.id, s).get("type", ""))
		check(got == types, "%s: slots 1-5 Defend, Rescue, Sabotage, Extraction, Hunt (%s)" % [map.id, str(got)])
		check(ResourceLoader.exists("res://maps/mission_%s.tscn" % map.id), "%s has a mission scene" % map.id)
	for t: String in types:
		check(M.TYPE_NAMES.has(t), "the %s type has a name" % t)
	var ids := ["yard", "town", "warehouse"]
	var per_map := func(slot: int, f: Callable) -> Array: return ids.map(func(id: String) -> Variant: return f.call(M.in_slot(id, slot)))
	var rising := func(a: Array) -> bool: return a[0] < a[1] and a[1] < a[2]
	var sab_guards: Array = per_map.call(3, func(m: Dictionary) -> int: return m.guards.size())
	var sab_count: Array = per_map.call(3, func(m: Dictionary) -> float: return m.countdown)
	check(rising.call(sab_guards) and sab_count[0] > sab_count[1] and sab_count[1] > sab_count[2],
			"Sabotage: more guards, shorter countdown per map (%s, %s)" % [str(sab_guards), str(sab_count)])
	check(per_map.call(3, func(m: Dictionary) -> int: return m.targets.size()).all(func(n: int) -> bool: return n >= 2 and n <= 3),
			"Sabotage: 2-3 targets")
	var ext_guards: Array = per_map.call(4, func(m: Dictionary) -> int: return m.guards.size())
	check(rising.call(ext_guards) and per_map.call(4, func(m: Dictionary) -> float: return m.hold).all(func(h: float) -> bool: return h == 30.0),
			"Extraction: more soldiers on the way per map (%s), hold 30 s" % str(ext_guards))
	var hp: Array = per_map.call(5, func(m: Dictionary) -> int: return m.commander_hp)
	var radio: Array = per_map.call(5, func(m: Dictionary) -> int: return m.radio_count)
	check(rising.call(hp) and rising.call(radio), "Hunt: tougher Commander, more backup per map (%s, %s)" % [str(hp), str(radio)])
	check(per_map.call(5, func(m: Dictionary) -> int: return m.bodyguards.size()).all(func(n: int) -> bool: return n >= 2 and n <= 3)
			and per_map.call(5, func(m: Dictionary) -> int: return m.spots.size()).all(func(n: int) -> bool: return n >= 3),
			"Hunt: 2-3 bodyguards, a few possible spots")
	for id: String in ids:
		for slot in [3, 4, 5]:
			check(M.star_text(M.in_slot(id, slot), 2).begins_with("Finish in under"), "%s slot %d: star 2 is the par time" % [id, slot])
	# Difficulty rises Yard -> Town -> Warehouse.
	var dur: Array = ["yard", "town", "warehouse"].map(func(id: String) -> float: return M.in_slot(id, 1).duration)
	var cap: Array = ["yard", "town", "warehouse"].map(func(id: String) -> float: return M.in_slot(id, 1).capture_time)
	var guards: Array = ["yard", "town", "warehouse"].map(func(id: String) -> int: return M.in_slot(id, 2).guards.size())
	check(dur[0] < dur[1] and dur[1] < dur[2] and dur[0] >= 120.0 and dur[2] <= 180.0,
			"Defend timers 2-3 min, longer per map (%s)" % str(dur))
	check(cap[0] > cap[1] and cap[1] > cap[2], "capture gets faster per map")
	check(guards[0] < guards[1] and guards[1] < guards[2], "more guards per map (%s)" % str(guards))
	# Unlock order, rewards and best stars.
	var a := "town_defend"
	var b := "town_rescue"
	check(progress.is_mission_unlocked(a) and not progress.is_mission_unlocked(b), "slot 1 open, slot 2 locked until slot 1 is cleared")
	var coins: int = progress.coins
	var r0: Dictionary = progress.complete_mission(a, 0)
	check(r0.coins == 0 and progress.mission_best(a) == 0 and not progress.is_mission_unlocked(b), "a failed mission pays nothing, unlocks nothing")
	var r1: Dictionary = progress.complete_mission(a, 2)
	check(r1.first and r1.coins == M.find(a).first.coins and progress.coins >= coins + r1.coins,
			"first clear pays the first-clear reward (%d coins, %d XP)" % [r1.coins, r1.xp])
	check(progress.is_mission_unlocked(b), "clearing slot 1 unlocks slot 2")
	var r2: Dictionary = progress.complete_mission(a, 1)
	check(not r2.first and r2.coins == M.find(a).repeat.coins and r2.coins < r1.coins and progress.mission_best(a) == 2,
			"replays pay less, the best stars are kept")
	progress.complete_mission(a, 3)
	check(progress.mission_best(a) == 3 and progress.mission_stars_on("town") == Vector2i(3, 15), "best stars per mission and per map")
	progress.save()
	var copy: Node = load("res://progress.gd").new()
	copy.save_path = progress.save_path
	copy.load_progress()
	check(copy.mission_best(a) == 3, "mission stars are saved")
	copy.free()
	progress.mission_stars.clear()


# Play > Combat > Missions > map > slot 1 (the full menu on the first map).
func _test_menu(id: String, full: bool) -> void:
	main = null
	change_scene_to_file("res://ui/main_menu.tscn")
	await frames(3)
	var menu := current_scene
	var login: Control = menu.get("login_popup")
	if login:
		login.visible = false
	menu.play_button.pressed.emit()
	var select: Node = null
	for i in 60:
		await frames(1)
		if current_scene and current_scene.name == "MapSelect":
			select = current_scene
			break
	if select == null:
		check(false, "Play opens the mode selection")
		return
	select.mode_buttons[Maps.COMBAT].pressed.emit()
	await frames(2)
	if full:
		check(select.step == select.Step.COMBAT_KIND and select.combat_buttons.has("waves") and select.combat_buttons.has("missions"),
				"Combat asks Waves or Missions")
		select.combat_buttons["waves"].pressed.emit()
		await frames(2)
		check(select.step == select.Step.MAPS and select.play_buttons.size() == 3, "Waves shows the 3 maps (as before)")
		select._on_back()
		await frames(2)
	select.combat_buttons["missions"].pressed.emit()
	await frames(2)
	check(select.step == select.Step.MISSION_MAPS and select.mission_map_buttons.size() == 3, "Missions shows the 3 maps")
	select.mission_map_buttons[id].pressed.emit()
	await frames(2)
	check(select.step == select.Step.MISSION_LIST and select.mission_buttons.size() == M.SLOTS, "the map lists %d mission slots" % M.SLOTS)
	var b: Dictionary = select.mission_buttons
	check(not b[1].disabled and b[2].disabled and b[3].disabled and b[5].disabled and b[3].text == "Locked" and b[5].text == "Locked",
			"slot 1 playable, slots 2-5 locked")
	b[1].pressed.emit()
	await _wait_for_main()
	check(main != null and main.mission.get("id", "") == id + "_defend", "slot 1 loads the Defend mission through the loading screen")


func _wait_for_main(old: Node = null) -> void:
	main = null
	for i in 1200:
		await frames(1)
		var s := current_scene
		if s and s.name == "Main" and s != old and s.get("mission") != null and is_instance_valid(s):
			main = s
			break
	if main == null:
		check(false, "the mission scene loads")
		return
	player = main.player
	player.invincible = true
	main.revives_left = 0
	await frames(3)


func _test_briefing() -> void:
	check(paused and main.ui.briefing != null and main.ui.briefing.visible and not main.running,
			"the briefing card shows first, the game waits")
	check(main.ui.start_button != null, "the briefing has START")
	var start: Vector3 = main.mission.player_start
	check(Vector2(player.global_position.x - start.x, player.global_position.z - start.z).length() < 1.0,
			"the player starts at the mission's spot")
	main.ui.start_button.pressed.emit()
	await frames(3)
	check(not paused and main.running and not main.ui.briefing.visible, "START begins the mission")
	check(not main.hud.wave_label.visible and not main.hud.shop_button.visible, "no wave counter, no shop")


func _soldiers() -> Array:
	return main.enemies.get_children().filter(func(e: Node) -> bool: return e.state != e.State.DEAD)


func _test_defend() -> void:
	var obj: Node = main.objective
	var zone: Node3D = obj.zone
	check(zone != null and zone.visible and zone.contains(player.global_position), "a visible ring; the player starts in it")
	check(main.ui.tracker.visible and main.ui.tracker_title.text != "", "the objective tracker shows")
	# Waves come; pushers walk into the zone.
	var pusher: Node = null
	for i in 2400:
		await frames(1)
		for e: Node in _soldiers():
			if e.push_spot != Vector3.INF and zone.contains(e.global_position):
				pusher = e
		if pusher:
			break
	var total := _soldiers().size()
	var pushers := _soldiers().filter(func(e: Node) -> bool: return e.push_spot != Vector3.INF).size()
	check(total > 0 and pushers > 0 and pushers < total + 1, "the first wave came (%d soldiers, %d pushers)" % [total, pushers])
	check(pusher != null, "a pusher walks into the zone")
	if pusher == null:
		return
	pusher.process_mode = Node.PROCESS_MODE_DISABLED  # holds still in the zone
	# Player inside: no capture.
	obj.capture = 0.0
	await seconds(0.6)
	check(obj.capture == 0.0 and obj.player_inside, "with the player inside, the point can't be captured")
	# Player out of the zone: the bar fills.
	var away: Vector3 = main.snap(zone.global_position + Vector3(zone.radius + 5.0, 0, 0))
	if zone.contains(away) or main.off_navmesh(away, 1) > 0.3:
		away = main.snap(zone.global_position + Vector3(0, 0, zone.radius + 5.0))
	player.global_position = away + Vector3.UP * 0.1
	await seconds(1.0)
	check(obj.capture > 0.03 and not obj.player_inside, "soldiers in the zone without the player fill the capture bar (%.2f)" % obj.capture)
	check(main.ui.marker_screen().size() > 0, "the marker / edge arrow points to the zone")
	# Full capture = fail, result screen with Retry.
	obj.capture = 0.99
	await seconds(0.5)
	check(main.finished and not main.won, "a full capture bar fails the mission")
	await seconds(M.RESULT_DELAY + 0.4)
	check(paused and main.ui.result != null and main.ui.result.visible and main.ui.retry_button != null
			and main.ui.result_title.text == "MISSION FAILED", "the fail screen shows with Retry")
	check(progress.mission_best(main.mission.id) == 0, "a fail saves no stars")
	# Retry, then win on time.
	var old := main
	main.ui.retry_button.pressed.emit()
	await _wait_for_main(old)
	if main == null:
		return
	check(main.mission.type == "defend", "Retry restarts the same mission")
	main.ui.start_button.pressed.emit()
	await frames(3)
	var coins: int = progress.coins
	main.elapsed = main.mission.duration - 0.05
	await frames(5)
	check(main.finished and main.won, "holding until the timer ends wins")
	await seconds(M.RESULT_DELAY + 0.4)
	check(main.stars == [true, true, true] and progress.mission_best(main.mission.id) == 3, "3 stars (complete, low capture, health)")
	check(progress.coins >= coins + main.mission.first.coins and main.reward.first, "the first clear pays %d coins" % main.mission.first.coins)
	check(main.ui.result.visible and main.ui.next_button != null, "the success screen offers Next Mission")


func _test_rescue() -> void:
	var old := main
	main.ui.next_button.pressed.emit()
	await _wait_for_main(old)
	if main == null:
		return
	check(main.mission.type == "rescue" and main.ui.briefing.visible, "Next Mission opens the Rescue briefing")
	var obj: Node = main.objective
	var hostage: Node = obj.hostage
	check(hostage != null and hostage.state == hostage.State.CAPTIVE, "the hostage is held")
	check(obj.guards.size() == main.mission.guards.size() and obj.alerted_count() == 0, "%d guards at their posts, not alerted" % obj.guards.size())
	check(not obj.extraction.visible, "the extraction zone shows only once he is free")
	main.ui.start_button.pressed.emit()
	await frames(30)
	# Navigation: start -> hostage -> extraction.
	var map: RID = main.get_world_3d().navigation_map
	var p1 := NavigationServer3D.map_get_path(map, main.snap(player.global_position), hostage.global_position, true, 1)
	var p2 := NavigationServer3D.map_get_path(map, hostage.global_position, obj.extraction.global_position, true, 1)
	check(not p1.is_empty() and p1[p1.size() - 1].distance_to(hostage.global_position) < 1.5, "a path from the start to the hostage")
	check(not p2.is_empty() and p2[p2.size() - 1].distance_to(obj.extraction.global_position) < 1.5, "a path from the hostage to extraction")
	var guard: Node = obj.guards[0]
	var post: Vector3 = guard.guard_post
	check(not guard.alert and Vector2(guard.global_position.x - post.x, guard.global_position.z - post.z).length() < 1.0,
			"an unalerted guard starts at its post (then patrols)")
	check(main.ui.use_text == "", "no USE button away from interactables")
	check(main.ui.marker_pos.distance_to(hostage.global_position) < 0.1, "the marker points at the hostage")
	# Next to the hostage: USE.
	var near: Vector3 = hostage.global_position + (hostage.global_position.direction_to(post) if post.distance_to(hostage.global_position) > 0.1 else Vector3.RIGHT) * 1.2
	player.global_position = main.snap(near) + Vector3.UP * 0.1
	await frames(3)
	check(main.ui.use_text == "FREE HOSTAGE" and main.ui.use_button.visible, "the USE button shows next to the hostage")
	_hold_use(true)
	await seconds(1.4)
	check(hostage.state == hostage.State.CAPTIVE and main.ui.use_progress > 0.25 and main.ui.use_progress < 0.75,
			"holding USE fills the ring (%.2f)" % main.ui.use_progress)
	_hold_use(false)
	await frames(3)
	check(main.ui.use_progress == 0.0 and hostage.state == hostage.State.CAPTIVE, "letting go resets it")
	_hold_use(true)
	await seconds(M.FREE_TIME + 0.4)
	_hold_use(false)
	check(hostage.state == hostage.State.FOLLOW and obj.freed, "3 s of USE frees him")
	check(obj.extraction.visible and main.ui.marker_pos.distance_to(obj.extraction.global_position) < 0.1,
			"the marker switches to extraction")
	check(main.ui.health_box.visible, "the hostage's health bar shows")
	check(obj.alerted_count() == obj.guards.filter(func(g: Node) -> bool: return is_instance_valid(g) and g.state != g.State.DEAD).size(),
			"freeing him alerts every guard")
	# He follows along the path.
	var path := NavigationServer3D.map_get_path(map, hostage.global_position, obj.extraction.global_position, true, 1)
	var walk_to: Vector3 = path[mini(path.size() - 1, 2)] if path.size() > 1 else hostage.global_position
	var along := 0.0
	var walk_at: Vector3 = hostage.global_position
	for k in range(1, path.size()):
		along += path[k - 1].distance_to(path[k])
		walk_to = path[k]
		if along >= 7.0:
			break
	player.global_position = walk_to + Vector3.UP * 0.1
	var start_d: float = hostage.global_position.distance_to(player.global_position)
	await seconds(3.0)
	var end_d: float = hostage.global_position.distance_to(player.global_position)
	check(end_d < start_d - 2.0 or end_d < M.FOLLOW_STOP + 1.5, "he follows the player (%.1f -> %.1f m)" % [start_d, end_d])
	check(hostage.global_position.distance_to(walk_at) > 1.0, "he walks on the navmesh")
	# Ducks when bullets fly close; takes damage.
	var chest: Vector3 = hostage.global_position + Vector3.UP
	hostage.bullet_passed(chest + Vector3(10, 0, 0.5), chest + Vector3(-10, 0, 0.5))
	await frames(10)
	check(hostage.is_cowering() and hostage._crouch.influence > 0.2, "he crouches when shot at")
	var hp: int = hostage.hp
	hostage.take_bullet(chest + Vector3(5, 0, 0))
	check(hostage.hp == hp - M.HOSTAGE_DAMAGE, "a bullet hurts him")
	await frames(2)
	check(main.ui.health_bar.value == hostage.hp, "the health bar follows (%d)" % hostage.hp)
	# Soldiers aim some bursts at him.
	await _test_soldier_targets_hostage(hostage)
	# Dying fails the mission.
	if map_id == "yard":
		player.invincible = false
		player.take_damage(1000)
		await seconds(0.4)
		check(main.finished and not main.won, "the player dying fails the mission")
		await _retry_rescue()
		if main == null:
			return
		obj = main.objective
		hostage = obj.hostage
	# He dies = fail.
	if hostage.state == hostage.State.CAPTIVE:
		_free_now(obj)
		await frames(3)
	while hostage.hp > 0:
		hostage.take_bullet(hostage.global_position)
	await seconds(0.3)
	check(main.finished and not main.won and hostage.state == hostage.State.DEAD, "the hostage dying fails the mission")
	await seconds(M.RESULT_DELAY + 0.4)
	check(main.ui.result.visible and main.ui.result_title.text == "MISSION FAILED", "the fail screen shows")
	await _retry_rescue()
	if main == null:
		return
	obj = main.objective
	hostage = obj.hostage
	_free_now(obj)
	await frames(3)
	# Extraction with him = win.
	var ex: Vector3 = obj.extraction.global_position
	player.global_position = ex + Vector3.UP * 0.1
	hostage.global_position = ex + Vector3(0.8, 0.0, 0.0)
	await frames(5)
	check(main.finished and main.won and hostage.state == hostage.State.SAFE, "reaching extraction with him wins")
	await seconds(M.RESULT_DELAY + 0.4)
	check(main.stars[0] and main.stars[1] and main.stars[2] and progress.mission_best(main.mission.id) == 3,
			"3 stars (complete, under par, health)")
	check(main.ui.result.visible and main.ui.result_title.text == "MISSION COMPLETE" and main.ui.next_button != null,
			"the success screen offers Next Mission (slot 3)")


# --- Slots 3-5 ----------------------------------------------------------------------

# Next Mission from a success screen into `type`'s briefing (not started).
func _next_mission(type: String) -> bool:
	var old := main
	main.ui.next_button.pressed.emit()
	await _wait_for_main(old)
	if main == null:
		return false
	check(main.mission.type == type and main.ui.briefing.visible and paused, "Next Mission opens the %s briefing" % M.TYPE_NAMES[type])
	return main.mission.type == type


# START, then wait for the navmesh (path / snap queries need it).
func _start() -> void:
	main.ui.start_button.pressed.emit()
	await frames(3)
	for i in 300:
		if main.navmesh_ready():
			break
		await frames(1)
	check(main.navmesh_ready(), "the navmesh is ready")


func _retry_and_start() -> void:
	var old := main
	main.ui.retry_button.pressed.emit()
	await _wait_for_main(old)
	if main == null:
		return
	await _start()


# The navmesh point nearest `p` (for putting the player down).
func _ground(p: Vector3) -> Vector3:
	return main.snap(p) + Vector3.UP * 0.1


func _path_ok(from: Vector3, to: Vector3, tolerance: float) -> bool:
	var map: RID = main.get_world_3d().navigation_map
	var p := NavigationServer3D.map_get_path(map, main.snap(from), main.snap(to), true, 1)
	return not p.is_empty() and Vector2(p[p.size() - 1].x - to.x, p[p.size() - 1].z - to.z).length() < tolerance


func _wait_result(won: bool) -> void:
	for i in 600:
		if main.finished:
			break
		await frames(1)
	check(main.finished and main.won == won, "the mission is won" if won else "the mission fails")
	await seconds(M.RESULT_DELAY + 0.4)


func _test_sabotage() -> void:
	if not await _next_mission("sabotage"):
		return
	var obj: Node = main.objective
	var n: int = main.mission.targets.size()
	check(obj.targets.size() == n and obj.targets.all(func(t: Node) -> bool: return t.visible and not t.planted),
			"%d targets in the level" % n)
	check(obj.targets.all(func(t: Node) -> bool: return t.collision_layer & 1 and t.find_children("*", "MeshInstance3D", true, false).size() > 0),
			"targets are solid and have a model")
	check(not obj.exit_zone.visible and obj.guards.size() == main.mission.guards.size() and obj.alerted_count() == 0,
			"%d guards, not alerted; the exit shows only after the last charge" % obj.guards.size())
	await _start()
	var start: Vector3 = player.global_position
	for t: Node in obj.targets:
		var reach: float = maxf(t.size.x, t.size.z) * 0.5 + 1.0
		check(_path_ok(start, t.use_point(), reach - 0.3), "a path to the %s" % t.kind)
		check(_path_ok(t.use_point(), obj.exit_zone.global_position, 1.5), "a path from the %s to the exit" % t.kind)
		check(t.global_position.distance_to(obj.exit_zone.global_position) > M.BLAST_RADIUS + 2.0, "the exit is out of the %s's blast" % t.kind)
	check(obj.targets.any(func(t: Node) -> bool: return main.ui.marker_pos.distance_to(t.global_position) < 0.1), "the marker points at a target")
	# Plant the first one with USE.
	var first: Node = obj.targets[0]
	player.global_position = _ground(first.use_point())
	await frames(3)
	check(main.ui.use_text == "PLANT C4", "USE shows next to a target")
	var near_guards: int = obj.living_guards().filter(func(g: Node) -> bool:
		return g.global_position.distance_to(player.global_position) <= M.PLANT_NOISE).size()
	_hold_use(true)
	await seconds(M.PLANT_NOISE_AFTER + 0.8)
	check(not first.planted and main.ui.use_progress > 0.3 and main.ui.use_progress < 0.75, "planting takes a while (%.2f)" % main.ui.use_progress)
	if near_guards > 0:
		check(obj.noticed_count() >= near_guards, "guards nearby hear the planting and come to look (%d)" % obj.noticed_count())
	var enemies_before: int = _soldiers().size() + main.queued_soldiers()
	await seconds(M.PLANT_TIME - M.PLANT_NOISE_AFTER - 0.4)
	_hold_use(false)
	check(first.planted and obj.planted_count == 1 and first.get_node_or_null("C4") != null, "4 s of USE plants a charge")
	check(_soldiers().size() + main.queued_soldiers() > enemies_before, "reinforcements come after a charge")
	check(obj.countdown_left == INF, "no countdown before the last charge")
	_plant_rest(obj)
	await frames(3)
	check(obj.planted_count == n and obj.countdown_left <= main.mission.countdown and obj.countdown_left > main.mission.countdown - 1.0,
			"the last charge starts the countdown (%.1f s)" % obj.countdown_left)
	check(obj.exit_zone.visible and main.ui.marker_pos.distance_to(obj.exit_zone.global_position) < 0.1, "the exit shows, the marker points to it")
	await seconds(0.5)
	check(first._beep.playing or first.beep_interval < 1.4, "the charges beep faster")
	# Time runs out away from the exit: everything blows, the mission fails.
	obj.countdown_left = 0.05
	await seconds(0.2)
	check(obj.detonated, "the countdown ends in the blasts")
	await seconds(M.BLAST_STAGGER * n + 0.2)
	check(obj.targets.all(func(t: Node) -> bool: return t.destroyed and t._fire.size() == 2),
			"every target blows up and burns")
	check(main.find_children("*", "Node3D", false, false).any(func(c: Node) -> bool: return c.get_script() == preload("res://effects/explosion.gd")),
			"big explosion effects")
	await _wait_result(false)
	check(main.ui.result.visible and main.ui.result_title.text == "MISSION FAILED", "outside the exit when they blow = fail")
	# Retry: plant everything, wait in the exit zone.
	await _retry_and_start()
	if main == null:
		return
	obj = main.objective
	_plant_rest(obj)
	await frames(2)
	player.global_position = _ground(obj.exit_zone.global_position)
	obj.countdown_left = 0.3
	await frames(4)
	check(obj.exit_zone.contains(player.global_position), "the player waits in the exit zone")
	await _wait_result(true)
	check(main.stars == [true, true, true] and progress.mission_best(main.mission.id) == 3, "3 stars (complete, under par, health)")
	check(main.ui.result.visible and main.ui.next_button != null, "Next Mission (Extraction)")


func _plant_rest(obj: Node) -> void:
	for it: Dictionary in main.interactables:
		if it.active and not it.node.planted:
			it.active = false
			(it.on_done as Callable).call()


func _test_extraction() -> void:
	if not await _next_mission("extraction"):
		return
	var obj: Node = main.objective
	var heli: Node3D = obj.heli
	check(obj.lz.visible and heli.state == heli.State.AWAY and not heli.visible, "the landing zone shows; no helicopter yet")
	check(obj.guards.size() == main.mission.guards.size() and obj.alerted_count() == 0, "%d soldiers hold positions on the way" % obj.guards.size())
	await _start()
	var start: Vector3 = player.global_position
	check(start.distance_to(obj.lz.global_position) > 18.0, "the LZ is at the other end (%.0f m)" % start.distance_to(obj.lz.global_position))
	check(_path_ok(start, obj.lz.global_position, 1.5), "a path from the start to the LZ")
	check(obj.phase == obj.Phase.REACH and main.ui.marker_pos.distance_to(obj.lz.global_position) < 0.1, "the marker points to the LZ")
	# Into the LZ: the hold starts.
	var r: float = obj.lz.radius
	var edge: Vector3 = obj.lz.global_position
	for a in 16:
		var p: Vector3 = main.snap(obj.lz.global_position + Vector3(cos(a * TAU / 16.0), 0, sin(a * TAU / 16.0)) * (r - 0.5))
		var d := Vector2(p.x - obj.lz.global_position.x, p.z - obj.lz.global_position.z).length()
		if obj.lz.contains(p) and d > M.BOARD_RADIUS + 0.2:
			edge = p
			break
	player.global_position = edge + Vector3.UP * 0.1
	await frames(3)
	check(obj.phase == obj.Phase.HOLD and obj.alerted_count() == obj.living_guards().size(), "entering the LZ starts the hold, every soldier comes")
	await seconds(1.0)
	check(obj.hold_elapsed > 0.6, "the hold clock runs inside (%.1f s)" % obj.hold_elapsed)
	var before: int = _soldiers().size() + main.queued_soldiers()
	obj.hold_elapsed = float(main.mission.hold_waves[0].at) + 0.1
	await frames(3)
	check(_soldiers().size() + main.queued_soldiers() > before, "soldiers come in waves during the hold")
	# Out of the zone: the clock stops.
	var held: float = obj.hold_elapsed
	player.global_position = _ground(obj.lz.global_position + Vector3(r + 4.0, 0, 0))
	if obj.lz.contains(player.global_position):
		player.global_position = _ground(obj.lz.global_position + Vector3(0, 0, r + 4.0))
	await seconds(0.5)
	check(not obj.player_inside and absf(obj.hold_elapsed - held) < 0.01 and main.ui.tracker_title.text.begins_with("Get back"),
			"leaving the LZ stops the clock")
	player.global_position = edge + Vector3.UP * 0.1
	# The helicopter flies in over the last HELI_APPROACH s.
	obj.hold_elapsed = float(main.mission.hold) - M.HELI_APPROACH + 0.2
	await frames(3)
	check(heli.visible and heli.state == heli.State.APPROACH and heli.sound.playing, "the helicopter comes in (rotor sound on)")
	var far: float = Vector2(heli.global_position.x - obj.lz.global_position.x, heli.global_position.z - obj.lz.global_position.z).length()
	check(far > 25.0 and heli.global_position.y > obj.lz.global_position.y + 10.0, "from far away and high up (%.0f m)" % far)
	var spin: float = heli.rotor.rotation.y
	await frames(4)
	check(absf(heli.rotor.rotation.y - spin) > 0.05, "the rotor spins")
	obj.hold_elapsed = float(main.mission.hold) - 2.0
	await frames(3)
	var hd: float = Vector2(heli.global_position.x - obj.lz.global_position.x, heli.global_position.z - obj.lz.global_position.z).length()
	check(hd < 2.0 and heli.global_position.y > obj.lz.global_position.y + 0.5, "it hovers over the LZ and descends (%.1f m up)" % (heli.global_position.y - obj.lz.global_position.y))
	obj.hold_elapsed = float(main.mission.hold) - 0.02
	await frames(5)
	check(obj.phase == obj.Phase.BOARD and heli.state == heli.State.LANDED and absf(heli.global_position.y - obj.lz.global_position.y) < 0.05,
			"after 30 s of holding it lands")
	check(obj.board_ring.visible and not main.finished, "boarding needs the player to step in")
	# Step in = win.
	player.global_position = _ground(heli.spot + Vector3(1.0, 0, 0))
	await _wait_result(true)
	check(main.stars == [true, true, true] and progress.mission_best(main.mission.id) == 3, "3 stars (complete, under par, health)")
	check(heli.state == heli.State.LIFTOFF, "the helicopter lifts off")
	check(main.ui.next_button != null, "Next Mission (Hunt the Commander)")


func _test_hunt() -> void:
	var Hunt := preload("res://missions/hunt.gd")
	Hunt.force_spot = 0
	if not await _next_mission("hunt"):
		return
	var obj: Node = main.objective
	var c: Node = obj.commander
	var spot: Vector3 = main.mission.spots[0][0]
	check(c != null and Vector2(c.global_position.x - spot.x, c.global_position.z - spot.z).length() < 1.5, "the Commander is at his spot")
	check(c.max_hp == main.mission.commander_hp and c.max_hp > 4 and c.armor < 1.0, "more health (%d) and a vest" % c.max_hp)
	check(c.beret() != null and c.beret().visible, "a red beret")
	var tinted := false
	for mi: MeshInstance3D in c.meshes:
		var m := mi.get_surface_override_material(0) as BaseMaterial3D
		if m and m.albedo_color.r > m.albedo_color.b * 1.3:
			tinted = true
	check(tinted, "a red-tinted uniform")
	check(obj.bodyguards.size() == main.mission.bodyguards.size() and obj.alerted_count() == 0,
			"%d bodyguards, nobody alerted" % obj.bodyguards.size())
	check(obj.intel.contains(c.global_position) and obj.intel.global_position.distance_to(c.global_position) > 0.5,
			"the intel ring covers his rough area")
	await _start()
	check(main.ui.marker_pos.distance_to(obj.intel.global_position) < 0.1, "the marker points at the intel area")
	var car_spot: Vector3 = obj.flee_spot()
	check(_path_ok(c.global_position, car_spot, 1.5), "a path from his spot to his car")
	for s: Array in main.mission.spots:
		check(_path_ok(s[0], car_spot, 1.5), "a path to the car from spot %s" % str(s[0]))
	# Spotted: he runs, then radios.
	var d0: float = c.global_position.distance_to(c.flee_to)
	c.raise_alert()
	await frames(2)
	check(obj.spotted and not obj.bodyguards.any(func(g: Node) -> bool: return g.alert),
			"spotted: he runs; his bodyguards don't know yet")
	var queued: int = _soldiers().size() + main.queued_soldiers()
	await seconds(maxf(M.RADIO_DELAY, SoldierCfg.RADIO_DELAY.y) + 0.4)
	check(obj.bodyguards.all(func(g: Node) -> bool: return not is_instance_valid(g) or g.alert),
			"his radio report alerts his bodyguards a moment later")
	check(obj.radioed and _soldiers().size() + main.queued_soldiers() >= queued + int(main.mission.radio_count) - 1
			and obj.vehicle.engine_on, "he radios for help (backup comes, the car starts)")
	check(c.global_position.distance_to(c.flee_to) < d0 - 1.5, "he runs for his car (%.1f -> %.1f m)" % [d0, c.global_position.distance_to(c.flee_to)])
	check(main.ui.marker_pos.distance_to(c.global_position) < 0.5 and main.ui.health_box.visible, "the marker and a health bar follow him")
	# He reaches the car: it drives off, the mission fails.
	c.global_position = c.flee_to + Vector3.UP * 0.05
	var car_at: Vector3 = obj.vehicle.global_position
	await frames(5)
	check(obj.escaped and c.has_fled(), "he gets in")
	await seconds(M.VEHICLE_DRIVE_TIME * 0.6)
	check(obj.vehicle.global_position.distance_to(car_at) > 1.0, "the car drives off")
	await _wait_result(false)
	check(main.ui.result_title.text == "MISSION FAILED", "the Commander escaping = fail")
	# Retry at another spot: the vest, then killing him wins.
	Hunt.force_spot = 1
	await _retry_and_start()
	Hunt.force_spot = -1
	if main == null:
		return
	obj = main.objective
	c = obj.commander
	var spot1: Vector3 = main.mission.spots[1][0]
	check(Vector2(c.global_position.x - spot1.x, c.global_position.z - spot1.z).length() < 1.5, "another spot this time")
	var hp: int = c.hp
	c.take_damage(4, c.global_position + Vector3.UP, Vector3.BACK, false)
	check(c.hp == hp - 2, "the vest halves body hits (%d -> %d)" % [hp, c.hp])
	hp = c.hp
	c.take_damage(2, c.global_position + Vector3.UP * 1.7, Vector3.BACK, true)
	check(c.hp == hp - 2, "headshots go through")
	c.take_damage(100, c.global_position + Vector3.UP * 1.7, Vector3.BACK, true)
	await _wait_result(true)
	check(main.stars == [true, true, true] and progress.mission_best(main.mission.id) == 3, "3 stars (complete, under par, health)")
	check(main.ui.result.visible and main.ui.next_button == null, "the last mission: no Next Mission")


func _retry_rescue() -> void:
	await seconds(M.RESULT_DELAY + 0.4)
	var old := main
	main.ui.retry_button.pressed.emit()
	await _wait_for_main(old)
	if main == null:
		return
	main.ui.start_button.pressed.emit()
	await frames(3)


func _free_now(obj: Node) -> void:
	player.global_position = obj.hostage.global_position + Vector3(1.0, 0.1, 0.0)
	for it: Dictionary in main.interactables:
		if it.active:
			it.active = false
			(it.on_done as Callable).call()


func _hold_use(on: bool) -> void:
	main.ui._use_touch = 99 if on else -1
	main.ui.use_held = on


# A soldier with a clear view of him (2.5 m away), told to always pick him:
# its burst goes at him and hits.
func _test_soldier_targets_hostage(hostage: Node) -> void:
	var list := _soldiers()
	if list.is_empty():
		main.spawn_soldier_at(hostage.global_position + Vector3(3.0, 0, 0))
		await frames(5)
		list = _soldiers()
	var s: Node = list[0]
	s.alt_target = hostage
	s.alt_chance = 1.0
	s.process_mode = Node.PROCESS_MODE_DISABLED
	hostage.set_physics_process(false)  # stands still meanwhile (still solid)
	# A spot 2.5 m from him with a clear line between them.
	var space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
	var chest: Vector3 = hostage.global_position + Vector3.UP * 0.9
	var spot: Vector3 = main.snap(hostage.global_position + Vector3(2.5, 0, 0))
	var ex: Array[RID] = s._sight_exclusions()  # patrolling guards don't count
	var found := false
	for r: float in [2.5, 3.5, 2.0]:
		for a in 12:
			var p: Vector3 = main.snap(hostage.global_position + Vector3(cos(a * TAU / 12.0), 0, sin(a * TAU / 12.0)) * r)
			var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 1.45, chest, 3, ex)
			if not found and main.off_navmesh(p, 1) < 0.2 and p.distance_to(hostage.global_position) > 1.6 \
					and space.intersect_ray(q).is_empty():
				spot = p
				found = true
	s.global_position = spot + Vector3.UP * 0.05
	var to: Vector3 = hostage.global_position - spot
	s.rotation.y = atan2(-to.x, -to.z)
	hostage._cower = 0.0
	await frames(2)
	s._set_state(s.State.AIM)
	check(s._burst_target() == hostage, "a soldier can aim its burst at the hostage")
	var before: int = hostage.hits_taken
	var player_hp: int = player.health
	for i in 12:
		s._fire()
	if hostage.hits_taken == before:
		var from: Vector3 = s._muzzle.global_position
		var q := PhysicsRayQueryParameters3D.create(from, chest, 3 | 8, s._sight_exclusions())
		var hit := space.intersect_ray(q)
		print("  debug: muzzle %s soldier %s hostage %s player %s hit %s" % [from, s.global_position, hostage.global_position,
				player.global_position, hit.get("collider", null)])
	check(hostage.hits_taken > before, "its bullets hit him (%d hits)" % (hostage.hits_taken - before))
	check(player.health == player_hp, "those bullets don't hit the player")
	s.alt_chance = 0.0
	s.process_mode = Node.PROCESS_MODE_INHERIT
	hostage.set_physics_process(true)
	s._set_state(s.State.CHASE)


func _backup_saves() -> void:
	for path: String in ["user://settings.cfg", "user://save.cfg"]:
		_backup[path] = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else null


func _restore_saves() -> void:
	for path: String in _backup:
		if _backup[path] == null:
			DirAccess.remove_absolute(path)
		else:
			var f := FileAccess.open(path, FileAccess.WRITE)
			f.store_buffer(_backup[path])
