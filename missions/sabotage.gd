extends "res://missions/objective.gd"
## Mission type "Sabotage" (missions_config.gd: targets, guards, exit,
## countdown, reinforcements, par_time). Two or three targets
## (missions/sabotage_target.gd: generator, fuel tank, truck) with guards
## around them. Hold USE PLANT_TIME s next to a target to plant a charge;
## the player stands still and exposed meanwhile, and after
## PLANT_NOISE_AFTER s the guards within PLANT_NOISE m hear it.
## Reinforcements come after the n-th charge. After the last one the
## countdown starts and the exit zone shows: when it ends every target blows
## up (BLAST_STAGGER s apart); the player inside the exit zone at that
## moment = win, anywhere else = fail (and close to a target, the blast hurts).

const M := preload("res://missions/missions_config.gd")
const ZoneRing := preload("res://missions/zone_ring.gd")
const Target := preload("res://missions/sabotage_target.gd")
const GREEN := Color(0.35, 1.0, 0.45)
const RED := Color(1.0, 0.3, 0.2)

var targets: Array[Target] = []
var exit_zone: Node3D
var planted_count := 0
## Seconds left on the countdown (INF before the last charge).
var countdown_left := INF
var detonated := false
var _reinforcements_sent := 0


func setup() -> void:
	for t: Dictionary in mission.targets:
		var target := Target.new(t.kind)
		target.name = "Target_%s" % t.kind
		mode.add_child(target)
		var p: Vector3 = t.pos
		target.global_position = Vector3(p.x, 0.0, p.z)
		target.rotation.y = deg_to_rad(t.yaw)
		targets.append(target)
		var reach := maxf(target.size.x, target.size.z) * 0.5 + 1.0
		mode.add_interactable(target, "PLANT C4", M.PLANT_TIME, _plant.bind(target), reach)
	exit_zone = ZoneRing.new(mission.exit.radius, GREEN)
	exit_zone.name = "Exit"
	mode.add_child(exit_zone)
	exit_zone.global_position = mode.snap(mission.exit.pos)
	exit_zone.visible = false
	spawn_guards(mission.guards)
	listen_for_gunshots()


func tick(delta: float) -> void:
	if detonated:
		return
	_planting_noise()
	if countdown_left == INF:
		var left := targets.filter(func(t: Target) -> bool: return not t.planted)
		mode.ui.set_tracker("Plant C4 on the targets (%d/%d)" % [planted_count, targets.size()],
				float(planted_count) / targets.size(),
				"Time %s   ·   Hold USE %d s on each" % [M.time_text(mode.elapsed), int(M.PLANT_TIME)])
		mode.ui.set_marker(_nearest(left).global_position if not left.is_empty() else Vector3.INF, "TARGET")
		return
	countdown_left -= delta
	var share := clampf(countdown_left / float(mission.countdown), 0.0, 1.0)
	for t in targets:
		t.beep_interval = lerpf(M.C4_BEEP.y, M.C4_BEEP.x, share)
	var inside: bool = exit_zone.contains(mode.player.global_position)
	exit_zone.color = GREEN if inside else RED
	mode.ui.set_tracker("Get to the exit!" if not inside else "Stay in the exit zone!", share,
			"Blast in %s" % M.time_text(countdown_left), RED)
	mode.ui.set_marker(exit_zone.global_position if not inside else Vector3.INF, "EXIT")
	if countdown_left <= 0.0:
		_detonate(inside)


func star2() -> bool:
	return under_par()


# Holding USE on a target makes noise: the guards close by come.
func _planting_noise() -> void:
	if mode.ui.use_progress * M.PLANT_TIME < M.PLANT_NOISE_AFTER:
		return
	var it: Dictionary = mode.interactable_in_reach()
	if not it.is_empty() and it.node is Target:
		alert_guards_near(mode.player.global_position, M.PLANT_NOISE)


func _plant(target: Target) -> void:
	target.plant()
	planted_count += 1
	var reinf: Array = mission.reinforcements
	while _reinforcements_sent < reinf.size() and planted_count >= int(reinf[_reinforcements_sent].after_plant):
		for i in int(reinf[_reinforcements_sent].count):
			mode.queue_soldier()
		_reinforcements_sent += 1
	if planted_count < targets.size():
		mode.hud.show_message("Charge planted (%d/%d). Enemy reinforcements!" % [planted_count, targets.size()])
		return
	countdown_left = float(mission.countdown)
	exit_zone.visible = true
	mode.hud.show_message("Charges armed! Get to the exit!")


# Time's up: every target blows (BLAST_STAGGER s apart), then the result.
func _detonate(player_safe: bool) -> void:
	detonated = true
	countdown_left = 0.0
	mode.ui.set_marker(Vector3.INF)
	if player_safe:
		mode.player.invincible = true  # the result is decided: in the exit zone
	for i in targets.size():
		var t := targets[i]
		if i == 0:
			t.blow(mode.player)
		else:
			get_tree().create_timer(M.BLAST_STAGGER * i, false).timeout.connect(t.blow.bind(mode.player))
	var done := get_tree().create_timer(M.BLAST_STAGGER * (targets.size() - 1) + 0.7, false)
	done.timeout.connect(func() -> void:
		if player_safe:
			mode.finish(true, "Every target destroyed.")
		else:
			mode.finish(false, "You didn't reach the exit in time."))


func _nearest(list: Array) -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for t: Node3D in list:
		var d := t.global_position.distance_to(mode.player.global_position)
		if d < best_d:
			best_d = d
			best = t
	return best
