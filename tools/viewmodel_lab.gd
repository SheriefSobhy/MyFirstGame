extends SceneTree
## Renders the first-person arms + one gun on their own, from the eye and
## from outside, for tuning hand poses (needs a window):
##   godot --path . --script res://tools/viewmodel_lab.gd -- --out <dir> [--weapon <slot>] [--ads] [--views fp,side,top,front] [--reload <0..1>]
## Writes <dir>/<slot>_<view>.png.

const Weapons := preload("res://weapon_stats.gd")
var WeaponView: GDScript
var FpArms: GDScript
const VIEW_SCALE := 0.5


func _initialize() -> void:
	_run.call_deferred()


func _arg(name: String, def := "") -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else def


func _run() -> void:
	WeaponView = load("res://weapon_view.gd")
	FpArms = load("res://fp_arms.gd")
	var out := _arg("--out", "user://lab")
	DirAccess.make_dir_recursive_absolute(out)
	var slots: Array = Array(_arg("--weapon", "0,1,2,3,4,5,6,7").split(",")).map(func(x: String) -> int: return int(x))
	var views: PackedStringArray = _arg("--views", "fp,side,top").split(",")
	var world := Node3D.new()
	root.add_child(world)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.35, 0.4, 0.45)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.environment.ambient_light_energy = 0.8
	world.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	world.add_child(sun)
	var cam := Camera3D.new()
	cam.fov = 75.0
	cam.near = 0.03
	cam.position = Vector3(0, 1.6, 0)
	world.add_child(cam)
	var vm := Node3D.new()
	vm.scale = Vector3.ONE * VIEW_SCALE
	cam.add_child(vm)
	var sway := Node3D.new()
	vm.add_child(sway)
	var pose := Node3D.new()
	sway.add_child(pose)
	var arms: Node3D = FpArms.new()
	vm.add_child(arms)
	var other := Camera3D.new()
	other.fov = 30.0
	other.near = 0.01
	world.add_child(other)
	for slot: int in slots:
		var w: Dictionary = Weapons.LIST[slot]
		var view: Node3D = WeaponView.new()
		pose.add_child(view)
		view.transform = Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3.ZERO)
		view.setup(w, 2)
		arms.set_targets(view.right_target, view.left_target)
		sway.position = w.hip
		sway.rotation_degrees = Vector3(3, 3, -2)
		if "--ads" in OS.get_cmdline_user_args():
			sway.rotation = Vector3.ZERO
			sway.position = Vector3(0, -w.sight_height - 0.002, -w.ads_distance)
		if "--handtest" in OS.get_cmdline_user_args():
			# Flat hands, fingers forward, palms down, then curl 0.5 on the left.
			for t: Node3D in [view.right_target, view.left_target]:
				var fwd := Vector3(1, 0, 0)
				var palm := Vector3(0, -1, 0)
				t.basis = Basis(fwd.cross(palm), fwd, palm)
				t.set_meta("curl", [0.0, 0.0, 0.0, 0.0])
				t.set_meta("thumb", 0.0)
			view.left_target.set_meta("curl", [0.0, 0.5, 1.0, 1.0])
			view.right_target.position = Vector3(0.0, 0.0, 0.05)
			view.left_target.position = Vector3(0.15, 0.0, -0.08)
		if _arg("--reload") != "":
			view.reload(w.reload_time, pose)
			await create_timer(w.reload_time * float(_arg("--reload"))).timeout
		await process_frame
		await process_frame
		var gun_at: Vector3 = view.global_position + cam.global_basis * Vector3(-0.02, 0.0, -0.1)
		for v in views:
			if v == "fp":
				cam.make_current()
			else:
				var dir := {"side": Vector3(1.0, 0.15, 0.1), "top": Vector3(0.05, 1.0, 0.25), "front": Vector3(0.3, 0.1, -1.0), "left": Vector3(-1.0, 0.1, 0.1)}[v] as Vector3
				other.global_position = gun_at + dir.normalized() * 1.4
				other.look_at(gun_at, Vector3.FORWARD if v == "top" else Vector3.UP)
				other.make_current()
			await process_frame
			await RenderingServer.frame_post_draw
			root.get_viewport().get_texture().get_image().save_png(out.path_join("%d_%s.png" % [slot, v]))
		view.queue_free()
		await process_frame
	print("lab done")
	quit(0)
