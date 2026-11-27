extends "res://soldiers/soldiers_mode.gd"
## Combat > Missions: one mission (missions/missions_config.gd) on a map,
## scene maps/mission_<map>.tscn (the map scene with this script). The
## Combat mode's soldiers, cover, damage indicator and regen stay; the waves,
## the shop, the score and the Waves progress (best wave, stars) don't.
##
## Flow: the player starts at the mission's spot; the briefing card (paused)
## -> START -> the objective (missions/objective.gd: defend.gd / rescue.gd)
## runs and calls finish() -> the result screen after RESULT_DELAY s with
## the 3 stars (complete / star2() / health > HEALTH_STAR) and the reward
## (Progress.complete_mission) -> Retry / Next Mission / Missions / Main Menu.
## Dying (after the revive offer) fails the mission.
##
## Framework for objectives: snap(), spawn_soldier_at(), queue_soldier()
## (spawn points, far from the player), add_interactable() (USE / E hold,
## mission_ui.gd), ui (tracker, marker), elapsed, finish().

const Missions := preload("res://missions/missions_config.gd")
const MissionUI := preload("res://missions/mission_ui.gd")
const TYPES := {
	"defend": preload("res://missions/defend.gd"),
	"rescue": preload("res://missions/rescue.gd"),
}
const MAP_SELECT := "res://ui/map_select.tscn"


var mission: Dictionary
var objective: Node
var ui: MissionUI
## True from START until finish().
var running := false
var finished := false
var won := false
## Seconds since START.
var elapsed := 0.0
## [completed, star 2, health] after finish().
var stars: Array = [false, false, false]
var reward := {}
## {node, text, hold, on_done, active}
var interactables: Array[Dictionary] = []
var _hold := 0.0
var _hold_target: Dictionary = {}
var _queue: Array[Callable] = []


func _ready() -> void:
	mission = Missions.find(Missions.pending)
	if mission.is_empty():
		mission = Missions.for_map(map_id)[0]
		Missions.pending = mission.id
	var start: Vector3 = mission.player_start
	player.global_position = Vector3(start.x, player.global_position.y, start.z)
	player.rotation.y = deg_to_rad(mission.player_yaw)
	super._ready()
	hud.wave_label.visible = false
	hud.set_shop_available(false)
	ui = MissionUI.new()
	ui.name = "MissionUI"
	ui.camera = player.camera
	hud.add_child(ui)
	hud.move_child(ui, hud.pause_button.get_index())  # under the pause / revive / level-up layers
	hud.touch_controls.blockers.append(ui.use_button)
	ui.start_pressed.connect(_on_start)
	ui.retry_pressed.connect(_on_retry)
	ui.next_pressed.connect(_on_next)
	ui.missions_pressed.connect(_on_missions)
	ui.menu_pressed.connect(_on_main_menu)
	objective = TYPES[mission.type].new()
	objective.name = "Objective"
	objective.mode = self
	objective.mission = mission
	add_child(objective)
	objective.setup()
	_open_briefing.call_deferred()


func _setup_progress() -> void:
	# No Waves progress (best wave, stars, match XP); kills still give XP and
	# count for daily missions. The mission's reward comes in finish().
	Progress.leveled_up.connect(hud.show_level_up)
	Progress.mission_completed.connect(hud.on_mission_completed)
	Progress.achievement_unlocked.connect(hud.on_achievement)


func _end_progress() -> Dictionary:
	return {}


## Waves don't exist here: main.gd's start_wave(1) / tutorial do nothing.
func start_wave(_n: int) -> void:
	phase = Phase.FIGHT


func start_tutorial() -> void:
	start_wave(1)


func _wave_cleared() -> void:
	pass


func _process(delta: float) -> void:
	super._process(delta)
	if not running:
		ui.use_text = ""
		return
	elapsed += delta
	_update_interactables(delta)
	objective.tick(delta)


# --- Briefing, result ---------------------------------------------------------------

func _open_briefing() -> void:
	get_tree().paused = true
	hud.touch_controls.reset()
	hud.touch_controls.visible = false
	hud.pause_button.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var m := mission.duplicate()
	m.map_color = MapList.find(mission.map).color
	ui.show_briefing(m, Progress.mission_best(mission.id))


func _on_start() -> void:
	hud.touch_controls.visible = DisplayServer.is_touchscreen_available() or hud.touch_controls.force_show
	hud.pause_button.visible = true
	get_tree().paused = false
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	running = true
	elapsed = 0.0
	objective.begin()
	hud.show_banner(mission.name, Missions.TYPE_NAMES[mission.type])


## The mission is over: success or failure, with the reason shown.
func finish(success: bool, reason: String) -> void:
	if finished:
		return
	finished = true
	running = false
	won = success
	spawn_timer.stop()
	_queue.clear()
	player.invincible = true  # nothing changes the result now
	var healthy: bool = player.health > player.MAX_HEALTH * Missions.HEALTH_STAR
	stars = [success, success and objective.star2(), success and healthy]
	reward = Progress.complete_mission(mission.id, stars.count(true) if success else 0)
	ui.set_marker(Vector3.INF)
	ui.use_text = ""
	hud.show_banner("MISSION COMPLETE" if success else "MISSION FAILED", reason)
	var t := get_tree().create_timer(Missions.RESULT_DELAY, true)
	t.timeout.connect(_show_result.bind(reason))


func _show_result(reason: String) -> void:
	get_tree().paused = true
	hud.is_game_over = true
	hud.touch_controls.reset()
	hud.touch_controls.visible = false
	hud.pause_button.visible = false
	hud.pause_menu.visible = false
	hud.revive_screen.visible = false
	hud.crosshair.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var next := Missions.next_of(mission.id)
	ui.show_result(won, reason, stars, mission, reward, elapsed,
			not next.is_empty() and Progress.is_mission_unlocked(next.id))


# Out of revives: the mission fails (no Game Over screen, no best score).
func _game_over() -> void:
	if finished:
		return
	revives_left = 0
	get_tree().paused = false
	hud.end_revive()
	finish(false, "You were killed.")


func _on_next() -> void:
	var next := Missions.next_of(mission.id)
	if next.is_empty():
		return
	Missions.pending = next.id
	_on_retry()


## Back to this map's mission list.
func _on_missions() -> void:
	get_tree().paused = false
	var select := load("res://ui/map_select.gd")
	select.open_missions_for = mission.map
	get_tree().change_scene_to_file(MAP_SELECT)


# --- Helpers for objectives ---------------------------------------------------------

## `pos` on the soldiers' navmesh (unchanged until the navmesh is ready, or
## when nothing is near), on the ground.
func snap(pos: Vector3) -> Vector3:
	var p := _on_navmesh(Vector3(pos.x, 0.0, pos.z), EnemyTypes.NAV_SMALL)
	return Vector3(p.x, 0.0, p.z)


## A Combat soldier at `pos`; `configure` is called before it enters the scene.
func spawn_soldier_at(pos: Vector3, configure := Callable()) -> Node:
	var soldier := SOLDIER_SCENE.instantiate()
	soldier.kind = "soldier"
	soldier.position = snap(pos) + Vector3.UP * 0.1
	if configure.is_valid():
		configure.call(soldier)
	soldier.died.connect(_on_enemy_died.bind(soldier))
	soldier.stuck.connect(_on_enemy_stuck.bind(soldier))
	soldier.shot_at_player.connect(_on_soldier_shot)
	enemies.add_child(soldier)
	_alive += 1
	return soldier


## A soldier to bring in at a spawn point far from the player (out of sight
## if possible) as soon as there is room (max_enemies alive, SPAWN_INTERVAL
## apart).
func queue_soldier(configure := Callable()) -> void:
	_queue.append(configure)
	if spawn_timer.is_stopped():
		spawn_timer.start()
		_on_spawn_tick()


## Soldiers waiting to come in (for tests).
func queued_soldiers() -> int:
	return _queue.size()


func _on_spawn_tick() -> void:
	if _queue.is_empty() or finished:
		spawn_timer.stop()
		return
	if enemies.get_child_count() >= max_enemies:
		return
	var configure: Callable = _queue.pop_front()
	var layer := EnemyTypes.nav_layer("soldier")
	var point: Node3D = _pick_spawn_point(layer)
	var offset := Vector3(randf_range(-SPAWN_SPREAD, SPAWN_SPREAD), 0.0, randf_range(-SPAWN_SPREAD, SPAWN_SPREAD))
	var pos := point.global_position + offset
	if off_navmesh(pos, layer) > SPAWN_OFF_MESH:
		pos = point.global_position
	spawn_soldier_at(pos, configure)


## Something the player can hold USE on: within USE_REACH of `node`, USE
## shows `text`; held for `hold` s, on_done is called once.
func add_interactable(node: Node3D, text: String, hold: float, on_done: Callable) -> Dictionary:
	var it := {"node": node, "text": text, "hold": hold, "on_done": on_done, "active": true}
	interactables.append(it)
	return it


## The active interactable in reach ({} = none).
func interactable_in_reach() -> Dictionary:
	if player.is_dead:
		return {}
	var best := {}
	var best_d := Missions.USE_REACH
	for it in interactables:
		if not it.active or not is_instance_valid(it.node):
			continue
		var p: Vector3 = (it.node as Node3D).global_position
		var d := Vector2(p.x - player.global_position.x, p.z - player.global_position.z).length()
		if d <= best_d:
			best_d = d
			best = it
	return best


func _update_interactables(delta: float) -> void:
	var it := interactable_in_reach()
	ui.use_text = it.text if not it.is_empty() else ""
	if it.is_empty() or not ui.use_held or it != _hold_target:
		_hold_target = it
		_hold = 0.0
		ui.use_progress = 0.0
		if it.is_empty() or not ui.use_held:
			return
	_hold += delta
	ui.use_progress = clampf(_hold / float(it.hold), 0.0, 1.0)
	if _hold >= float(it.hold):
		it.active = false
		_hold = 0.0
		ui.use_progress = 0.0
		ui.use_text = ""
		(it.on_done as Callable).call()
