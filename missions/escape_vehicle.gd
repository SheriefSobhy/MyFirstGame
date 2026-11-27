extends StaticBody3D
## Hunt the Commander: his escape car (missions/hunt.gd). The Kenney SUV
## (assets/models/vehicles/suv.glb, CC0), dark, with a box collider (cover)
## and a NavigationObstacle3D. start_engine(): idling sound (synth_sounds.gd
## engine_loop) and exhaust; drive_off(): drives `distance` m forward (-Z)
## over VEHICLE_DRIVE_TIME s and disappears.

const M := preload("res://missions/missions_config.gd")
const Synth := preload("res://effects/synth_sounds.gd")
const MODEL := preload("res://assets/models/vehicles/suv.glb")
const SCALE := 1.4
const SIZE := Vector3(2.1, 2.0, 3.9)

var engine_on := false
var driving := false
var _sound: AudioStreamPlayer3D


func _ready() -> void:
	collision_layer = 1
	collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = SIZE
	shape.shape = box
	shape.position.y = SIZE.y * 0.5
	add_child(shape)
	var obstacle := NavigationObstacle3D.new()
	var hx := SIZE.x * 0.5 + 0.1
	var hz := SIZE.z * 0.5 + 0.1
	obstacle.vertices = PackedVector3Array([Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(hx, 0, hz), Vector3(-hx, 0, hz)])
	obstacle.height = SIZE.y
	obstacle.avoidance_enabled = true
	add_child(obstacle)
	var model: Node3D = MODEL.instantiate()
	model.scale = Vector3.ONE * SCALE
	add_child(model)
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		mi.transparency = 0.0
		for s in mi.mesh.get_surface_count():
			var src := mi.get_active_material(s) as BaseMaterial3D
			if src:
				var m := src.duplicate() as BaseMaterial3D
				m.albedo_color = src.albedo_color * Color(0.35, 0.35, 0.38)
				mi.set_surface_override_material(s, m)
	_sound = AudioStreamPlayer3D.new()
	_sound.stream = Synth.engine_loop()
	_sound.unit_size = 7.0
	_sound.max_distance = 45.0
	_sound.position = Vector3(0, 0.8, -1.4)
	add_child(_sound)


## Where the Commander runs to: beside a door (side 1 = driver, -1 = passenger).
func door_spot(side := 1.0) -> Vector3:
	return global_position - global_basis.x * side * (SIZE.x * 0.5 + 0.7)


func start_engine() -> void:
	if engine_on:
		return
	engine_on = true
	_sound.play()


func drive_off(distance: float) -> void:
	if driving:
		return
	driving = true
	start_engine()
	collision_layer = 0
	var to := global_position - global_basis.z * distance
	var tw := create_tween()
	tw.tween_property(self, "global_position", to, M.VEHICLE_DRIVE_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(_sound, "pitch_scale", 1.8, M.VEHICLE_DRIVE_TIME)
	tw.tween_callback(func() -> void:
		visible = false
		_sound.stop())
