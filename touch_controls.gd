extends Control
## On-screen touch controls, drawn with simple shapes (no images).
##  - Anywhere outside the buttons: drag to look around.
##  - Left half: a virtual joystick, only while the player's MOVEMENT_ENABLED is on
##    (walking is switched off for now, so the whole screen is for aiming).
##  - Buttons: Shoot (hold for auto fire), Jump, Reload.
## Each finger is tracked by its touch index, so you can move, look and
## shoot at the same time. Only shown on touch screen devices.

const JOY_RADIUS := 90.0            # how far the knob can move from the center
const KNOB_RADIUS := 40.0
const LOOK_SENSITIVITY := 1.5       # multiplier on top of the player's mouse sensitivity
const FONT_SIZE := 22
const COLOR_FILL := Color(1, 1, 1, 0.15)
const COLOR_PRESSED := Color(1, 1, 1, 0.4)
const COLOR_LINE := Color(1, 1, 1, 0.6)

# Buttons: position is an offset from the bottom-right corner of the screen.
const BUTTONS := {
	"shoot": {"offset": Vector2(-150, -190), "radius": 75.0, "label": "SHOOT"},
	"jump": {"offset": Vector2(-310, -120), "radius": 55.0, "label": "JUMP"},
	"reload": {"offset": Vector2(-120, -370), "radius": 50.0, "label": "RELOAD"},
}

## Show the controls even without a touch screen (handy for testing on PC).
@export var force_show := false

## The player to control; assigned by main.gd.
var player: Node

# Which finger (touch index) is doing what; -1 = none.
var _joy_index := -1
var _look_index := -1
var _shoot_index := -1
var _joy_center := Vector2.ZERO
var _joy_knob := Vector2.ZERO


func _ready() -> void:
	visible = force_show or DisplayServer.is_touchscreen_available()
	resized.connect(queue_redraw)


func _input(event: InputEvent) -> void:
	if not visible or player == null:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_down(event.index, event.position)
		else:
			_touch_up(event.index)
		queue_redraw()
	elif event is InputEventScreenDrag:
		_touch_drag(event.index, event.position, event.relative)


func _touch_down(index: int, pos: Vector2) -> void:
	match _button_at(pos):
		"shoot":
			_shoot_index = index
			player.touch_shoot = true
		"jump":
			player.request_jump()
		"reload":
			player.start_reload()
		_:
			if _movement_enabled() and pos.x < size.x * 0.5:
				if _joy_index == -1:
					# Start the joystick wherever the finger lands.
					_joy_index = index
					_joy_center = pos
					_joy_knob = pos
			elif _look_index == -1:
				_look_index = index


func _touch_up(index: int) -> void:
	if index == _joy_index:
		_joy_index = -1
		player.touch_move = Vector2.ZERO
	elif index == _look_index:
		_look_index = -1
	elif index == _shoot_index:
		_shoot_index = -1
		player.touch_shoot = false


func _touch_drag(index: int, pos: Vector2, relative: Vector2) -> void:
	if index == _joy_index:
		var offset := (pos - _joy_center).limit_length(JOY_RADIUS)
		_joy_knob = _joy_center + offset
		# x = strafe, y = forward/back (up on screen = forward), like WASD.
		player.touch_move = offset / JOY_RADIUS
		queue_redraw()
	elif index == _look_index:
		player.look(relative * LOOK_SENSITIVITY)


func _movement_enabled() -> bool:
	return player != null and player.MOVEMENT_ENABLED


# Returns the name of the button under pos, or "" if none.
func _button_at(pos: Vector2) -> String:
	for button_name in BUTTONS:
		if pos.distance_to(_button_center(button_name)) <= BUTTONS[button_name].radius:
			return button_name
	return ""


func _button_center(button_name: String) -> Vector2:
	return size + BUTTONS[button_name].offset


func _draw() -> void:
	var font := ThemeDB.fallback_font

	# Joystick: drawn where the finger is, or faintly at a default spot.
	if _movement_enabled():
		var center := _joy_center if _joy_index != -1 else Vector2(170, size.y - 170)
		var knob := _joy_knob if _joy_index != -1 else center
		draw_circle(center, JOY_RADIUS, COLOR_FILL)
		draw_arc(center, JOY_RADIUS, 0.0, TAU, 48, COLOR_LINE, 2.0)
		draw_circle(knob, KNOB_RADIUS, COLOR_PRESSED)

	# Buttons.
	for button_name in BUTTONS:
		var b: Dictionary = BUTTONS[button_name]
		var c := _button_center(button_name)
		var held: bool = button_name == "shoot" and _shoot_index != -1
		draw_circle(c, b.radius, COLOR_PRESSED if held else COLOR_FILL)
		draw_arc(c, b.radius, 0.0, TAU, 48, COLOR_LINE, 2.0)
		draw_string(font, Vector2(c.x - b.radius, c.y + FONT_SIZE * 0.35), b.label,
				HORIZONTAL_ALIGNMENT_CENTER, b.radius * 2.0, FONT_SIZE)
