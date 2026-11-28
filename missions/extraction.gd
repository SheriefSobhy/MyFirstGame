extends "res://missions/objective.gd"
## Mission type "Extraction" (missions_config.gd: guards, lz, hold,
## hold_waves, par_time). The player starts at one end of the map; soldiers
## hold positions on the way (guards, objective.gd) to the landing zone at
## the other end.
##  REACH  get into the LZ ring
##  HOLD   stay in it for `hold` s (the clock stops while outside it);
##         soldiers come in waves (hold_waves, at s of holding). The
##         helicopter (missions/helicopter.gd) flies in over the last
##         HELI_APPROACH s, its approach tied to the clock, and lands as it ends
##  BOARD  step within BOARD_RADIUS m of it = win (it lifts off)

const M := preload("res://missions/missions_config.gd")
const ZoneRing := preload("res://missions/zone_ring.gd")
const Helicopter := preload("res://missions/helicopter.gd")
const BLUE := Color(0.3, 0.7, 1.0)
const IDLE := Color(1.0, 0.85, 0.35)
const GREEN := Color(0.35, 1.0, 0.45)

enum Phase { REACH, HOLD, BOARD }

var phase := Phase.REACH
var lz: Node3D
var heli: Helicopter
var board_ring: Node3D
## Seconds the LZ has been held.
var hold_elapsed := 0.0
var player_inside := false
var _waves_sent := 0


func setup() -> void:
	lz = ZoneRing.new(mission.lz.radius, IDLE)
	lz.name = "LandingZone"
	mode.add_child(lz)
	lz.global_position = mode.snap(mission.lz.pos)
	heli = Helicopter.new()
	heli.name = "Helicopter"
	heli.driven = true
	mode.add_child(heli)
	board_ring = ZoneRing.new(M.BOARD_RADIUS, GREEN)
	board_ring.name = "Board"
	mode.add_child(board_ring)
	board_ring.global_position = lz.global_position
	board_ring.visible = false
	spawn_guards(mission.guards)


func tick(delta: float) -> void:
	player_inside = not mode.player.is_dead and lz.contains(mode.player.global_position)
	match phase:
		Phase.REACH:
			mode.ui.set_tracker("Reach the landing zone", -1.0, "Time %s   ·   Par %s" % [M.time_text(mode.elapsed), M.time_text(mission.par_time)])
			mode.ui.set_marker(lz.global_position, "LZ")
			if player_inside:
				phase = Phase.HOLD
				alert_all_guards()
				mode.hud.show_message("Hold the landing zone! The helicopter is on its way.")
		Phase.HOLD:
			_hold(delta)
		Phase.BOARD:
			mode.ui.set_tracker("Get on the helicopter!", -1.0, "Time %s" % M.time_text(mode.elapsed))
			mode.ui.set_marker(heli.global_position, "BOARD")
			var p: Vector3 = mode.player.global_position
			if Vector2(p.x - heli.spot.x, p.z - heli.spot.z).length() <= M.BOARD_RADIUS:
				mode.finish(true, "You made it out.")
				board_ring.visible = false
				get_tree().create_timer(0.6, false).timeout.connect(heli.lift_off)


func star2() -> bool:
	return under_par()


func _hold(delta: float) -> void:
	var hold := float(mission.hold)
	if player_inside:
		hold_elapsed = minf(hold_elapsed + delta, hold)
	var waves: Array = mission.hold_waves
	while _waves_sent < waves.size() and hold_elapsed >= float(waves[_waves_sent].at):
		for i in int(waves[_waves_sent].count):
			mode.queue_soldier()
		_waves_sent += 1
		if _waves_sent > 1:
			mode.hud.show_message("Enemy wave incoming!")
	# The helicopter's approach follows the hold clock.
	var approach_start := hold - M.HELI_APPROACH
	if hold_elapsed >= approach_start:
		if heli.state == Helicopter.State.AWAY:
			heli.arrive(lz.global_position, float(mission.lz.yaw), M.HELI_APPROACH)
			mode.hud.show_message("Helicopter inbound!")
		heli.progress = clampf((hold_elapsed - approach_start) / M.HELI_APPROACH, 0.0, 1.0)
	lz.color = BLUE if player_inside else IDLE
	var left := hold - hold_elapsed
	mode.ui.set_tracker("Hold the landing zone" if player_inside else "Get back to the landing zone!",
			hold_elapsed / hold, "Helicopter in %s" % M.time_text(left), BLUE)
	mode.ui.set_marker(lz.global_position if not player_inside else Vector3.INF, "LZ")
	if hold_elapsed >= hold:
		heli.progress = 1.0
		phase = Phase.BOARD
		board_ring.visible = true
		mode.hud.show_message("The helicopter has landed. Get on board!")
