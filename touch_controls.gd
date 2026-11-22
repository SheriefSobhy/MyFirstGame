extends Control
## On-screen touch controls, drawn with simple shapes (no images).
##  - Anywhere outside the buttons and the joystick: drag to look around.
##  - Bottom-left: a fixed virtual joystick for walking (only while the player's
##    MOVEMENT_ENABLED is on). Only touches that start on it move the player.
##  - Buttons: Shoot (hold for auto fire), Jump, Reload, Switch (next weapon)
##    and Aim (aim down the sights / sniper scope, on/off).
## Each finger is tracked by its touch index, so you can move, look and
## shoot at the same time. Only shown on touch screen devices.

const JOY_RADIUS := 90.0            # how far the knob can move from the center
const KNOB_RADIUS := 40.0
const JOY_MARGIN := 170.0           # joystick centre, from the bottom-left corner
const JOY_TOUCH_SCALE := 1.3        # touches this far out (x JOY_RADIUS) still grab the stick
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
	"switch": {"offset": Vector2(-300, -280), "radius": 48.0, "label": "SWITCH"},
	"aim": {"offset": Vector2(-270, -440), "radius": 48.0, "label": "AIM"},
}

## Show the controls even without a touch screen (handy for testing on PC).
@export var force_show := false

## The player to control; assigned by main.gd.
var player: Node
## Controls (like the pause button) whose touches are left to the GUI.
var blockers: Array[Control] = []

## A finger that jumps further than this (in pixels) between two events is
## treated as a different finger.
const REMAP_DISTANCE := 250.0
## Safety cap on how far a single drag event may turn the view (pixels).
const MAX_LOOK_STEP := 120.0

# Which finger is doing what: role ("joy", "look" or "shoot") -> {index, pos}.
# Fingers are matched by position as well as by touch index, because web
# browsers renumber the remaining touches when one finger lifts. Trusting the
# index alone made the view jump (often up into the sky) when you let go of Shoot.
var _fingers := {}
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
			_touch_up(event.index, event.position)
		queue_redraw()
	elif event is InputEventScreenDrag:
		_touch_drag(event.index, event.position)


func _touch_down(index: int, pos: Vector2) -> void:
	for blocker in blockers:
		if blocker.is_visible_in_tree() and blocker.get_global_rect().has_point(pos):
			return
	match _button_at(pos):
		"shoot":
			_fingers["shoot"] = {"index": index, "pos": pos}
			player.touch_shoot = true
		"jump":
			player.request_jump()
		"reload":
			player.start_reload()
		"switch":
			player.next_weapon(1)
		"aim":
			player.toggle_aim()
		_:
			# Only a touch that starts on the joystick moves; everywhere else
			# (including the left half of the screen) is for aiming.
			if _movement_enabled() and not _fingers.has("joy") \
					and pos.distance_to(_joy_home()) <= JOY_RADIUS * JOY_TOUCH_SCALE:
				_fingers["joy"] = {"index": index, "pos": pos}
				_joy_center = _joy_home()
				var offset := (pos - _joy_center).limit_length(JOY_RADIUS)
				_joy_knob = _joy_center + offset
				player.touch_move = offset / JOY_RADIUS
			elif not _fingers.has("look"):
				_fingers["look"] = {"index": index, "pos": pos}


## Forgets every finger and lets go of the stick and trigger (used when
## the game pauses, since finger lifts aren't seen while paused).
func reset() -> void:
	_fingers.clear()
	if player != null:
		player.touch_move = Vector2.ZERO
		player.touch_shoot = false
	queue_redraw()


func _touch_up(index: int, pos: Vector2) -> void:
	var role := _role_for(index, pos)[0] as String
	_fingers.erase(role)
	match role:
		"joy":
			player.touch_move = Vector2.ZERO
		"shoot":
			player.touch_shoot = false


func _touch_drag(index: int, pos: Vector2) -> void:
	var match_info := _role_for(index, pos)
	var role: String = match_info[0]
	if role == "":
		return
	var trusted: bool = match_info[1]
	var last_pos: Vector2 = _fingers[role].pos
	_fingers[role] = {"index": index, "pos": pos}
	match role:
		"joy":
			var offset := (pos - _joy_center).limit_length(JOY_RADIUS)
			_joy_knob = _joy_center + offset
			# x = strafe, y = forward/back (up on screen = forward), like WASD.
			player.touch_move = offset / JOY_RADIUS
			queue_redraw()
		"look":
			# Measure the movement ourselves instead of using event.relative,
			# and skip the event where a finger was re-identified.
			if trusted:
				var delta := (pos - last_pos).limit_length(MAX_LOOK_STEP)
				player.look(delta * LOOK_SENSITIVITY)


# Works out which tracked finger an event belongs to.
# Returns [role, trusted]: role is "" if no finger is tracked, and trusted is
# false when the finger was matched by position because its index changed.
func _role_for(index: int, pos: Vector2) -> Array:
	var by_index := ""
	var nearest := ""
	var nearest_dist := INF
	for role: String in _fingers:
		var finger: Dictionary = _fingers[role]
		if finger.index == index:
			by_index = role
		var dist := pos.distance_to(finger.pos)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest = role
	if by_index != "" and (by_index == nearest
			or pos.distance_to(_fingers[by_index].pos) < REMAP_DISTANCE):
		return [by_index, true]
	return [nearest, false]


## The joystick's fixed spot near the bottom-left corner.
func _joy_home() -> Vector2:
	return Vector2(JOY_MARGIN, size.y - JOY_MARGIN)


func _movement_enabled() -> bool:
	return player != null and player.MOVEMENT_ENABLED


# Returns the name of the button under pos, or "" if none.
func _button_at(pos: Vector2) -> String:
	for button_name in BUTTONS:
		if _button_shown(button_name) \
				and pos.distance_to(_button_center(button_name)) <= BUTTONS[button_name].radius:
			return button_name
	return ""


# The Aim button shows for every weapon that can aim (all of them).
func _button_shown(button_name: String) -> bool:
	return button_name != "aim" or (player != null and player.can_aim())


func _button_center(button_name: String) -> Vector2:
	return size + BUTTONS[button_name].offset


func _draw() -> void:
	var font := ThemeDB.fallback_font

	# Joystick: drawn where the finger is, or faintly at a default spot.
	if _movement_enabled():
		var center := _joy_home()
		var knob := _joy_knob if _fingers.has("joy") else center
		draw_circle(center, JOY_RADIUS, COLOR_FILL)
		draw_arc(center, JOY_RADIUS, 0.0, TAU, 48, COLOR_LINE, 2.0)
		draw_circle(knob, KNOB_RADIUS, COLOR_PRESSED)

	# Buttons.
	for button_name in BUTTONS:
		if not _button_shown(button_name):
			continue
		var b: Dictionary = BUTTONS[button_name]
		var c := _button_center(button_name)
		var held: bool = (button_name == "shoot" and _fingers.has("shoot")) \
				or (button_name == "aim" and player.is_aiming())
		draw_circle(c, b.radius, COLOR_PRESSED if held else COLOR_FILL)
		draw_arc(c, b.radius, 0.0, TAU, 48, COLOR_LINE, 2.0)
		draw_string(font, Vector2(c.x - b.radius, c.y + FONT_SIZE * 0.35), b.label,
				HORIZONTAL_ALIGNMENT_CENTER, b.radius * 2.0, FONT_SIZE)
