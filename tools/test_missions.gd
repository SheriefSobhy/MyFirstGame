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
## he dies = fail, extraction = win), dying = fail.

const M := preload("res://missions/missions_config.gd")
const Maps := preload("res://maps.gd")
const Progression := preload("res://progression_config.gd")

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
	map_id = ""
	_finish()


func _finish() -> void:
	_restore_saves()
	print("\n%s: %d failure(s)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _test_config_and_progress() -> void:
	check(M.LIST.size() == 6, "6 missions")
	for map: Dictionary in Maps.LIST:
		var d := M.in_slot(map.id, 1)
		var r := M.in_slot(map.id, 2)
		check(d.get("type", "") == "defend" and r.get("type", "") == "rescue" and M.in_slot(map.id, 3).is_empty(),
				"%s: slot 1 Defend, slot 2 Rescue, slots 3-5 coming soon" % map.id)
		check(ResourceLoader.exists("res://maps/mission_%s.tscn" % map.id), "%s has a mission scene" % map.id)
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
	check(progress.mission_best(a) == 3 and progress.mission_stars_on("town") == Vector2i(3, 6), "best stars per mission and per map")
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
	check(not b[1].disabled and b[2].disabled and b[3].disabled and b[5].disabled and b[3].text == "Soon",
			"slot 1 playable, slot 2 locked, slots 3-5 coming soon")
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
			"an unalerted guard stays at its post")
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
	check(obj.alerted_count() > 0, "guards notice the player close by")
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
	check(main.ui.result.visible and main.ui.result_title.text == "MISSION COMPLETE" and main.ui.next_button == null,
			"the success screen (no next mission: slot 3 is coming soon)")


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
	for a in 12:
		var p: Vector3 = main.snap(hostage.global_position + Vector3(cos(a * TAU / 12.0), 0, sin(a * TAU / 12.0)) * 2.5)
		var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 1.45, chest, 3)
		if main.off_navmesh(p, 1) < 0.2 and space.intersect_ray(q).is_empty():
			spot = p
			break
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
