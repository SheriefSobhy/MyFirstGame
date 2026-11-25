extends SceneTree
## Automated check of the three maps and the map selection screen:
##   godot --headless --path . --script res://tools/test_maps.gd
## Prints PASS/FAIL per check and exits with code 1 if anything failed.
## With `-- --shots <folder>` (and without --headless) it also saves a
## screenshot of each map and of the map selection screen.

const Maps := preload("res://maps.gd")

var failures := 0
var shots_dir := ""
var _backup := {}
var _yard_surfaces := 0
var _tracks := {}


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
		await process_frame  # scene changes finish at the end of a process frame


func seconds(t: float) -> void:
	await create_timer(t, true, true).timeout


func _run() -> void:
	_backup_saves()
	root.get_node("Settings").clear_bests()
	# Every map unlocked (the level locks: test_progression.gd). Progress uses
	# a test save under a tool script.
	root.get_node("Progress").xp = preload("res://progression_config.gd").xp_for_level(8)
	check(Maps.LIST.size() == 3 and Maps.LIST[0].id == "yard" and Maps.LIST[0].scene == "res://main.tscn",
			"3 maps, the current yard is map 1")
	for m: Dictionary in Maps.LIST:
		await _test_map(m)
	check(_tracks.size() == 3, "each map has its own music (%d tracks)" % _tracks.size())
	await _test_best_scores()
	await _test_select_screen()
	_restore_saves()
	print("\n%s: %d failure(s)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)


func _test_map(m: Dictionary) -> void:
	print("--- ", m.name)
	change_scene_to_file(m.scene)
	await frames(15)
	var main := current_scene
	var tag: String = m.name
	check(main.name == "Main" and main.map_id == m.id, "%s loads (map_id %s)" % [tag, main.map_id])
	main.get_node("SpawnTimer").stop()
	for e in main.get_node("Enemies").get_children():
		e.free()
	var player: Node3D = main.get_node("Player")
	var hud: Node = main.get_node("HUD")

	# Music.
	await seconds(1.6)
	var music: Node = root.get_node("Music")
	var track: AudioStream = music.current_track()
	check(track != null and track != music.MENU_TRACK, "%s plays gameplay music" % tag)
	if track:
		_tracks[track.resource_path] = true
		check(track.loop, "%s music loops" % tag)

	# Lighting.
	var sun: DirectionalLight3D = main.get_node("Sun")
	var env: Environment = main.get_node("WorldEnvironment").environment
	check(sun != null and env != null, "%s has a sun/moon and an environment" % tag)
	var lamps := main.find_children("*", "Light3D", true, false).filter(
			func(l: Node) -> bool: return not player.is_ancestor_of(l) and l != sun)
	if m.id != "yard":
		check(lamps.size() >= 4 and lamps.size() <= 8, "%s has %d lamps (few, for phones)" % [tag, lamps.size()])
		var optional := get_nodes_in_group("optional_lights")
		check(not optional.is_empty(), "%s has extra lamps that Low quality can turn off" % tag)
		var settings: Node = root.get_node("Settings")
		var q: int = settings.quality
		settings.set_value("quality", settings.Quality.LOW)
		check(optional.all(func(l: Node3D) -> bool: return not l.visible), "%s: Low quality turns the extra lamps off" % tag)
		settings.set_value("quality", settings.Quality.HIGH)
		check(optional.all(func(l: Node3D) -> bool: return l.visible), "%s: High quality turns them on" % tag)
		settings.set_value("quality", q)

	# Draw calls: count visible mesh surfaces (the yard is the reference).
	var surfaces := 0
	for mi: MeshInstance3D in main.find_children("*", "MeshInstance3D", true, false):
		if mi.is_visible_in_tree() and mi.mesh and not player.is_ancestor_of(mi) and not hud.is_ancestor_of(mi):
			surfaces += mi.mesh.get_surface_count()
	print("     %s: %d mesh surfaces" % [tag, surfaces])
	if m.id == "yard":
		_yard_surfaces = surfaces
	else:
		check(surfaces <= _yard_surfaces * 1.3, "%s stays light: %d mesh surfaces (yard %d)" % [tag, surfaces, _yard_surfaces])

	# Navmesh, player start, spawn points and pickups.
	var nav: NavigationRegion3D = main.get_node("NavigationRegion3D")
	check(nav.navigation_mesh and nav.navigation_mesh.get_polygon_count() > 50,
			"%s has its own navmesh (%d polygons)" % [tag, nav.navigation_mesh.get_polygon_count() if nav.navigation_mesh else 0])
	await frames(30)
	check(player.is_on_floor() and absf(player.global_position.y) < 0.2, "%s: the player starts on the ground" % tag)
	var map_rid: RID = main.get_world_3d().navigation_map
	var start: Vector3 = NavigationServer3D.map_get_closest_point(map_rid, player.global_position)
	var spawns: Array = main.get_node("SpawnPoints").get_children()
	check(spawns.size() >= 5, "%s has %d spawn points" % [tag, spawns.size()])
	var bad := []
	for s: Node3D in spawns:
		if not _reachable(map_rid, s.global_position, start) or _blocked(main, s.global_position, player):
			bad.append(s.name)
		if s.global_position.distance_to(player.global_position) < main.SAFE_SPAWN_DISTANCE:
			bad.append(s.name + " (too close)")
	check(bad.is_empty(), "%s: every spawn point is open and has a path to the player %s" % [tag, bad])
	var pickups: Array = main.get_node("Pickups").get_children()
	var weapons := pickups.filter(func(p: Node) -> bool: return p.kind == 0).size()
	var boxes := pickups.size() - weapons
	check(weapons == 3 and boxes >= 3, "%s has 3 weapon pickups and %d ammo boxes" % [tag, boxes])
	bad = []
	for p: Node3D in pickups:
		if not _reachable(map_rid, p.global_position, start) or _blocked(main, p.global_position, player):
			bad.append(p.name)
	check(bad.is_empty(), "%s: pickups are reachable and not inside anything %s" % [tag, bad])

	# An enemy from the farthest spawn walks towards the player.
	var far: Node3D = spawns[0]
	for s: Node3D in spawns:
		if s.global_position.distance_to(player.global_position) > far.global_position.distance_to(player.global_position):
			far = s
	var e: Node3D = main.ENEMY_SCENE.instantiate()
	e.position = far.global_position
	main.get_node("Enemies").add_child(e)
	var d0: float = e.global_position.distance_to(player.global_position)
	await seconds(5.0)
	var d1: float = e.global_position.distance_to(player.global_position)
	check(d1 < d0 - 3.0, "%s: an enemy walks from the far spawn towards the player (%.1f -> %.1f m)" % [tag, d0, d1])
	e.queue_free()
	await frames(2)

	if shots_dir != "":
		hud.visible = true
		await frames(20)
		await _screenshot("map_" + m.id)


# True if the navmesh connects `from` to `to` (the path ends close to `to`).
func _reachable(map_rid: RID, from: Vector3, to: Vector3) -> bool:
	var a := NavigationServer3D.map_get_closest_point(map_rid, from)
	if Vector2(a.x - from.x, a.z - from.z).length() > 0.7:
		return false
	var path := NavigationServer3D.map_get_path(map_rid, a, to, true)
	return path.size() > 0 and path[path.size() - 1].distance_to(to) < 1.0


# True if a person-sized cylinder at `pos` overlaps a wall or prop.
func _blocked(main: Node, pos: Vector3, player: Node3D) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.4
	shape.height = 1.2
	q.shape = shape
	q.transform = Transform3D(Basis(), pos + Vector3(0, 0.75, 0))
	q.collision_mask = 3
	q.exclude = [player.get_rid()]
	return not main.get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


func _test_best_scores() -> void:
	print("--- Best scores")
	var settings: Node = root.get_node("Settings")
	settings.clear_bests()
	check(settings.submit_score(300, 3, "town"), "a first town score is a new best")
	check(not settings.submit_score(200, 4, "town"), "a lower town score isn't")
	check(settings.submit_score(150, 2, "warehouse"), "the warehouse has its own best")
	check(settings.best_score_for("town") == 300 and settings.best_wave_for("town") == 4,
			"town best 300, wave 4 (%d, %d)" % [settings.best_score_for("town"), settings.best_wave_for("town")])
	check(settings.best_score_for("warehouse") == 150 and settings.best_score_for("yard") == 0,
			"each map keeps its own best")
	check(settings.best_score == 300, "the menu shows the best over all maps")
	var save := ConfigFile.new()
	check(save.load(settings.SAVE_PATH) == OK and save.get_value("best_town", "score") == 300
			and save.get_value("best_warehouse", "score") == 150, "bests are saved per map")
	# Loading again keeps them, and an old single best becomes the yard's.
	save.set_value("best", "score", 90)
	save.set_value("best", "wave", 2)
	save.save(settings.SAVE_PATH)
	settings.clear_bests()
	settings._load()
	check(settings.best_score_for("town") == 300 and settings.best_score_for("yard") == 90,
			"saved bests load back; an old save counts for the yard")
	# A game over in the town shows the town's best.
	change_scene_to_file("res://maps/town.tscn")
	await frames(15)
	var main := current_scene
	main.get_node("SpawnTimer").stop()
	main.player.take_damage(1000)
	await frames(3)
	check(main.hud.best_label.text == "Best: 300", "Game Over in the town shows the town best (got '%s')" % main.hud.best_label.text)
	paused = false


func _test_select_screen() -> void:
	print("--- Map selection")
	change_scene_to_file("res://ui/main_menu.tscn")
	await frames(5)
	current_scene.play_button.pressed.emit()
	await frames(5)
	var select := current_scene
	check(select.name == "MapSelect", "Play opens the map selection screen")
	check(select.play_buttons.size() == 3, "one card per map")
	var names := []
	for m: Dictionary in Maps.LIST:
		var button: Button = select.play_buttons[m.id]
		var card: Node = button.get_parent()
		var labels := card.find_children("*", "Label", true, false).map(func(l: Label) -> String: return l.text)
		names.append(labels[0])
		var pic: TextureRect = card.find_children("*", "TextureRect", true, false)[0]
		check(pic.texture != null, "%s card has a picture" % m.name)
		var best: Label = card.get_node("Best")
		var expected: String = "Best: %d   (wave %d)" % [select.get_node("/root/Settings").best_score_for(m.id),
				select.get_node("/root/Settings").best_wave_for(m.id)]
		if select.get_node("/root/Settings").best_score_for(m.id) == 0:
			expected = "Best: -"
		check(best.text == expected, "%s card shows its best ('%s')" % [m.name, best.text])
	check(names == ["Industrial Yard", "Abandoned Town", "Warehouse Night"], "cards: %s" % [names])
	await _screenshot("map_select")
	select.back_button.pressed.emit()
	await frames(5)
	check(current_scene.name == "MainMenu", "Back returns to the main menu")
	current_scene.play_button.pressed.emit()
	await frames(5)
	current_scene.play_buttons["warehouse"].pressed.emit()
	await frames(15)
	check(current_scene.name == "Main" and current_scene.map_id == "warehouse", "picking Warehouse Night loads it")
	# Retry stays on the same map.
	var main := current_scene
	main.get_node("SpawnTimer").stop()
	main.player.take_damage(1000)
	await frames(3)
	main.hud.retry_button.pressed.emit()
	await frames(15)
	check(current_scene.map_id == "warehouse", "Retry replays the same map")
	paused = false


func _screenshot(file_name: String) -> void:
	if shots_dir == "":
		return
	await process_frame
	await process_frame
	root.get_texture().get_image().save_png(shots_dir.path_join(file_name + ".png"))
	print("saved ", file_name)


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
	var settings: Node = root.get_node("Settings")
	settings.clear_bests()
	settings._load()
