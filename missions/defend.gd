extends "res://missions/objective.gd"
## Mission type "Defend the point" (missions_config.gd: zone, duration,
## waves, pusher_share, capture_time). A ring on the ground; soldiers come
## in waves (at the given seconds), some walk into the zone and hold it
## ("pushers", tactical_soldier.gd push_spot), the rest fight from cover.
## While soldiers stand in the zone and the player doesn't, the capture bar
## fills (faster with more of them, CAPTURE_STACK); with nobody of theirs
## inside it drains (CAPTURE_DECAY). Full = fail; the timer running out = win.

const M := preload("res://missions/missions_config.gd")
const ZoneRing := preload("res://missions/zone_ring.gd")
const BLUE := Color(0.3, 0.7, 1.0)
const RED := Color(1.0, 0.25, 0.2)
const IDLE := Color(1.0, 0.85, 0.35)

## 0..1 enemy capture, and the most it reached (star 2).
var capture := 0.0
var max_capture := 0.0
var zone: Node3D
var enemies_inside := 0
var player_inside := false
var _waves_sent := 0


func setup() -> void:
	zone = ZoneRing.new(mission.zone.radius, IDLE)
	zone.name = "DefendZone"
	mode.add_child(zone)
	zone.global_position = mode.snap(mission.zone.pos)


func tick(delta: float) -> void:
	var waves: Array = mission.waves
	while _waves_sent < waves.size() and mode.elapsed >= float(waves[_waves_sent].at):
		_send_wave(int(waves[_waves_sent].count))
		_waves_sent += 1
	enemies_inside = 0
	for e: Node in mode.enemies.get_children():
		if e.state != e.State.DEAD and zone.contains(e.global_position):
			enemies_inside += 1
	player_inside = not mode.player.is_dead and zone.contains(mode.player.global_position)
	if enemies_inside > 0 and not player_inside:
		var rate := (1.0 + M.CAPTURE_STACK * (enemies_inside - 1)) / float(mission.capture_time)
		capture = minf(capture + rate * delta, 1.0)
	elif enemies_inside == 0:
		capture = maxf(capture - M.CAPTURE_DECAY * delta, 0.0)
	max_capture = maxf(max_capture, capture)
	zone.color = BLUE if player_inside else (RED if enemies_inside > 0 else IDLE)
	var left: float = mission.duration - mode.elapsed
	var title := "Defend the point"
	if enemies_inside > 0 and not player_inside:
		title = "They're taking the point: get back in!"
	elif not player_inside:
		title = "Defend the point: stay near the ring"
	mode.ui.set_tracker(title, capture, "Hold for %s   ·   Enemy capture %d%%" % [M.time_text(left), int(capture * 100)], RED)
	mode.ui.set_marker(zone.global_position if not player_inside else Vector3.INF, "POINT")
	if capture >= 1.0:
		mode.finish(false, "The soldiers captured the point.")
	elif left <= 0.0:
		mode.finish(true, "You held the point for %s." % M.time_text(mission.duration))


func star2() -> bool:
	return max_capture <= M.CAPTURE_STAR


# count soldiers from the map's spawn points: the first pusher_share of them
# head into the zone, the others fight from cover.
func _send_wave(count: int) -> void:
	var pushers := ceili(count * float(mission.pusher_share))
	for i in count:
		var push := i < pushers
		mode.queue_soldier(func(s: Node) -> void:
			if push:
				s.push_spot = _push_spot())
	if _waves_sent > 0:
		mode.hud.show_message("Enemy wave incoming!")


func _push_spot() -> Vector3:
	var r: float = mission.zone.radius * M.PUSH_SPOT_RADIUS * sqrt(randf())
	var a := randf() * TAU
	return mode.snap(zone.global_position + Vector3(cos(a), 0.0, sin(a)) * r)
