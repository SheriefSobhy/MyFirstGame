extends "res://missions/objective.gd"
## Mission type "Hunt the Commander" (missions_config.gd: spots, bodyguards,
## vehicle, commander_hp, radio_count, intel_radius, par_time).
## The Commander (a tactical_soldier.gd with make_commander(): red-tinted
## uniform, red beret, a vest that halves non-headshot damage, more health)
## stands at one of `spots` (random) with his bodyguards around him, all
## guards (objective.gd). An intel ring marks his rough area (off-centre).
## Once he is alerted (sees / hears the player, is shot, a bodyguard's radio
## report) he runs for his escape car (missions/escape_vehicle.gd), and
## RADIO_DELAY s later radios for help: radio_count soldiers come in and
## the car's engine starts. He reaches the car = fail (it drives off);
## killed = win.

const M := preload("res://missions/missions_config.gd")
const ZoneRing := preload("res://missions/zone_ring.gd")
const Vehicle := preload("res://missions/escape_vehicle.gd")
const Synth := preload("res://effects/synth_sounds.gd")
const INTEL := Color(1.0, 0.6, 0.2)

## Tests: force his spot (index into `spots`; -1 = random).
static var force_spot := -1

var spot_index := 0
var commander: Node
var bodyguards: Array[Node] = []
var intel: Node3D
var vehicle: Vehicle
var spotted := false
var radioed := false
var escaped := false
var _radio: AudioStreamPlayer3D


func setup() -> void:
	var spots: Array = mission.spots
	spot_index = force_spot if force_spot >= 0 and force_spot < spots.size() else randi() % spots.size()
	var spot: Vector3 = spots[spot_index][0]
	var yaw: float = spots[spot_index][1]
	var v: Dictionary = mission.vehicle
	vehicle = Vehicle.new()
	vehicle.name = "EscapeVehicle"
	mode.add_child(vehicle)
	vehicle.global_position = Vector3(v.pos.x, 0.0, v.pos.z)
	vehicle.rotation.y = deg_to_rad(v.yaw)
	commander = spawn_guard(spot, yaw, func(s: Node) -> void:
		s.hp_override = int(mission.commander_hp)
		s.flee_speed = M.COMMANDER_FLEE
		s.name = "Commander")
	commander.make_commander(M.COMMANDER_TINT, M.COMMANDER_BERET, M.COMMANDER_ARMOR)
	commander.alerted.connect(_on_spotted)
	commander.died.connect(_on_commander_died)
	commander.fled.connect(_on_fled)
	for b: Array in mission.bodyguards:
		bodyguards.append(spawn_guard(spot + (b[0] as Vector3), b[1]))
	var r := float(mission.intel_radius)
	var a := randf() * TAU
	intel = ZoneRing.new(r, INTEL)
	intel.name = "Intel"
	mode.add_child(intel)
	intel.global_position = mode.snap(spot) + Vector3(cos(a), 0.0, sin(a)) * r * randf_range(0.2, 0.5)
	_radio = AudioStreamPlayer3D.new()
	_radio.stream = Synth.radio()
	_radio.unit_size = 10.0
	_radio.max_distance = 60.0
	commander.add_child(_radio)
	_radio.position.y = 1.6


func tick(_delta: float) -> void:
	if escaped:
		return
	var alive: bool = is_instance_valid(commander) and commander.state != commander.State.DEAD
	if not spotted:
		mode.ui.set_tracker("Find and eliminate the Commander", -1.0,
				"Time %s   ·   Intel: he's inside the orange ring" % M.time_text(mode.elapsed))
		mode.ui.set_marker(intel.global_position, "INTEL")
		return
	if not alive:
		return
	mode.ui.set_health("COMMANDER", commander.hp, commander.max_hp)
	var d: float = Vector2(commander.global_position.x - commander.flee_to.x, commander.global_position.z - commander.flee_to.z).length()
	mode.ui.set_tracker("Stop the Commander! He's running for his car", -1.0,
			"%d m from the car   ·   Time %s" % [roundi(d), M.time_text(mode.elapsed)])
	mode.ui.set_marker(commander.global_position, "COMMANDER")


func star2() -> bool:
	return under_par()


func _on_spotted() -> void:
	if spotted:
		return
	spotted = true
	if is_instance_valid(commander):
		commander.flee_to = flee_spot()
	intel.visible = false
	mode.hud.show_message("The Commander spotted you! He's running!")
	get_tree().create_timer(M.RADIO_DELAY, false).timeout.connect(_call_for_help)


func _call_for_help() -> void:
	if radioed or escaped or mode.finished or not is_instance_valid(commander) or commander.state == commander.State.DEAD:
		return
	radioed = true
	_radio.play()
	vehicle.start_engine()
	for i in int(mission.radio_count):
		mode.queue_soldier()
	mode.hud.show_message("He radioed for backup! Don't let him reach his car!")


func _on_commander_died() -> void:
	if escaped:
		return
	mode.finish(true, "The Commander is down.")


func _on_fled() -> void:
	if mode.finished or not is_instance_valid(commander) or commander.state == commander.State.DEAD:
		return
	escaped = true
	_hide_commander.call_deferred()  # not inside its own physics step
	mode.ui.set_marker(Vector3.INF)
	mode.ui.set_health("", 0.0, 0.0)
	mode.hud.show_message("The Commander got to his car!")
	vehicle.drive_off(float(mission.vehicle.drive))
	get_tree().create_timer(M.VEHICLE_DRIVE_TIME, false).timeout.connect(
			func() -> void: mode.finish(false, "The Commander escaped."))


## Where he runs to: beside the car's door, on the navmesh (the side the
## navmesh reaches; worked out when needed, once the navmesh is ready).
func flee_spot() -> Vector3:
	var best := Vector3.INF
	var best_off := INF
	for side: float in [1.0, -1.0]:
		var p: Vector3 = vehicle.door_spot(side)
		var q: Vector3 = mode.snap(p)
		var off := Vector2(q.x - p.x, q.z - p.z).length()
		if off < best_off:
			best_off = off
			best = q
	return best


func _hide_commander() -> void:
	if not is_instance_valid(commander):
		return
	commander.visible = false
	commander.collision_layer = 0  # gone: no longer blocks or gets shot
	commander.process_mode = Node.PROCESS_MODE_DISABLED
