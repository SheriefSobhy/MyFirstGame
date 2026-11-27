extends Node
## Base of a mission objective type (missions/defend.gd, rescue.gd,
## sabotage.gd, extraction.gd, hunt.gd). missions/mission_mode.gd creates
## the one for the mission's "type" and calls these; a new type only needs to
## fill them in (and an entry in mission_mode.gd TYPES + missions_config.gd
## TYPE_NAMES):
##   setup()        build its things in the level (before the briefing)
##   begin()        START was pressed: the clock runs from now
##   tick(delta)    every frame while running: update the tracker and marker
##                  (mode.ui), call mode.finish(true / false, reason)
##   star2()        the mission's second star (the first is completing it,
##                  the third finishing above half health)
## mode gives: mission (its missions_config.gd entry), player, ui, elapsed,
## snap(), spawn_soldier_at(), queue_soldiers(), add_interactable(), finish().
##
## Guards (shared): spawn_guard() places a soldier at a post that hasn't
## noticed the player (tactical_soldier.gd alert = false); an alerted guard
## alerts the others within GUARD_ALERT_RADIUS, and the player's shots alert
## the guards within GUNSHOT_ALERT (listen_for_gunshots()).

const Cfg := preload("res://missions/missions_config.gd")

var mode: Node
var mission: Dictionary
var guards: Array[Node] = []


func setup() -> void:
	pass


func begin() -> void:
	pass


func tick(_delta: float) -> void:
	pass


func star2() -> bool:
	return true


## Par-time star (Rescue, Sabotage, Extraction, Hunt).
func under_par() -> bool:
	return mode.elapsed <= float(mission.par_time)


## A guard at `post` looking along `yaw` (degrees, 0 = -Z); `configure` runs
## before it enters the scene (after the guard settings).
func spawn_guard(post: Vector3, yaw: float, configure := Callable()) -> Node:
	var s: Node = mode.spawn_soldier_at(post, func(s: Node) -> void:
		s.alert = false
		s.guard_post = mode.snap(post)
		s.guard_yaw = yaw
		s.rotation.y = deg_to_rad(yaw)
		if configure.is_valid():
			configure.call(s))
	s.alerted.connect(_on_guard_alerted.bind(s))
	guards.append(s)
	return s


## Guards from a missions_config list [[pos, yaw], ...].
func spawn_guards(list: Array, configure := Callable()) -> void:
	for g: Array in list:
		spawn_guard(g[0], g[1], configure)


func listen_for_gunshots() -> void:
	mode.player.fired.connect(_on_player_fired)


## Wakes the unalerted guards within `radius` m of `pos` (noise).
func alert_guards_near(pos: Vector3, radius: float) -> void:
	for g in guards:
		if is_instance_valid(g) and not g.alert and g.state != g.State.DEAD \
				and g.global_position.distance_to(pos) <= radius:
			g.raise_alert()


func alert_all_guards() -> void:
	for g in guards:
		if is_instance_valid(g):
			g.raise_alert()


func _on_guard_alerted(guard: Node) -> void:
	if not is_instance_valid(guard):
		return
	alert_guards_near(guard.global_position, Cfg.GUARD_ALERT_RADIUS)


func _on_player_fired() -> void:
	alert_guards_near(mode.player.global_position, Cfg.GUNSHOT_ALERT)


## Guards that have noticed the player (for tests).
func alerted_count() -> int:
	return guards.filter(func(g: Node) -> bool: return is_instance_valid(g) and g.alert).size()


## Guards still alive.
func living_guards() -> Array[Node]:
	return guards.filter(func(g: Node) -> bool: return is_instance_valid(g) and g.state != g.State.DEAD)
