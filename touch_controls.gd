extends Control
## On-screen touch controls, drawn with simple shapes (no images).
##  - Anywhere outside the buttons and the joystick: drag to look around.
##  - Bottom-left: a fixed virtual joystick for walking (only while the player's
##    MOVEMENT_ENABLED is on). Only touches that start on it move the player.
##  - Buttons: Shoot (hold for auto fire), Jump, Reload, Aim (aim down the
##    sights / sniper scope, on/off), Grenade (hold to see the throw arc,
##    let go to throw) and Switch: tap for the next weapon, or hold / drag to
##    open the weapon wheel and let go over a weapon to pick it.
## Each finger is tracked by its touch index, so you can move, look and
## shoot at the same time. Only shown on touch screen devices.
##
## Layout: buttons can be moved and resized (Settings > Customize Controls,
## ui/controls_editor.gd, saved in Settings.touch_layout), the whole set can
## be mirrored for left-handed players (Settings.left_handed: joystick on the
## right, buttons on the left) and faded (Settings.touch_opacity).
## `edit_mode` draws every button for the editor and ignores the game.

const JOY_RADIUS := 90.0            # how far the knob can move from the center
const KNOB_RADIUS := 40.0
const JOY_MARGIN := 170.0           # joystick centre, from the bottom-left corner
const JOY_TOUCH_SCALE := 1.3        # touches this far out (x JOY_RADIUS) still grab the stick
const LOOK_SENSITIVITY := 1.5       # multiplier on top of the player's mouse sensitivity
const FONT_SIZE := 22
const COLOR_FILL := Color(1, 1, 1, 0.15)
const COLOR_PRESSED := Color(1, 1, 1, 0.4)
const COLOR_LINE := Color(1, 1, 1, 0.6)
const COLOR_HIGHLIGHT := Color(1, 0.8, 0.3)    # tutorial pointer, editor selection

# Buttons: position is an offset from the bottom-right corner of the screen.
const BUTTONS := {
	"shoot": {"offset": Vector2(-150, -190), "radius": 75.0, "label": "SHOOT"},
	"jump": {"offset": Vector2(-310, -120), "radius": 55.0, "label": "JUMP"},
	"reload": {"offset": Vector2(-120, -370), "radius": 50.0, "label": "RELOAD"},
	"switch": {"offset": Vector2(-300, -280), "radius": 48.0, "label": "SWITCH"},
	"aim": {"offset": Vector2(-270, -440), "radius": 48.0, "label": "AIM"},
	"grenade": {"offset": Vector2(-110, -505), "radius": 50.0, "label": "GRENADE"},
}

# Weapon wheel (opened from the Switch button).
const WHEEL_HOLD_TIME := 0.22       # seconds held before the wheel opens
const WHEEL_DRAG_OPEN := 24.0       # ...or this far dragged (pixels)
const WHEEL_SELECT_DRAG := 35.0     # drag at least this far to pick a slot
const WHEEL_OUTER := 230.0
const WHEEL_INNER := 85.0
const WHEEL_FONT_SIZE := 20
const COLOR_WHEEL := Color(0, 0, 0, 0.45)
const COLOR_WHEEL_PICK := Color(1, 0.8, 0.3, 0.55)
const COLOR_DISABLED := Color(1, 1, 1, 0.25)
const Weapons := preload("res://weapon_stats.gd")

## Show the controls even without a touch screen (handy for testing on PC).
@export var force_show := false

## The player to control; assigned by main.gd.
var player: Node
## Controls (like the pause button) whose touches are left to the GUI.
var blockers: Array[Control] = []
## The tutorial points at a button (or "joy") with a pulsing ring; "" = none.
var highlight := "":
	set(value):
		highlight = value
		queue_redraw()
## Customize Controls: draw every button, no player, selected one outlined.
var edit_mode := false
var edit_selected := ""

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
var _wheel_open := false
var _wheel_pick := -1          # weapon slot under the finger, -1 = none
var _switch_start := Vector2.ZERO
var _switch_time := 0.0        # seconds the Switch button has been held


func _ready() -> void:
	visible = force_show or DisplayServer.is_touchscreen_available()
	resized.connect(queue_redraw)
	Settings.changed.connect(queue_redraw)


func _process(delta: float) -> void:
	if highlight != "":
		queue_redraw()  # the pulsing ring
	# Holding Switch for a moment opens the weapon wheel.
	if _fingers.has("switch") and not _wheel_open:
		_switch_time += delta
		if _switch_time >= WHEEL_HOLD_TIME:
			_open_wheel()


func _input(event: InputEvent) -> void:
	if not visible or player == null or edit_mode:
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
		if is_instance_valid(blocker) and blocker.is_visible_in_tree() and blocker.get_global_rect().has_point(pos):
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
			_fingers["switch"] = {"index": index, "pos": pos}
			_switch_start = pos
			_switch_time = 0.0
			_wheel_open = false
			_wheel_pick = -1
		"grenade":
			_fingers["grenade"] = {"index": index, "pos": pos}
			player.start_grenade()
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
	_wheel_open = false
	_wheel_pick = -1
	if player != null:
		player.touch_move = Vector2.ZERO
		player.touch_shoot = false
		player.cancel_grenade()
	queue_redraw()


func _touch_up(index: int, pos: Vector2) -> void:
	var role := _role_for(index, pos)[0] as String
	_fingers.erase(role)
	match role:
		"joy":
			player.touch_move = Vector2.ZERO
		"shoot":
			player.touch_shoot = false
		"grenade":
			player.throw_grenade()
		"switch":
			_release_switch(pos)
	queue_redraw()


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
		"switch":
			if not _wheel_open and pos.distance_to(_switch_start) >= WHEEL_DRAG_OPEN:
				_open_wheel()
			if _wheel_open:
				_wheel_pick = _wheel_slot_at(pos - _switch_start)
				queue_redraw()
		"look":
			# Measure the movement ourselves instead of using event.relative,
			# and skip the event where a finger was re-identified.
			if trusted:
				var delta := (pos - last_pos).limit_length(MAX_LOOK_STEP)
				player.look(delta * LOOK_SENSITIVITY, true)


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


# --- Weapon wheel -------------------------------------------------------------

func _open_wheel() -> void:
	_wheel_open = true
	queue_redraw()


## True while the weapon wheel is on screen.
func is_wheel_open() -> bool:
	return _wheel_open


# Switch released: a quick tap cycles to the next weapon; with the wheel open,
# the weapon under the finger is picked (nothing if the finger is still
# near the button).
func _release_switch(pos: Vector2) -> void:
	if _wheel_open:
		var slot := _wheel_slot_at(pos - _switch_start)
		if slot >= 0:
			player.switch_to(slot)
	else:
		player.next_weapon(1)
	_wheel_open = false
	_wheel_pick = -1


## The weapon slot in direction "drag" (from where the finger went down),
## or -1 if the drag is too short or that slot's weapon isn't owned.
## Slot 0 is straight up, then clockwise.
func _wheel_slot_at(drag: Vector2) -> int:
	if drag.length() < WHEEL_SELECT_DRAG:
		return -1
	var count := Weapons.LIST.size()
	var angle := fposmod(drag.angle() + PI / 2.0, TAU)  # 0 = up, clockwise
	var slot := roundi(angle / (TAU / count)) % count
	return slot if player.has_weapon(slot) else -1


func _wheel_center() -> Vector2:
	return size * 0.5


func _wheel_slot_center(slot: int, radius: float) -> Vector2:
	var count := Weapons.LIST.size()
	var a := -PI / 2.0 + slot * TAU / count
	return _wheel_center() + Vector2(cos(a), sin(a)) * radius


func _draw_wheel(font: Font) -> void:
	var count := Weapons.LIST.size()
	var c := _wheel_center()
	var step := TAU / count
	for slot in count:
		var a0 := -PI / 2.0 + (slot - 0.5) * step
		var pts := PackedVector2Array()
		for k in 9:
			var a := a0 + step * k / 8.0
			pts.append(c + Vector2(cos(a), sin(a)) * WHEEL_OUTER)
		for k in 9:
			var a := a0 + step * (8 - k) / 8.0
			pts.append(c + Vector2(cos(a), sin(a)) * WHEEL_INNER)
		var owned: bool = player.has_weapon(slot)
		draw_colored_polygon(pts, COLOR_WHEEL_PICK if slot == _wheel_pick else COLOR_WHEEL)
		pts.append(pts[0])
		draw_polyline(pts, COLOR_LINE if slot == player.weapon_index else Color(1, 1, 1, 0.2), 2.0)
		var label_pos := _wheel_slot_center(slot, (WHEEL_OUTER + WHEEL_INNER) * 0.5)
		var w: Dictionary = Weapons.LIST[slot]
		draw_string(font, label_pos + Vector2(-60, -2), w.name, HORIZONTAL_ALIGNMENT_CENTER, 120,
				WHEEL_FONT_SIZE, Color.WHITE if owned else COLOR_DISABLED)
		draw_string(font, label_pos + Vector2(-60, 20), str(slot + 1), HORIZONTAL_ALIGNMENT_CENTER, 120,
				WHEEL_FONT_SIZE - 4, Color(1, 1, 1, 0.6) if owned else COLOR_DISABLED)


## The joystick's fixed spot near the bottom-left corner (bottom-right when
## left-handed).
func _joy_home() -> Vector2:
	return _mirror(Vector2(JOY_MARGIN, size.y - JOY_MARGIN))


func _movement_enabled() -> bool:
	return edit_mode or (player != null and player.MOVEMENT_ENABLED)


# Returns the name of the button under pos, or "" if none.
func _button_at(pos: Vector2) -> String:
	for button_name: String in BUTTONS:
		if _button_shown(button_name) \
				and pos.distance_to(_button_center(button_name)) <= _button_radius(button_name):
			return button_name
	return ""


# The Aim button shows for every weapon that can aim (all of them).
func _button_shown(button_name: String) -> bool:
	return edit_mode or button_name != "aim" or (player != null and player.can_aim())


## Where a button is on screen: its saved spot (Customize Controls) or the
## default, mirrored for left-handed players.
func _button_center(button_name: String) -> Vector2:
	var layout: Dictionary = Settings.button_layout(button_name)
	var p: Vector2 = size + BUTTONS[button_name].offset
	if layout.has("pos"):
		var o: Vector2 = layout.pos
		p = Vector2(o.x if o.x >= 0.0 else size.x + o.x, size.y + o.y)
	return _mirror(p)


func _button_radius(button_name: String) -> float:
	return BUTTONS[button_name].radius * float(Settings.button_layout(button_name).get("scale", 1.0))


func _button_scale(button_name: String) -> float:
	return float(Settings.button_layout(button_name).get("scale", 1.0))


## Customize Controls: puts a button at screen point `pos` (kept on screen)
## with size `scale`, and saves it in Settings. The spot is remembered from
## the nearer side edge, so it stays put on wider or narrower screens.
func place_button(button_name: String, pos: Vector2, scale: float) -> void:
	var r: float = BUTTONS[button_name].radius * clampf(scale, Settings.MIN_BUTTON_SCALE, Settings.MAX_BUTTON_SCALE)
	pos = pos.clamp(Vector2(r, r), size - Vector2(r, r))
	var p := _mirror(pos)  # saved as right-handed
	var x := p.x if p.x < size.x * 0.5 else p.x - size.x
	Settings.set_button_layout(button_name, Vector2(x, p.y - size.y), scale)


func _mirror(p: Vector2) -> Vector2:
	return Vector2(size.x - p.x, p.y) if Settings.left_handed else p


# Button and joystick colours, faded by the opacity setting.
func _fade(c: Color) -> Color:
	return Color(c, c.a * Settings.touch_opacity)


func _draw() -> void:
	var font := ThemeDB.fallback_font

	# Joystick: drawn where the finger is, or faintly at a default spot.
	if _movement_enabled():
		var center := _joy_home()
		var knob := _joy_knob if _fingers.has("joy") else center
		draw_circle(center, JOY_RADIUS, _fade(COLOR_FILL))
		draw_arc(center, JOY_RADIUS, 0.0, TAU, 48, _fade(COLOR_LINE), 2.0)
		draw_circle(knob, KNOB_RADIUS, _fade(COLOR_PRESSED))
		if edit_mode:
			draw_string(font, center + Vector2(-JOY_RADIUS, JOY_RADIUS + 26), "MOVE",
					HORIZONTAL_ALIGNMENT_CENTER, JOY_RADIUS * 2.0, FONT_SIZE - 4, _fade(Color.WHITE))

	# Buttons.
	for button_name: String in BUTTONS:
		if not _button_shown(button_name):
			continue
		var b: Dictionary = BUTTONS[button_name]
		var c := _button_center(button_name)
		var r := _button_radius(button_name)
		var font_size := int(FONT_SIZE * clampf(_button_scale(button_name), 0.8, 1.3))
		var held: bool = player != null and ((button_name in ["shoot", "grenade", "switch"] and _fingers.has(button_name)) \
				or (button_name == "aim" and player.is_aiming()))
		draw_circle(c, r, _fade(COLOR_PRESSED if held else COLOR_FILL))
		draw_arc(c, r, 0.0, TAU, 48, _fade(COLOR_LINE), 2.0)
		if edit_mode and button_name == edit_selected:
			draw_arc(c, r + 6.0, 0.0, TAU, 48, COLOR_HIGHLIGHT, 4.0)
		if button_name == "grenade" and player != null:
			# Label and how many are left; dimmed when there are none.
			var text_color := Color.WHITE if player.grenades > 0 else COLOR_DISABLED
			draw_string(font, Vector2(c.x - r, c.y + 2), b.label,
					HORIZONTAL_ALIGNMENT_CENTER, r * 2.0, font_size - 5, _fade(text_color))
			draw_string(font, Vector2(c.x - r, c.y + 28), "x%d" % player.grenades,
					HORIZONTAL_ALIGNMENT_CENTER, r * 2.0, font_size, _fade(text_color))
		else:
			draw_string(font, Vector2(c.x - r, c.y + font_size * 0.35), b.label,
					HORIZONTAL_ALIGNMENT_CENTER, r * 2.0, font_size - (5 if button_name == "grenade" else 0),
					_fade(Color.WHITE))

	# The tutorial's pointer: a pulsing ring around one button (or the stick).
	if highlight != "":
		var hc := Vector2.ZERO
		var hr := 0.0
		if highlight == "joy":
			hc = _joy_home()
			hr = JOY_RADIUS
		elif BUTTONS.has(highlight) and _button_shown(highlight):
			hc = _button_center(highlight)
			hr = _button_radius(highlight)
		if hr > 0.0:
			var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 160.0)
			draw_arc(hc, hr + 8.0 + pulse * 10.0, 0.0, TAU, 48, Color(COLOR_HIGHLIGHT, 0.5 + 0.5 * pulse), 5.0)

	if _wheel_open:
		_draw_wheel(font)
