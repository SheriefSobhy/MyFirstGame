extends Control
## Play on the main menu opens this. Steps:
##  1. a mode (Zombies / Combat, maps.gd MODES);
##  2. Combat only: Waves or Missions;
##  3. a map: one card per map in maps.gd with its picture, description and
##     the best score and stars (3 per map) of that mode, or (Missions) the
##     mission stars on that map;
##  4. Missions only: the map's mission list (missions/missions_config.gd
##     SLOTS slots: unlocked in order, "Coming soon" where none exists yet).
## Maps your level hasn't unlocked show the level they need (the same in
## every mode). Picking a map (or a mission) opens the loading screen
## (ui/loading_screen.gd). Back goes one step back, then to the main menu.

const Maps := preload("res://maps.gd")
const Progression := preload("res://progression_config.gd")
const Missions := preload("res://missions/missions_config.gd")
const StarRow := preload("res://ui/star_row.gd")
const MENU_SCENE := "res://ui/main_menu.tscn"
const LoadingScreen := preload("res://ui/loading_screen.gd")
const WAVES := "waves"
const MISSIONS := "missions"
const COMBAT_KINDS := [
	{"id": WAVES, "name": "Waves", "color": Color(0.95, 0.55, 0.3),
		"description": "Endless waves of soldiers. How long can you last?"},
	{"id": MISSIONS, "name": "Missions", "color": Color(0.45, 0.8, 1.0),
		"description": "Objectives on every map: defend a point, rescue a hostage. Earn 3 stars on each."},
]

enum Step { MODE, COMBAT_KIND, MAPS, MISSION_MAPS, MISSION_LIST }

## The mode picked last (the map cards show it; Zombies at first).
static var last_mode := Maps.ZOMBIES
## Set before opening this scene to go straight to a map's mission list
## (the mission result screen's "Missions" button).
static var open_missions_for := ""

@onready var cards: HBoxContainer = %Cards
@onready var back_button: Button = %BackButton
@onready var loading_label: Label = %Loading
@onready var title: Label = $Margin/Box/Title

## The mode the map cards are for.
var mode := Maps.ZOMBIES
var step := Step.MODE
## The Play button of each map card, by map id (also used by the tests).
## Built for `mode`, also while the mode step is showing.
var play_buttons := {}
## The button of each mode card, by mode id.
var mode_buttons := {}
## Combat: the Waves / Missions buttons.
var combat_buttons := {}
## Missions: the "Missions" button of each map card, by map id.
var mission_map_buttons := {}
## The mission list: the button of each slot (1..SLOTS).
var mission_buttons := {}
## The map whose mission list is showing.
var mission_map := ""
## True while the mode step (Zombies / Combat) is showing.
var choosing_mode := true
var _mode_cards: HBoxContainer
var _combat_cards: HBoxContainer
var _mission_list: VBoxContainer


func _ready() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_mode_cards = _row("ModeCards")
	for m: Dictionary in Maps.MODES:
		_mode_cards.add_child(_make_mode_card(m))
	_combat_cards = _row("CombatCards")
	for k: Dictionary in COMBAT_KINDS:
		_combat_cards.add_child(_make_combat_card(k))
	_mission_list = VBoxContainer.new()
	_mission_list.name = "MissionList"
	_mission_list.add_theme_constant_override("separation", 10)
	_mission_list.alignment = BoxContainer.ALIGNMENT_CENTER
	cards.add_sibling(_mission_list)
	_build_map_cards(last_mode)
	back_button.pressed.connect(_on_back)
	Music.play_menu()
	if open_missions_for != "":
		var id := open_missions_for
		open_missions_for = ""
		last_mode = Maps.COMBAT
		show_mission_list(id)
	else:
		show_modes()


func _row(row_name: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = row_name
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 24)
	cards.add_sibling(row)
	return row


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("release_mouse"):
		_on_back()
		get_viewport().set_input_as_handled()


func _show(s: Step, heading: String) -> void:
	step = s
	choosing_mode = s == Step.MODE
	title.text = heading
	_mode_cards.visible = s == Step.MODE
	_combat_cards.visible = s == Step.COMBAT_KIND
	cards.visible = s == Step.MAPS or s == Step.MISSION_MAPS
	_mission_list.visible = s == Step.MISSION_LIST


## Shows the mode step.
func show_modes() -> void:
	_show(Step.MODE, "Choose a mode")
	_focus(mode_buttons[last_mode])


## Picks a mode: Zombies shows its maps, Combat asks Waves or Missions.
func choose_mode(id: String) -> void:
	last_mode = id
	if id == Maps.COMBAT:
		_show(Step.COMBAT_KIND, "Combat: Waves or Missions?")
		_focus(combat_buttons[WAVES])
		return
	_build_map_cards(id)
	_show(Step.MAPS, "%s: choose a map" % Maps.mode_info(id).name)
	_focus(play_buttons[Maps.LIST[0].id])


## Combat: Waves (the map cards) or Missions (map cards, then the list).
func choose_combat(kind: String) -> void:
	if kind == WAVES:
		_build_map_cards(Maps.COMBAT)
		_show(Step.MAPS, "Combat Waves: choose a map")
		_focus(play_buttons[Maps.LIST[0].id])
	else:
		_build_mission_map_cards()
		_show(Step.MISSION_MAPS, "Combat Missions: choose a map")
		_focus(mission_map_buttons[Maps.LIST[0].id])


func _focus(b: Button) -> void:
	if not DisplayServer.is_touchscreen_available() and b and b.is_inside_tree():
		b.grab_focus.call_deferred()


func _clear_cards() -> void:
	for c in cards.get_children():
		cards.remove_child(c)
		c.queue_free()
	play_buttons.clear()
	mission_map_buttons.clear()


func _build_map_cards(id: String) -> void:
	mode = id
	_clear_cards()
	for m: Dictionary in Maps.LIST:
		cards.add_child(_make_card(m))


func _card_panel(color: Color) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(360, 0)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.05, 0.05, 0.85)
	style.border_color = color
	style.set_border_width_all(3)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _text(text: String, font_size: int, color := Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l


# A big card with a name, a description, an info line and a button.
func _big_card(card_name: String, color: Color, description: String, info: String, button_text: String) -> Array:
	var panel := _card_panel(color)
	panel.custom_minimum_size = Vector2(420, 0)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)
	var name_label := _text(card_name, 44, color)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(name_label)
	var desc := _text(description, 20, Color(1, 1, 1, 0.75))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(0, 84)
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(desc)
	var info_label := _text(info, 20)
	info_label.name = "Info"
	info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(info_label)
	var button := Button.new()
	button.name = "Choose"
	button.text = button_text
	button.custom_minimum_size = Vector2(0, 72)
	button.add_theme_font_size_override("font_size", 32)
	box.add_child(button)
	return [panel, button]


func _make_mode_card(m: Dictionary) -> Control:
	# Best score and stars over all maps in this mode (Waves).
	var best := 0
	var stars := 0
	for map: Dictionary in Maps.LIST:
		var key := Maps.save_key(map.id, m.id)
		best = maxi(best, Settings.best_score_for(key))
		stars += Progress.stars(key)
	var info := "Best: %s     Stars: %d / %d" % [str(best) if best > 0 else "-", stars, Maps.LIST.size() * 3]
	var parts := _big_card(m.name, m.color, m.description, info, "Play %s" % m.name)
	(parts[1] as Button).pressed.connect(choose_mode.bind(m.id))
	mode_buttons[m.id] = parts[1]
	return parts[0]


func _make_combat_card(k: Dictionary) -> Control:
	var info := ""
	if k.id == WAVES:
		var stars := 0
		for map: Dictionary in Maps.LIST:
			stars += Progress.stars(Maps.save_key(map.id, Maps.COMBAT))
		info = "Wave stars: %d / %d" % [stars, Maps.LIST.size() * 3]
	else:
		var got := Vector2i.ZERO
		for map: Dictionary in Maps.LIST:
			got += Progress.mission_stars_on(map.id)
		info = "Mission stars: %d / %d" % [got.x, got.y]
	var parts := _big_card(k.name, k.color, k.description, info, k.name)
	(parts[1] as Button).pressed.connect(choose_combat.bind(k.id))
	combat_buttons[k.id] = parts[1]
	return parts[0]


# Picture, name and description of a map card; returns [panel, box, pic].
func _map_card_top(m: Dictionary) -> Array:
	var panel := _card_panel(m.color)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	var pic := TextureRect.new()
	pic.custom_minimum_size = Vector2(0, 190)
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	if ResourceLoader.exists(m.thumbnail):
		pic.texture = load(m.thumbnail)
	box.add_child(pic)
	box.add_child(_text(m.name, 30, m.color))
	var desc := _text(m.description, 18, Color(1, 1, 1, 0.75))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(0, 56)
	box.add_child(desc)
	return [panel, box, pic]


func _make_card(m: Dictionary) -> Control:
	var key := Maps.save_key(m.id, mode)
	var top := _map_card_top(m)
	var box: VBoxContainer = top[1]
	var pic: TextureRect = top[2]

	var score := Settings.best_score_for(key)
	var best := _text("Best: %d   (wave %d)" % [score, Settings.best_wave_for(key)] if score > 0 else "Best: -", 20)
	best.name = "Best"
	box.add_child(best)

	# Stars: reach wave 5 / 10 / 15 (progression_config.gd STAR_WAVES).
	var star_row := HBoxContainer.new()
	star_row.add_theme_constant_override("separation", 12)
	box.add_child(star_row)
	var stars := StarRow.new(Progress.stars(key), 28.0)
	stars.name = "Stars"
	star_row.add_child(stars)
	star_row.add_child(_text("Reach wave %s" % " / ".join(Progression.STAR_WAVES.map(func(w: int) -> String: return str(w))),
			16, Color(1, 1, 1, 0.55)))

	var play := _map_button(m, pic, "Play")
	play.pressed.connect(_on_play.bind(m))
	box.add_child(play)
	play_buttons[m.id] = play
	return top[0]


# The card's main button: `text`, or "Locked: Level n" (picture dimmed).
func _map_button(m: Dictionary, pic: TextureRect, text: String) -> Button:
	var b := Button.new()
	b.name = "Play"
	b.custom_minimum_size = Vector2(0, 64)
	b.add_theme_font_size_override("font_size", 30)
	if Progress.is_map_unlocked(m.id):
		b.text = text
	else:
		b.text = "Locked: Level %d" % Progression.map_unlock_level(m.id)
		b.disabled = true
		pic.modulate = Color(0.35, 0.35, 0.35)
	return b


func _on_play(m: Dictionary) -> void:
	if not Progress.is_map_unlocked(m.id):
		return
	_disable_all()
	# The loading screen (tip + progress bar) loads the map in the mode.
	LoadingScreen.go(get_tree(), Maps.for_mode(m.id, mode))


func _disable_all() -> void:
	for b: Button in play_buttons.values() + mission_buttons.values():
		b.disabled = true
	back_button.disabled = true


# --- Missions ---------------------------------------------------------------------

func _build_mission_map_cards() -> void:
	mode = Maps.COMBAT
	_clear_cards()
	for m: Dictionary in Maps.LIST:
		var top := _map_card_top(m)
		var box: VBoxContainer = top[1]
		var got := Progress.mission_stars_on(m.id)
		var cleared := Missions.for_map(m.id).filter(func(x: Dictionary) -> bool:
			return Progress.mission_best(x.id) > 0).size()
		var info := _text("Missions cleared: %d / %d" % [cleared, Missions.for_map(m.id).size()], 20)
		info.name = "Best"
		box.add_child(info)
		var star_row := HBoxContainer.new()
		star_row.add_theme_constant_override("separation", 12)
		box.add_child(star_row)
		var stars := StarRow.new(1 if got.x > 0 else 0, 28.0)
		stars.total = 1
		stars.custom_minimum_size = Vector2(28, 28)
		star_row.add_child(stars)
		star_row.add_child(_text("%d / %d stars" % [got.x, got.y], 20))
		var b := _map_button(m, top[2], "Missions")
		b.pressed.connect(show_mission_list.bind(m.id))
		box.add_child(b)
		mission_map_buttons[m.id] = b
		cards.add_child(top[0])


## The mission list of a map: SLOTS rows (name, type, best stars, Play /
## Locked / Coming soon).
func show_mission_list(map_id: String) -> void:
	if not Progress.is_map_unlocked(map_id):
		return
	mode = Maps.COMBAT
	mission_map = map_id
	for c in _mission_list.get_children():
		_mission_list.remove_child(c)
		c.queue_free()
	mission_buttons.clear()
	var map := Maps.find(map_id)
	var first: Button = null
	for slot in range(1, Missions.SLOTS + 1):
		var row := _mission_row(Missions.in_slot(map_id, slot), slot, map.color)
		_mission_list.add_child(row[0])
		mission_buttons[slot] = row[1]
		if first == null and not row[1].disabled:
			first = row[1]
	_show(Step.MISSION_LIST, "%s: Missions" % map.name)
	_focus(first)


func _mission_row(m: Dictionary, slot: int, color: Color) -> Array:
	var panel := _card_panel(color if not m.is_empty() else Color(0.4, 0.4, 0.4))
	panel.custom_minimum_size = Vector2(900, 0)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	panel.add_child(row)
	var num := _text(str(slot), 36, color)
	num.custom_minimum_size = Vector2(40, 0)
	num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(num)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)
	var button := Button.new()
	button.name = "Play"
	button.custom_minimum_size = Vector2(210, 60)
	button.add_theme_font_size_override("font_size", 26)
	if m.is_empty():
		info.add_child(_text("Coming soon", 26, Color(1, 1, 1, 0.45)))
		info.add_child(_text("A new mission type is on the way.", 16, Color(1, 1, 1, 0.35)))
		button.text = "Soon"
		button.disabled = true
		row.add_child(button)
		return [panel, button]
	info.add_child(_text(m.name, 26))
	info.add_child(_text(Missions.TYPE_NAMES[m.type], 18, Color(1, 1, 1, 0.6)))
	var stars := StarRow.new(Progress.mission_best(m.id), 28.0)
	stars.name = "Stars"
	stars.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(stars)
	if Progress.is_mission_unlocked(m.id):
		button.text = "Play"
		button.pressed.connect(play_mission.bind(m.id))
	else:
		button.text = "Locked"
		button.disabled = true
		button.tooltip_text = "Complete mission %d first" % (slot - 1)
		info.add_child(_text("Complete mission %d first" % (slot - 1), 16, Color(1, 0.6, 0.4)))
	row.add_child(button)
	return [panel, button]


## Loads a mission (missions/mission_mode.gd reads `pending`).
func play_mission(id: String) -> void:
	var m := Missions.find(id)
	if m.is_empty() or not Progress.is_mission_unlocked(id):
		return
	_disable_all()
	Missions.pending = id
	LoadingScreen.go(get_tree(), Maps.for_mission(m.map, m.name))


func _on_back() -> void:
	match step:
		Step.MISSION_LIST:
			_build_mission_map_cards()
			_show(Step.MISSION_MAPS, "Combat Missions: choose a map")
		Step.MISSION_MAPS:
			choose_mode(Maps.COMBAT)
		Step.MAPS:
			if mode == Maps.COMBAT:
				choose_mode(Maps.COMBAT)
			else:
				show_modes()
		Step.COMBAT_KIND:
			show_modes()
		_:
			get_tree().change_scene_to_file(MENU_SCENE)
