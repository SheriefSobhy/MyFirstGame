extends SceneTree
## Multi-touch: holding the joystick (and looking) while other fingers tap or
## hold each button never lets go of them.
##   godot --headless --path . --script res://tools/test_touch.gd --fixed-fps 60
## Prints PASS/FAIL per check and exits with code 1 if anything failed.

var failures := 0
var player: Node
var touch: Control
var spawn: Vector3


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		failures += 1


func frames(n: int) -> void:
	for i in n:
		await physics_frame
		await process_frame


func _touch(index: int, pos: Vector2, pressed: bool) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.position = pos
	ev.pressed = pressed
	root.push_input(ev, true)


func _drag(index: int, pos: Vector2) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = index
	ev.position = pos
	root.push_input(ev, true)


# The stick is still held forward, the player still walks and the finger
# still steers it.
func _walking(what: String) -> void:
	player.global_position = spawn
	var from := spawn
	await frames(8)
	var moved: bool = player.global_position.distance_to(from) > 0.1
	player.global_position = spawn
	_drag(0, touch._joy_home() + Vector2(30, -80))
	var steers: bool = player.touch_move.x > 0.2
	_drag(0, touch._joy_home() + Vector2(0, -80))
	check(moved and steers and player.touch_move.y < -0.5, "still walking " + what)


func _run() -> void:
	change_scene_to_file("res://main.tscn")
	for i in 600:
		await process_frame
		if current_scene != null and current_scene.name == "Main":
			break
	await frames(10)
	var main := current_scene
	main.set_process(false)  # no waves
	player = main.player
	player.invincible = true
	spawn = player.global_position
	touch = main.hud.touch_controls
	touch.force_show = true
	touch.visible = true

	var home: Vector2 = touch._joy_home()
	_touch(0, home, true)
	_drag(0, home + Vector2(0, -80))
	await _walking("with only the joystick")

	for button: String in ["aim", "reload", "switch", "jump", "grenade", "shoot"]:
		var c: Vector2 = touch._button_center(button)
		for time in 2:  # twice: AIM in, then out
			_touch(1, c, true)
			await _walking("while %s is down (%d)" % [button.to_upper(), time + 1])
			_touch(1, c, false)
			await _walking("after %s is lifted (%d)" % [button.to_upper(), time + 1])
			await frames(30)
	check(not player.touch_shoot, "SHOOT is let go")

	# USE (missions): a button touch_controls leaves alone.
	var ui: Control = load("res://missions/mission_ui.gd").new()
	main.hud.add_child(ui)
	ui.use_text = "USE"
	touch.blockers.append(ui.use_button)
	await frames(2)
	# Headless has no touch screen, so the button has its wide PC shape.
	var use: Vector2 = ui.use_button.get_global_rect().get_center()
	_touch(1, use, true)
	check(ui.use_held, "USE is held")
	_touch(2, touch._button_center("aim"), true)
	_touch(2, touch._button_center("aim"), false)
	check(ui.use_held, "USE stays held through an AIM tap")
	await _walking("while USE is down")
	_touch(1, use, false)
	check(not ui.use_held, "USE is let go")
	await _walking("after USE is lifted")
	touch.blockers.erase(ui.use_button)
	ui.queue_free()

	# Joystick + look + held SHOOT, with taps and extra fingers on top.
	var look := Vector2(touch.size.x * 0.5, 150)
	var shoot: Vector2 = touch._button_center("shoot")
	_touch(1, look, true)
	_touch(2, shoot, true)
	for button: String in ["aim", "reload", "jump", "aim"]:
		_touch(3, touch._button_center(button), true)
		_touch(3, touch._button_center(button), false)
	_touch(3, shoot + Vector2(20, 0), true)  # a second finger on SHOOT
	_touch(3, shoot + Vector2(20, 0), false)
	_touch(3, look + Vector2(0, 60), true)   # a finger with no job
	_touch(3, look + Vector2(0, 60), false)
	check(player.touch_shoot, "SHOOT stays held through other taps")
	var yaw: float = player.rotation.y
	_drag(1, look + Vector2(60, 0))
	check(not is_equal_approx(player.rotation.y, yaw), "the look finger still turns the view")
	await _walking("with look and SHOOT held")

	# Web browsers renumber the fingers left after one lifts.
	_touch(0, shoot, false)  # SHOOT, now reported as index 0
	check(player.touch_move.y < -0.5 and not player.touch_shoot, "a renumbered lift releases the right finger")
	_touch(1, look + Vector2(60, 0), false)
	_touch(0, home + Vector2(0, -80), false)
	check(player.touch_move == Vector2.ZERO, "lifting the joystick stops")
	check(touch._fingers.is_empty(), "no finger left over")

	print("\n%s: %d failure(s)" % ["OK" if failures == 0 else "FAILED", failures])
	quit(1 if failures > 0 else 0)
