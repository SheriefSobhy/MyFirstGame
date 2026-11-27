extends "res://missions/objective.gd"
## Mission type "Rescue" (missions_config.gd: hostage, guards, extraction,
## reinforcements, hostage_target_chance, par_time). The hostage
## (missions/hostage.gd) is held with guards around him; guards stand at
## their posts until they hear / see the player, are shot, hear shots
## (GUNSHOT_ALERT) or another guard near them is alerted. Hold USE
## FREE_TIME s next to him to free him; he then follows the player, and
## reinforcements arrive. Reach the extraction zone with him alive = win;
## he dies = fail. Soldiers sometimes fire their burst at him.

const M := preload("res://missions/missions_config.gd")
const ZoneRing := preload("res://missions/zone_ring.gd")
const Hostage := preload("res://missions/hostage.gd")
const GREEN := Color(0.35, 1.0, 0.45)

var hostage: Hostage
var extraction: Node3D
var guards: Array[Node] = []
var freed := false
var freed_at := 0.0
var _reinforcements_sent := 0


func setup() -> void:
	var h: Dictionary = mission.hostage
	hostage = Hostage.new(h.yaw)
	hostage.name = "Hostage"
	mode.add_child(hostage)
	hostage.global_position = mode.snap(h.pos)
	hostage.died.connect(func() -> void: mode.finish(false, "The hostage was killed."))
	extraction = ZoneRing.new(mission.extraction.radius, GREEN)
	extraction.name = "Extraction"
	mode.add_child(extraction)
	extraction.global_position = mode.snap(mission.extraction.pos)
	extraction.visible = false
	for g: Array in mission.guards:
		var post: Vector3 = g[0]
		var yaw: float = g[1]
		var s: Node = mode.spawn_soldier_at(post, func(s: Node) -> void:
			s.alert = false
			s.guard_post = mode.snap(post)
			s.guard_yaw = yaw
			s.rotation.y = deg_to_rad(yaw)
			_target_hostage(s))
		s.alerted.connect(_on_guard_alerted.bind(s))
		guards.append(s)
	mode.player.fired.connect(_on_player_fired)
	mode.add_interactable(hostage, "FREE HOSTAGE", M.FREE_TIME, _free)


func tick(_delta: float) -> void:
	if not freed:
		mode.ui.set_tracker("Free the hostage", -1.0, "Time %s   ·   Hold USE next to him" % M.time_text(mode.elapsed))
		mode.ui.set_marker(hostage.global_position, "HOSTAGE")
		return
	var reinf: Array = mission.reinforcements
	while _reinforcements_sent < reinf.size() and mode.elapsed - freed_at >= float(reinf[_reinforcements_sent].after):
		for i in int(reinf[_reinforcements_sent].count):
			mode.queue_soldier(_target_hostage)
		_reinforcements_sent += 1
		mode.hud.show_message("Enemy reinforcements!")
	mode.ui.set_health("HOSTAGE", hostage.hp, hostage.max_hp)
	var title := "Get the hostage to extraction"
	if hostage.global_position.distance_to(mode.player.global_position) > 10.0:
		title = "Wait for the hostage!"
	mode.ui.set_tracker(title, -1.0, "Time %s   ·   Par %s" % [M.time_text(mode.elapsed), M.time_text(mission.par_time)])
	mode.ui.set_marker(extraction.global_position, "EXTRACT")
	if hostage.state == Hostage.State.FOLLOW and extraction.contains(hostage.global_position) \
			and extraction.contains(mode.player.global_position):
		hostage.make_safe()
		mode.finish(true, "The hostage is safe.")


func star2() -> bool:
	return mode.elapsed <= float(mission.par_time)


func _free() -> void:
	freed = true
	freed_at = mode.elapsed
	hostage.free_hostage()
	extraction.visible = true
	mode.hud.show_message("Hostage freed! Get him out.")
	for g in guards:
		if is_instance_valid(g):
			g.raise_alert()


func _target_hostage(s: Node) -> void:
	s.alt_target = hostage
	s.alt_chance = float(mission.hostage_target_chance)


func _on_guard_alerted(guard: Node) -> void:
	for g in guards:
		if is_instance_valid(g) and g != guard and g.state != g.State.DEAD \
				and g.global_position.distance_to(guard.global_position) <= M.GUARD_ALERT_RADIUS:
			g.raise_alert()


func _on_player_fired() -> void:
	for g in guards:
		if is_instance_valid(g) and not g.alert and g.state != g.State.DEAD \
				and g.global_position.distance_to(mode.player.global_position) <= M.GUNSHOT_ALERT:
			g.raise_alert()


## Guards that have noticed the player (for tests).
func alerted_count() -> int:
	return guards.filter(func(g: Node) -> bool: return is_instance_valid(g) and g.alert).size()
